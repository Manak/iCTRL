import Foundation

/// What is in front of the user right now, as far as the bridge is concerned.
enum BridgeForeground: Equatable {
    /// SpringBoard is frontmost.
    case home
    case allowed(BridgeAllowedApp)
    /// Anything that is not the home screen or an allowlisted app, including
    /// an app the runner could not name.
    case blocked
    case phoneLocked
    /// The raw API could not report the foreground (for example a wedged UI
    /// channel). Treated as "do nothing", but not as a lockout.
    case unverified(String)
}

/// One reading of the phone's state.
struct BridgeProbe {
    let foreground: BridgeForeground
    let pointWidth: Double
    let pointHeight: Double
    /// device_info's `system` object (battery, thermal state, …). Contains no
    /// screen content, but does contain the foreground bundle id, so it is
    /// only passed on after filtering.
    let system: BridgeJSON
}

/// Result of one MCP tool call, before it is wrapped as an MCP response.
struct BridgeToolResult {
    var content: [BridgeJSON]
    var isError: Bool
    var status: BridgeLogEntry.Status

    static func text(_ s: String) -> BridgeToolResult {
        BridgeToolResult(content: [["type": "text", "text": s]], isError: false, status: .ok)
    }
    static func error(_ s: String, status: BridgeLogEntry.Status = .error) -> BridgeToolResult {
        BridgeToolResult(content: [["type": "text", "text": s]], isError: true, status: status)
    }
}

/// Enforces "allowlisted apps only" around every raw API call.
///
/// Every guarded action is: check the foreground, act, check again. If either
/// check finds a non-allowlisted app the bridge is locked out: nothing is
/// read, nothing is done, and the reply names neither the app nor anything on
/// screen. The lockout is the foreground state itself, so it clears as soon as
/// the home screen or an allowlisted app is in front again.
final class BridgeGuard {
    static let springboard = "com.apple.springboard"
    static let lockedOutMessage =
        "locked: non-allowlisted app in foreground. Only go_home is available; call it to return to the home screen."
    static let phoneLockedMessage =
        "phone locked: the phone must be unlocked by its owner before any action can run."
    /// Sent when an action itself moved the phone somewhere it must not be.
    static let lockedAfterMessage =
        "locked: the action left a non-allowlisted app in the foreground. Nothing further was read or done. Call go_home."

    private let raw: BridgeRawAPI
    private let allowlist: BridgeAllowlistProvider
    /// Called on every transition into lockout.
    var onLockout: (() -> Void)?
    /// Post-action re-checks before a blocked reading counts as a lockout.
    var settleRetries = 2
    var settleDelay: TimeInterval = 0.5
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    private let runLock = NSLock()
    private let stateLock = NSLock()
    private var lockedOut = false

    init(raw: BridgeRawAPI, allowlist: BridgeAllowlistProvider) {
        self.raw = raw
        self.allowlist = allowlist
    }

    /// Whether the last check found a non-allowlisted app in front.
    var isLockedOut: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return lockedOut
    }

    /// Reads the foreground app and lock state through the raw API.
    func probe(record: Bool = true) -> BridgeProbe {
        let result = raw.call("device_info", [:])
        guard case .success(let info) = result else {
            var reason = "device state unavailable"
            if case .failure(let message) = result { reason = message }
            return BridgeProbe(foreground: .unverified(reason), pointWidth: 0, pointHeight: 0, system: [:])
        }
        let system = info["system"] as? BridgeJSON ?? [:]
        let width = (info["point_width"] as? NSNumber)?.doubleValue ?? 0
        let height = (info["point_height"] as? NSNumber)?.doubleValue ?? 0

        let foreground: BridgeForeground
        if (system["screen_locked"] as? Bool) ?? false {
            foreground = .phoneLocked
        } else if let bundle = system["foreground_app"] as? String, !bundle.isEmpty {
            if bundle == Self.springboard {
                foreground = .home
            } else if let app = allowlist.app(bundleID: bundle) {
                foreground = .allowed(app)
            } else {
                foreground = .blocked
            }
        } else {
            // The runner could not name the front app. Fail closed.
            foreground = .blocked
        }
        if record { note(foreground) }
        return BridgeProbe(foreground: foreground, pointWidth: width, pointHeight: height, system: system)
    }

    private func note(_ foreground: BridgeForeground) {
        var entered = false
        stateLock.lock()
        switch foreground {
        case .blocked:
            entered = !lockedOut
            lockedOut = true
        case .home, .allowed:
            lockedOut = false
        case .phoneLocked, .unverified:
            break
        }
        stateLock.unlock()
        if entered { onLockout?() }
    }

    /// The refusal for a foreground state, or nil when acting is permitted.
    private func refusal(for foreground: BridgeForeground) -> BridgeToolResult? {
        switch foreground {
        case .home, .allowed:
            return nil
        case .blocked:
            return .error(Self.lockedOutMessage, status: .lockedOut)
        case .phoneLocked:
            return .error(Self.phoneLockedMessage, status: .phoneLocked)
        case .unverified(let reason):
            return .error("could not verify which app is in front, so nothing was done: \(reason)")
        }
    }

    /// Runs `body` only while the home screen or an allowlisted app is in
    /// front, and re-checks afterwards. One guarded call runs at a time.
    ///
    /// - Parameter body: receives the pre-check reading. It may refuse by
    ///   returning an error result without touching the raw API.
    func guarded(_ body: (BridgeProbe) -> BridgeToolResult) -> BridgeToolResult {
        runLock.lock(); defer { runLock.unlock() }

        let before = probe()
        if let refused = refusal(for: before.foreground) { return refused }

        let result = body(before)
        // A refusal that never reached the phone needs no second check.
        if result.status == .refused { return result }

        // An app that is still launching can be unnameable for a moment. Give
        // it a short grace period before calling it a lockout; nothing else
        // runs meanwhile, because the run lock is held.
        var after = probe(record: false)
        var retries = settleRetries
        while case .blocked = after.foreground, retries > 0 {
            sleep(settleDelay)
            after = probe(record: false)
            retries -= 1
        }
        note(after.foreground)
        switch after.foreground {
        case .home, .allowed:
            return result
        case .blocked:
            // Whatever was captured or reported may describe the blocked app.
            return .error(Self.lockedAfterMessage, status: .lockedOut)
        case .phoneLocked:
            return .error(Self.phoneLockedMessage, status: .phoneLocked)
        case .unverified(let reason):
            // The screen cannot be vouched for, so no content leaves.
            return .error("the action ran, but the foreground app could not be verified afterwards, so its result was withheld: \(reason)")
        }
    }

    /// Presses Home. The only action permitted during lockout.
    func goHome() -> BridgeToolResult {
        runLock.lock(); defer { runLock.unlock() }

        let before = probe()
        if case .phoneLocked = before.foreground {
            return .error(Self.phoneLockedMessage, status: .phoneLocked)
        }
        let pressed = raw.call("home", [:])
        let after = probe()
        switch after.foreground {
        case .home:
            return .text("Home screen is in front. All tools are available.")
        case .allowed:
            return .text("An allowlisted app is in front. All tools are available.")
        case .phoneLocked:
            return .error(Self.phoneLockedMessage, status: .phoneLocked)
        case .blocked, .unverified:
            if case .failure = pressed {
                return .error("go_home failed: the Home press did not go through. The bridge is still locked; try again.", status: .lockedOut)
            }
            return .error("go_home pressed Home, but the home screen is not in front yet. The bridge is still locked; try again.", status: .lockedOut)
        }
    }
}
