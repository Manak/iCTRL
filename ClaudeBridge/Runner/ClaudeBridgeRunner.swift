import Foundation
import Security

// Runner-side glue for the Claude bridge. Compiled into the iCTRLUITests
// bundle next to ClaudeBridge/Core. This is the only bridge file that knows
// about iCTRL's own types (JSONValue, JSONRPCError, the log buffer).

/// iCTRL's in-process RPC entry point: the same closure HTTP clients reach
/// after the envelope is opened, so calls share its queue, watchdog and
/// circuit breaker.
typealias ClaudeBridgeRPC = (String, [String: JSONValue]?, @escaping ([String: JSONValue]?, JSONRPCError?) -> Void) -> Void

final class ClaudeBridgeRunner {
    static let shared = ClaudeBridgeRunner()

    /// Loopback port of the MCP listener. 8200 is the raw API and 8201 its
    /// nearby listener, so the bridge stays clear of both.
    static let defaultPort: UInt16 = 8220
    static let enabledKey = "claudeBridge.enabled"
    static let portKey = "claudeBridge.port"

    private var http: BridgeHTTPServer?
    private let lock = NSLock()
    let actionLog = BridgeActionLog()
    private(set) var guardian: BridgeGuard?
    private var keepAwake: BridgeKeepAwake?
    private(set) var idle: BridgeIdleShutdown?
    private(set) var sessionStarted: Date?
    static let idleMinutesKey = "claudeBridge.idleMinutes"

    /// True once the companion says its Live Activity is showing. The
    /// runner's own "server ready" notification is then redundant and is
    /// withheld (see the hook in `postStatusNotification`).
    var statusNotificationSuppressed = false

    /// Minutes without a request from Claude before the session ends.
    /// Default 30; 0 means never.
    static var idleLimit: TimeInterval {
        if let minutes = UserDefaults.standard.object(forKey: idleMinutesKey) as? Double {
            return max(0, minutes) * 60
        }
        return BridgeIdleShutdown.defaultLimit
    }

    /// Stops everything: the public address, the bridge, the raw API and the
    /// runner process itself. Uses iCTRL's own stop path, so the run loop
    /// exits and the bridge is torn down by the hook that follows it.
    func endSession() {
        lock.lock(); let rpc = self.rpc; lock.unlock()
        guard let rpc = rpc else { return }
        rpc("config", [
            "stop_server": .bool(true),
            JSONRPCServer.peerSourceParam: .string("local"),
        ]) { _, _ in }
    }
    static let keepAwakeKey = "claudeBridge.keepAwake"

    /// On by default while the bridge runs; set the key to false to let the
    /// phone auto-lock as usual. `ICTRL_BRIDGE_KEEP_AWAKE=0` does the same
    /// for one debug run.
    static var keepAwakeEnabled: Bool {
        if ProcessInfo.processInfo.environment["ICTRL_BRIDGE_KEEP_AWAKE"] == "0" { return false }
        return UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool ?? true
    }

    /// Off unless switched on. With the bridge off, the runner behaves exactly
    /// like upstream iCTRL. `ICTRL_BRIDGE=1` in the Xcode scheme turns it on
    /// for a debug run without persisting anything.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["ICTRL_BRIDGE"] == "1" { return true }
        // Funnel mode needs the bridge, so it switches it on.
        if ClaudeBridgeGate.funnelMode { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return http != nil
    }

    /// Kept so the mode can be switched while the runner is running.
    private var rpc: ClaudeBridgeRPC?

    /// Called once by the runner when its own server is up. Starts the MCP
    /// listener on 127.0.0.1 if the bridge is enabled; otherwise only
    /// remembers how to reach the raw API, for a later `setFunnelMode`.
    func start(rpc: @escaping ClaudeBridgeRPC) {
        lock.lock(); defer { lock.unlock() }
        self.rpc = rpc
        startLocked()
    }

    /// Switches "Claude via Funnel" on or off, now and for future starts.
    func setFunnelMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ClaudeBridgeGate.funnelKey)
        lock.lock()
        stopLocked()
        let rpc = self.rpc
        startLocked()
        lock.unlock()
        if on, let rpc = rpc {
            // The raw API must be loopback-only from now on. Asking for
            // remote access off rebuilds its listener if it was on, and the
            // rebuilt listener is pinned to loopback by ClaudeBridgeGate.
            rpc("config", [
                "allow_remote_access": .bool(false),
                JSONRPCServer.peerSourceParam: .string("local"),
            ]) { _, _ in }
        }
    }

    private func startLocked() {
        guard Self.isEnabled, let rpc = rpc else { return }
        guard http == nil else { return }

        let raw = ClaudeBridgeRawAPI(rpc: rpc)
        let allowlist = ClaudeBridgeAllowlistStore()
        let clock = BridgeSystemClock()
        let guardian = BridgeGuard(raw: raw, allowlist: allowlist)
        guardian.onLockout = { Self.log("🤖⛔️ Claude bridge locked out: non-allowlisted app in foreground") }
        let keepAwake = BridgeKeepAwake(
            clock: clock,
            isLocked: { LockStateMonitor.shared().isLocked },
            sendEvent: { ClaudeBridgeIdleEvent.send() })
        actionLog.onAppend = { [weak keepAwake] entry in
            // Tool name and status only. Never arguments or screen content.
            Self.log("🤖 MCP \(entry.tool) → \(entry.status.rawValue)")
            keepAwake?.noteActivity()
        }
        let tools = BridgeTools(
            raw: raw, allowlist: allowlist, guardian: guardian,
            // About two calls a second sustained, with room for short bursts.
            limiter: BridgeRateLimiter(burst: 30, perSecond: 2, clock: clock),
            log: actionLog, clock: clock)

        // On iOS 27 the runner can only name the front app by asking apps it
        // already knows whether they are in front. Make sure it knows every
        // app the bridge cares about, so one the owner opened by hand (or the
        // system search) is recognised instead of reading as "unknown".
        for app in allowlist.allowedApps + BridgeGuard.systemSurfaces where AppMemory.shared.entry(for: app.bundleID) == nil {
            AppMemory.shared.recordOpened(bundleId: app.bundleID, name: app.name)
        }

        let secrets = ClaudeBridgeSecretStore.shared
        secrets.ensureSecret()
        let mcp = BridgeMCPServer(auth: BridgePathSecretAuthenticator(secrets: secrets), tools: tools)

        // End the whole session when Claude has been quiet for too long.
        let idle = BridgeIdleShutdown(limit: Self.idleLimit, clock: clock)
        mcp.onAuthenticRequest = { [weak idle] in idle?.noteActivity() }
        idle.onExpire = { [weak self] in
            Self.log("🤖💤 No request from Claude for \(Int(Self.idleLimit / 60)) min: ending the session")
            self?.endSession()
        }

        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = (saved > 1024 && saved <= 65535) ? UInt16(saved) : Self.defaultPort
        let server = BridgeHTTPServer(port: port) { mcp.handle($0) }
        server.onLog = { Self.log("🤖 \($0)") }
        do {
            try server.start()
            http = server
            self.guardian = guardian
            self.idle = idle
            sessionStarted = Date()
            idle.start()
            if ProcessInfo.processInfo.environment["ICTRL_BRIDGE_DIAG"] == "1" {
                ClaudeBridgeDiagnostics.start(raw: raw, log: Self.log)
                Self.log("🤖🔬 installed-app routes: \(ClaudeBridgeInstalledApps.counts())")
            }
            if Self.keepAwakeEnabled {
                keepAwake.start()
                self.keepAwake = keepAwake
                Self.log("🤖 keep-awake on: the phone will not auto-lock during the session")
            }
            // "Claude via Funnel": publish the listener through Tailscale.
            // Without it the bridge stays reachable on this device only.
            if ClaudeBridgeGate.funnelMode {
                ClaudeBridgeTunnel.shared.start(targetPort: server.port) { Self.log($0) }
            }
        } catch {
            Self.log("🤖🔴 Claude bridge failed to start: \(error)")
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        // Public side first, so nothing arrives for a listener that is gone.
        ClaudeBridgeTunnel.shared.stop()
        idle?.stop()
        idle = nil
        sessionStarted = nil
        statusNotificationSuppressed = false
        keepAwake?.stop()
        keepAwake = nil
        http?.stop()
        http = nil
        guardian = nil
    }

    /// The bridge logs through iCTRL's buffer. Callers must never pass the
    /// URL secret, a request path, or anything read from the screen.
    private static func log(_ message: String) {
        iCTRLUITests.logBuffer.append(message)
    }
}

// MARK: - Raw API adapter

/// Calls iCTRL's RPC dispatcher and converts between JSONValue and plain
/// Foundation JSON.
final class ClaudeBridgeRawAPI: BridgeRawAPI {
    /// Upper bound on one raw call. iCTRL's own watchdog answers well before
    /// this (6 to 90 s); this only protects against a reply that never comes.
    static let timeout: TimeInterval = 100
    private let rpc: ClaudeBridgeRPC

    init(rpc: @escaping ClaudeBridgeRPC) { self.rpc = rpc }

    func call(_ method: String, _ params: BridgeJSON) -> BridgeRawResult {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        var converted: [String: JSONValue] = [:]
        for (key, value) in params { converted[key] = Self.toJSONValue(value) }

        rpc(method, converted) { result, error in
            if let error = error {
                box.set(.failure(error.message))
            } else {
                box.set(.success((result ?? [:]).mapValues { $0.toAny() }))
            }
            done.signal()
        }
        if done.wait(timeout: .now() + Self.timeout) == .timedOut {
            return .failure("\(method) did not answer within \(Int(Self.timeout))s")
        }
        return box.get() ?? .failure("\(method) returned nothing")
    }

    private final class ResultBox {
        private var value: BridgeRawResult?
        private let lock = NSLock()
        func set(_ v: BridgeRawResult) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        func get() -> BridgeRawResult? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func toJSONValue(_ any: Any) -> JSONValue {
        switch any {
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e15 { return .int(n.intValue) }
            return .double(d)
        case let a as [Any]:
            return .array(a.map(toJSONValue))
        case let o as [String: Any]:
            return .object(o.mapValues(toJSONValue))
        default:
            return .null
        }
    }
}

// MARK: - Allowlist

/// The allowlist, kept in the runner's own defaults and edited from the
/// companion app. Nothing in the MCP layer writes it. It starts empty.
struct ClaudeBridgeAllowlistStore: BridgeAllowlistProvider {
    static let key = "claudeBridge.allowlist"

    /// Read fresh on every use, so an edit from the companion applies to the
    /// very next tool call. Always passed through the policy filter.
    var allowedApps: [BridgeAllowedApp] {
        // Nothing is allowed until the owner switches an app on.
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [[String: Any]] ?? []
        return BridgeAllowlistPolicy.sanitize(stored.compactMap(Self.app(from:)))
    }

    static func app(from entry: [String: Any]) -> BridgeAllowedApp? {
        guard let bundle = entry["bundle_id"] as? String, !bundle.isEmpty else { return nil }
        let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundle
        return BridgeKnownLinks.app(bundleID: bundle, name: name, readOnly: entry["read_only"] as? Bool ?? false)
    }

    /// Stores a new list. Returns what was actually kept after filtering.
    @discardableResult
    static func save(_ apps: [BridgeAllowedApp]) -> [BridgeAllowedApp] {
        let kept = BridgeAllowlistPolicy.sanitize(apps)
        let stored: [[String: Any]] = kept.map {
            ["bundle_id": $0.bundleID, "name": $0.name, "read_only": $0.readOnly]
        }
        UserDefaults.standard.set(stored, forKey: key)
        // Make sure the runner can recognise each app when it is in front.
        for app in kept where AppMemory.shared.entry(for: app.bundleID) == nil {
            AppMemory.shared.recordOpened(bundleId: app.bundleID, name: app.name)
        }
        return kept
    }
}

// MARK: - URL secret

/// The URL secret, kept in the runner's keychain and nowhere else. It is
/// never logged and never returned by an MCP tool.
final class ClaudeBridgeSecretStore: BridgeSecretSource {
    static let shared = ClaudeBridgeSecretStore()
    private static let service = "claude-bridge"
    private static let account = "url-secret"

    private let lock = NSLock()
    private var cached: String?
    private var loaded = false

    var currentSecret: String? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return cached
    }

    /// Creates a secret on first use.
    func ensureSecret() {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if cached == nil { store(BridgeSecret.generate()) }
    }

    /// Replaces the secret. The old URL stops working with the next request.
    @discardableResult
    func rotate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store(BridgeSecret.generate())
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // Debug convenience, mirroring ICTRL_ALLOW_AUTH_ONCE: a fixed secret
        // from the Xcode scheme so a development run has a known URL. It is
        // used for this launch only and is not written to the keychain.
        if let dev = ProcessInfo.processInfo.environment["ICTRL_BRIDGE_DEV_SECRET"],
           dev.count >= BridgePathSecretAuthenticator.minimumLength {
            cached = dev
            return
        }
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let value = String(data: data, encoding: .utf8) {
            cached = value
        }
    }

    @discardableResult
    private func store(_ secret: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        // Readable while the runner works in the background after the first
        // unlock; never synced and never included in a device transfer.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            cached = secret
            loaded = true
            return true
        }
        // Keychain unavailable: fall back to memory for this launch, so the
        // endpoint is never left without a secret.
        cached = secret
        loaded = true
        return false
    }
}

// MARK: - Keep-awake event

/// The input event keep-awake sends: Control pressed and released on a
/// virtual hardware keyboard. It never touches the screen, so it cannot tap
/// a control, and a bare modifier key does nothing in any app.
enum ClaudeBridgeIdleEvent {
    /// XCUIKeyModifierFlags.control
    private static let control: UInt = 1 << 2
    private static var loggedFailure = false

    static func send() -> Bool {
        var ok = false
        // XCTest event synthesis is main-thread only in this runner.
        if Thread.isMainThread { ok = sendOnMain() } else { DispatchQueue.main.sync { ok = sendOnMain() } }
        if !ok, !loggedFailure {
            loggedFailure = true
            iCTRLUITests.logBuffer.append("🤖🔴 keep-awake event could not be sent; the phone may auto-lock")
        }
        return ok
    }

    private static func sendOnMain() -> Bool {
        // -[XCPointerEventPath setModifiers:mergeWithCurrentModifierFlags:atOffset:]
        // is not in the bridging header, so it is called through its IMP.
        let selector = NSSelectorFromString("setModifiers:mergeWithCurrentModifierFlags:atOffset:")
        let path = XCPointerEventPath(forTextInput: ())
        guard path.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: path), selector) else { return false }
        typealias SetModifiers = @convention(c) (AnyObject, Selector, UInt, Bool, TimeInterval) -> Void
        let setModifiers = unsafeBitCast(implementation, to: SetModifiers.self)
        var ok = false
        let failure = ObjCException.catching {
            setModifiers(path, selector, control, false, 0)
            setModifiers(path, selector, 0, false, 0.05)
            let record = XCSynthesizedEventRecord(name: "Claude Bridge keep-awake")
            record.add(path)
            ok = (try? record.synthesize()) != nil
        }
        return failure == nil && ok
    }
}

// MARK: - Diagnostics

/// Development aid, on only with `ICTRL_BRIDGE_DIAG=1`. Every two seconds it
/// logs which app is in front and the element ids in SpringBoard's visible
/// tree, when either changes. That is how the markers for the home screen,
/// the app switcher and system overlays are found on a new iOS version.
/// It logs identifiers only (letters, digits, `_ . : -`), never labels.
enum ClaudeBridgeDiagnostics {
    private static var timer: DispatchSourceTimer?
    private static var last = ""

    static func start(raw: BridgeRawAPI, log: @escaping (String) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler {
            var front = "?"
            var locked = false
            if case .success(let info) = raw.call("device_info", [:]), let system = info["system"] as? BridgeJSON {
                front = system["foreground_app"] as? String ?? "unnamed"
                locked = system["screen_locked"] as? Bool ?? false
            }
            var ids: [String] = []
            var nodes = 0
            if case .success(let page) = raw.call("page_source", ["bundle_id": BridgeGuard.springboard, "visible_only": true, "max_children": 50]),
               let source = page["source"] as? String {
                nodes = source.components(separatedBy: "\n").count
                let pattern = try? NSRegularExpression(pattern: "id: '([A-Za-z0-9_.:\\-]{2,60})'")
                let range = NSRange(source.startIndex..., in: source)
                var seen = Set<String>()
                pattern?.enumerateMatches(in: source, range: range) { match, _, _ in
                    if let m = match, let r = Range(m.range(at: 1), in: source) { seen.insert(String(source[r])) }
                }
                ids = seen.sorted()
            }
            let line = "front=\(front) locked=\(locked) sb_nodes~\(nodes / 10 * 10) sb_ids=\(ids.prefix(40).joined(separator: ","))"
            if line != last {
                last = line
                log("🤖🔬 \(line)")
            }
        }
        t.resume()
        timer = t
    }
}
