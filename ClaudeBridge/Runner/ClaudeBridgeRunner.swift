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

    /// Off unless switched on. With the bridge off, the runner behaves exactly
    /// like upstream iCTRL. `ICTRL_BRIDGE=1` in the Xcode scheme turns it on
    /// for a debug run without persisting anything.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["ICTRL_BRIDGE"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return http != nil
    }

    /// Starts the MCP listener on 127.0.0.1. Does nothing unless enabled.
    func start(rpc: @escaping ClaudeBridgeRPC) {
        guard Self.isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard http == nil else { return }

        let raw = ClaudeBridgeRawAPI(rpc: rpc)
        let allowlist = ClaudeBridgeAllowlistStore()
        let clock = BridgeSystemClock()
        let guardian = BridgeGuard(raw: raw, allowlist: allowlist)
        guardian.onLockout = { Self.log("🤖⛔️ Claude bridge locked out: non-allowlisted app in foreground") }
        actionLog.onAppend = { entry in
            // Tool name and status only. Never arguments or screen content.
            Self.log("🤖 MCP \(entry.tool) → \(entry.status.rawValue)")
        }
        let tools = BridgeTools(
            raw: raw, allowlist: allowlist, guardian: guardian,
            // About two calls a second sustained, with room for short bursts.
            limiter: BridgeRateLimiter(burst: 30, perSecond: 2, clock: clock),
            log: actionLog, clock: clock)

        let secrets = ClaudeBridgeSecretStore.shared
        secrets.ensureSecret()
        let mcp = BridgeMCPServer(auth: BridgePathSecretAuthenticator(secrets: secrets), tools: tools)

        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = (saved > 1024 && saved <= 65535) ? UInt16(saved) : Self.defaultPort
        let server = BridgeHTTPServer(port: port) { mcp.handle($0) }
        server.onLog = { Self.log("🤖 \($0)") }
        do {
            try server.start()
            http = server
            self.guardian = guardian
        } catch {
            Self.log("🤖🔴 Claude bridge failed to start: \(error)")
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
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

/// The allowlist, read from the runner's own defaults. Nothing in the MCP
/// layer writes it. Editing from the companion app arrives in a later stage;
/// until then it is WhatsApp only.
struct ClaudeBridgeAllowlistStore: BridgeAllowlistProvider {
    static let key = "claudeBridge.allowlist"

    var allowedApps: [BridgeAllowedApp] {
        guard let stored = UserDefaults.standard.array(forKey: Self.key) as? [[String: Any]] else {
            return [.whatsApp]
        }
        return stored.compactMap { entry in
            guard let bundle = entry["bundle_id"] as? String, !bundle.isEmpty else { return nil }
            return BridgeAllowedApp(
                bundleID: bundle,
                name: entry["name"] as? String ?? bundle,
                readOnly: entry["read_only"] as? Bool ?? false,
                urlSchemes: (entry["url_schemes"] as? [String] ?? []).map { $0.lowercased() },
                urlHosts: (entry["url_hosts"] as? [String] ?? []).map { $0.lowercased() })
        }
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
