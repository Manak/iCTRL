import Foundation

/// Claude Bridge: one switch shared by the raw JSON-RPC server and the bridge.
///
/// In "Claude via Funnel" mode the phone has a public endpoint. The raw API
/// (tap anywhere, type anything) must then stay on 127.0.0.1 whatever the
/// remote-access setting says, so `JSONRPCServer` consults this when it is
/// created. This file lives in iCTRLKit because that server is compiled into
/// both the app and the runner; the rest of the bridge is in ClaudeBridge/.
enum ClaudeBridgeGate {
    static let funnelKey = "claudeBridge.funnel"

    /// True when the runner is (or will be, on its next start) in Funnel mode.
    /// `ICTRL_BRIDGE_FUNNEL=1` in the Xcode scheme turns it on for one debug
    /// run without persisting anything.
    static var funnelMode: Bool {
        if ProcessInfo.processInfo.environment["ICTRL_BRIDGE_FUNNEL"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: funnelKey)
    }

    /// The raw API may only bind to loopback while this is true.
    static var forceLocalOnly: Bool { funnelMode }
}
