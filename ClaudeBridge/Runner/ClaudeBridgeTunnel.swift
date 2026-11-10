import Foundation
import Security

// The Tailscale side of the bridge: a Go static library (ClaudeBridge/go)
// that joins the tailnet with tsnet and serves Funnel on port 443, forwarding
// to the MCP listener on 127.0.0.1. Declared here by symbol name so no
// bridging header (an upstream file) has to change.

@_silgen_name("ClaudeBridgeTSStart")
private func ClaudeBridgeTSStart(_ dir: UnsafePointer<CChar>, _ hostname: UnsafePointer<CChar>,
                                 _ authKey: UnsafePointer<CChar>, _ targetPort: Int32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("ClaudeBridgeTSStop")
private func ClaudeBridgeTSStop()
@_silgen_name("ClaudeBridgeTSStatus")
private func ClaudeBridgeTSStatus() -> UnsafeMutablePointer<CChar>?

/// Status of the public endpoint. Never contains the URL secret.
struct ClaudeBridgeTunnelStatus: Equatable {
    /// stopped | starting | needs_login | running | error
    var state = "stopped"
    /// For example "ictrl-phone.tail1234.ts.net".
    var host: String?
    var error: String?
}

final class ClaudeBridgeTunnel {
    static let shared = ClaudeBridgeTunnel()
    static let hostnameKey = "claudeBridge.hostname"
    static let defaultHostname = "ictrl-phone"
    static let lastHostKey = "claudeBridge.lastHost"

    /// Public host name from the last time Funnel was live. It only changes
    /// if the device is renamed or the tailnet's domain changes.
    static var lastKnownHost: String? {
        let host = UserDefaults.standard.string(forKey: lastHostKey) ?? ""
        return host.isEmpty ? nil : host
    }

    private let lock = NSLock()
    private var started = false
    private var watcher: DispatchSourceTimer?
    private var lastLogged = ClaudeBridgeTunnelStatus()

    /// Fixed device name on the tailnet, so the URL never changes.
    static var hostname: String {
        let saved = UserDefaults.standard.string(forKey: hostnameKey) ?? ""
        return saved.isEmpty ? defaultHostname : saved
    }

    /// tsnet's node key and TLS certificates. Durable (so the URL and device
    /// identity survive restarts and reboots), never backed up, and readable
    /// while the runner works in the background after the first unlock.
    static func stateDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("ClaudeBridge/tsnet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// Joins the tailnet and opens Funnel, forwarding to `targetPort` on
    /// loopback. Returns at once; progress is reported through `status`.
    func start(targetPort: UInt16, log: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        do {
            let dir = try Self.stateDirectory()
            // Only needed the first time; afterwards the stored node key logs in.
            let authKey = ClaudeBridgeAuthKeyStore.shared.currentSecret ?? ""
            let failure = dir.path.withCString { d in
                Self.hostname.withCString { h in
                    authKey.withCString { k in ClaudeBridgeTSStart(d, h, k, Int32(targetPort)) }
                }
            }
            if let failure = failure {
                let message = String(cString: failure)
                free(failure)
                log("🤖🔴 Funnel failed to start: \(Self.redact(message))")
                return
            }
            started = true
            log("🤖 Funnel starting as \(Self.hostname)")
            watch(log: log)
        } catch {
            log("🤖🔴 Funnel state directory unavailable: \(error.localizedDescription)")
        }
    }

    /// Leaves the tailnet. The public endpoint stops answering.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        watcher?.cancel()
        watcher = nil
        guard started else { return }
        started = false
        ClaudeBridgeTSStop()
    }

    var status: ClaudeBridgeTunnelStatus {
        guard let raw = ClaudeBridgeTSStatus() else { return ClaudeBridgeTunnelStatus() }
        defer { free(raw) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any] else {
            return ClaudeBridgeTunnelStatus()
        }
        return ClaudeBridgeTunnelStatus(
            state: object["state"] as? String ?? "stopped",
            host: object["host"] as? String,
            error: (object["error"] as? String).map(Self.redact))
    }

    /// Logs state changes only. Checks often while starting, rarely after.
    private func watch(log: @escaping (String) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = self.status
            guard now != self.lastLogged else { return }
            self.lastLogged = now
            switch now.state {
            case "running":
                log("🤖🌐 Funnel live at https://\(now.host ?? "?")/…/mcp")
                // Remembered so the companion can show the URL while stopped.
                if let host = now.host { UserDefaults.standard.set(host, forKey: Self.lastHostKey) }
                // Settled: a slow heartbeat is enough from here on.
                timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
            case "error", "needs_login":
                log("🤖🔴 Funnel \(now.state): \(now.error ?? "unknown")")
            default:
                log("🤖 Funnel \(now.state)")
            }
        }
        timer.resume()
        watcher = timer
    }

    /// Tailscale errors should not contain keys, but never rely on that.
    static func redact(_ message: String) -> String {
        message.replacingOccurrences(of: #"tskey-[A-Za-z0-9-]+"#, with: "tskey-<redacted>", options: .regularExpression)
    }
}

/// The Tailscale auth key, kept in the runner's keychain. Used once, to join
/// the tailnet; the node key in the state directory takes over afterwards.
final class ClaudeBridgeAuthKeyStore: BridgeSecretSource {
    static let shared = ClaudeBridgeAuthKeyStore()
    private static let service = "claude-bridge"
    private static let account = "tailscale-authkey"

    var currentSecret: String? {
        // Debug convenience for a development run; not written to the keychain.
        if let dev = ProcessInfo.processInfo.environment["ICTRL_BRIDGE_TS_AUTHKEY"], !dev.isEmpty { return dev }
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func store(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
