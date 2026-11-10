import Foundation
@testable import ClaudeBridgeCore

/// Stand-in for iCTRL's raw API. Records every call and lets a test script
/// what is in front before and after each one.
final class MockRawAPI: BridgeRawAPI {
    var calls: [(method: String, params: BridgeJSON)] = []
    /// Foreground bundle id reported by device_info. nil = unnameable.
    var foreground: String? = BridgeGuard.springboard
    var screenLocked = false
    var deviceInfoFails = false
    /// Canned results per method. Default is an empty success.
    var results: [String: BridgeRawResult] = [:]
    /// Runs after a non-probe call, e.g. to move the foreground.
    var afterCall: ((String) -> Void)?
    /// Successive foreground values consumed by device_info, if set.
    var foregroundScript: [String?] = []

    /// What SpringBoard's UI tree looks like when the guard inspects it.
    var springboardSource = "Other, id: 'Home screen icons', {{0, 0}, {393, 852}}"
    static let appSwitcherSource = "Other, id: 'Home screen icons'\nOther, id: 'AppSwitcherContentView'\nWindow, id: 'SBSwitcherWindow:Main'"

    private static func isProbe(_ method: String, _ params: BridgeJSON) -> Bool {
        method == "device_info" || (method == "page_source" && params["bundle_id"] as? String == BridgeGuard.springboard)
    }
    /// Raw calls other than the guard's own state checks.
    var actionCalls: [String] { calls.filter { !Self.isProbe($0.method, $0.params) }.map(\.method) }

    func call(_ method: String, _ params: BridgeJSON) -> BridgeRawResult {
        calls.append((method, params))
        if method == "device_info" {
            if deviceInfoFails { return .failure("UI channel unhealthy") }
            if !foregroundScript.isEmpty { foreground = foregroundScript.removeFirst() }
            var system: BridgeJSON = [
                "screen_locked": screenLocked,
                "battery_percent": 81,
                "battery_state": "unplugged",
                "thermal_state": "nominal",
                "low_power_mode": false,
            ]
            if let foreground = foreground { system["foreground_app"] = foreground }
            return .success(["point_width": 393.0, "point_height": 852.0, "system": system])
        }
        if Self.isProbe(method, params) { return .success(["source": springboardSource]) }
        let result = results[method] ?? .success([:])
        afterCall?(method)
        return result
    }
}

final class TestClock: BridgeClock {
    var uptime: TimeInterval = 1000
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

struct FixedSecret: BridgeSecretSource {
    var currentSecret: String?
}

final class MutableSecret: BridgeSecretSource {
    var currentSecret: String?
    init(_ s: String?) { currentSecret = s }
}

let whatsApp = BridgeAllowedApp.whatsApp.bundleID
let safari = "com.apple.mobilesafari"

/// A full stack over a mock raw API.
struct Harness {
    let raw = MockRawAPI()
    let clock = TestClock()
    let log = BridgeActionLog()
    let guardian: BridgeGuard
    let tools: BridgeTools
    var lockouts = 0

    init(apps: [BridgeAllowedApp] = [.whatsApp], burst: Int = 100) {
        let allowlist = BridgeStaticAllowlist(allowedApps: apps)
        guardian = BridgeGuard(raw: raw, allowlist: allowlist)
        guardian.sleep = { _ in }
        tools = BridgeTools(
            raw: raw, allowlist: allowlist, guardian: guardian,
            limiter: BridgeRateLimiter(burst: burst, perSecond: 1, clock: clock),
            log: log, clock: clock)
        tools.makeBlockID = { "test" }
    }

    func call(_ name: String, _ args: BridgeJSON = [:]) -> BridgeToolResult {
        tools.call(name, args)!
    }
}

extension BridgeToolResult {
    var firstText: String {
        content.compactMap { $0["text"] as? String }.first ?? ""
    }
    var allText: String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
