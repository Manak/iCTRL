import Foundation
import UserNotifications

/// Phone-side administration of the bridge, for the companion app.
///
/// It is one extra method on iCTRL's existing paired, encrypted JSON-RPC
/// channel (the same one the companion uses for `config`). It is NOT an MCP
/// tool: nothing reachable through Funnel can call it, so the allowlist, the
/// secret and the mode can only be changed from the phone.
///
/// `{"method": "claude_bridge", "params": {"action": "..."}}`
///
/// | action          | params          | result                                  |
/// |-----------------|-----------------|-----------------------------------------|
/// | status          |                 | mode, tunnel state, host; never a secret |
/// | set_mode        | mode: off/funnel| status                                  |
/// | connector_url   |                 | url (contains the secret)               |
/// | rotate_secret   |                 | url (new secret; old one is dead)       |
/// | set_auth_key    | auth_key        | status                                  |
/// | action_log      |                 | entries: time, tool, status             |
/// | set_allowlist   | apps: [...]     | status + rejected bundle ids            |
/// | end_session     |                 | stops bridge, raw API and the runner    |
/// | live_activity   | showing: bool   | status; withholds the status notification |
enum ClaudeBridgeAdmin {
    static let method = "claude_bridge"

    static func handle(_ params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        let params = params ?? [:]
        guard let action = params["action"]?.stringValue else {
            return (nil, .serverError("claude_bridge: 'action' is required"))
        }
        switch action {
        case "status":
            return (status(), nil)

        case "set_mode":
            guard let mode = params["mode"]?.stringValue, mode == "off" || mode == "funnel" else {
                return (nil, .serverError("claude_bridge set_mode: mode must be 'off' or 'funnel'"))
            }
            ClaudeBridgeRunner.shared.setFunnelMode(mode == "funnel")
            return (status(), nil)

        case "connector_url":
            return connectorURL()

        case "rotate_secret":
            // The authenticator reads the secret on every request, so the old
            // URL stops working with the very next one.
            ClaudeBridgeSecretStore.shared.rotate()
            iCTRLUITests.logBuffer.append("🤖🔑 Claude bridge URL secret rotated")
            return connectorURL()

        case "set_auth_key":
            let key = params["auth_key"]?.stringValue ?? ""
            guard key.isEmpty || key.hasPrefix("tskey-") else {
                return (nil, .serverError("claude_bridge set_auth_key: that does not look like a Tailscale auth key (tskey-…)"))
            }
            guard ClaudeBridgeAuthKeyStore.shared.store(key) else {
                return (nil, .serverError("claude_bridge set_auth_key: the keychain refused the key"))
            }
            iCTRLUITests.logBuffer.append(key.isEmpty ? "🤖🔑 Tailscale auth key cleared" : "🤖🔑 Tailscale auth key stored")
            return (status(), nil)

        case "set_allowlist":
            guard case .array(let items)? = params["apps"] else {
                return (nil, .serverError("claude_bridge set_allowlist: 'apps' must be a list"))
            }
            var requested: [BridgeAllowedApp] = []
            var rejected: [JSONValue] = []
            for item in items {
                guard let entry = item.toAny() as? [String: Any],
                      let app = ClaudeBridgeAllowlistStore.app(from: entry) else { continue }
                if !BridgeAllowlistPolicy.isValidBundleID(app.bundleID) || BridgeAllowlistPolicy.isForbidden(app.bundleID) {
                    rejected.append(.string(app.bundleID))
                } else {
                    requested.append(app)
                }
            }
            let kept = ClaudeBridgeAllowlistStore.save(requested)
            iCTRLUITests.logBuffer.append("🤖📋 Allowlist changed from the phone: \(kept.count) app(s)")
            var out = status()
            out["rejected"] = .array(rejected)
            return (out, nil)

        case "end_session":
            iCTRLUITests.logBuffer.append("🤖🛑 Session ended from the phone")
            ClaudeBridgeRunner.shared.endSession()
            return (["stopping": .bool(true)], nil)

        case "live_activity":
            // The companion reports whether its Live Activity is on screen.
            let showing = params["showing"]?.boolValue ?? false
            ClaudeBridgeRunner.shared.statusNotificationSuppressed = showing
            if showing { ClaudeBridgeNotifications.removeStatusNotification() }
            return (status(), nil)

        case "action_log":
            let iso = ISO8601DateFormatter()
            let entries: [JSONValue] = ClaudeBridgeRunner.shared.actionLog.all.suffix(200).map {
                .object([
                    "time": .string(iso.string(from: $0.time)),
                    "tool": .string($0.tool),
                    "status": .string($0.status.rawValue),
                ])
            }
            return (["entries": .array(entries)], nil)

        default:
            return (nil, .serverError("claude_bridge: unknown action '\(action)'"))
        }
    }

    /// Everything the companion shows that is not secret.
    static func status() -> [String: JSONValue] {
        let runner = ClaudeBridgeRunner.shared
        let tunnel = ClaudeBridgeTunnel.shared.status
        var out: [String: JSONValue] = [
            "mode": .string(ClaudeBridgeGate.funnelMode ? "funnel" : (ClaudeBridgeRunner.isEnabled ? "local" : "off")),
            "running": .bool(runner.isRunning),
            "tunnel_state": .string(tunnel.state),
            "hostname": .string(ClaudeBridgeTunnel.hostname),
            "has_auth_key": .bool(ClaudeBridgeAuthKeyStore.shared.currentSecret != nil),
            "locked_out": .bool(runner.guardian?.isLockedOut ?? false),
            "keep_awake": .bool(ClaudeBridgeRunner.keepAwakeEnabled),
            "allowed_apps": .array(ClaudeBridgeAllowlistStore().allowedApps.map {
                .object(["bundle_id": .string($0.bundleID), "name": .string($0.name), "read_only": .bool($0.readOnly)])
            }),
        ]
        if let started = runner.sessionStarted {
            out["session_started"] = .double(started.timeIntervalSince1970)
        }
        out["idle_limit_minutes"] = .double(ClaudeBridgeRunner.idleLimit / 60)
        if let idle = runner.idle, let remaining = idle.remaining {
            out["idle_seconds"] = .double(idle.idleFor)
            out["ends_at"] = .double(Date().timeIntervalSince1970 + remaining)
        }
        if let host = tunnel.host ?? ClaudeBridgeTunnel.lastKnownHost { out["host"] = .string(host) }
        if let error = tunnel.error { out["tunnel_error"] = .string(error) }
        return out
    }

    private static func connectorURL() -> ([String: JSONValue]?, JSONRPCError?) {
        guard let secret = ClaudeBridgeSecretStore.shared.currentSecret else {
            return (nil, .serverError("claude_bridge: no URL secret yet; start a session first"))
        }
        guard let host = ClaudeBridgeTunnel.shared.status.host ?? ClaudeBridgeTunnel.lastKnownHost else {
            return (nil, .serverError("claude_bridge: the public host name is not known yet; start a session in Funnel mode and wait until it is live"))
        }
        return (["url": .string(BridgeConnectorURL.make(host: host, secret: secret)), "host": .string(host)], nil)
    }
}

/// Runner-side notification housekeeping for the bridge.
enum ClaudeBridgeNotifications {
    /// Identifier of iCTRL's always-present "server ready" notification.
    static let statusNotificationID = "ictrl.server.ready"

    static func removeStatusNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [statusNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [statusNotificationID])
    }
}
