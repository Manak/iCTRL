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
    /// System surfaces treated like the home screen: always permitted, never
    /// launchable through launch_app, not part of the editable allowlist.
    /// On iOS 27 the pull-down search is its own process, "Siri AI", whose
    /// bundle id is com.apple.campo (read from the device's system log).
    static let systemSurfaces = [
        BridgeAllowedApp(bundleID: "com.apple.campo", name: "Search"),
    ]
    static let lockedOutMessage =
        "locked: non-allowlisted app in foreground. Only go_home is available; call it to return to the home screen."
    static let phoneLockedMessage =
        "phone locked: the lock screen or Notification Centre is showing. The phone's owner must unlock or dismiss it before any action can run."
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
                // SpringBoard also hosts the app switcher, which shows other
                // apps' screens. Only the real home screen counts as home.
                foreground = springboardShowsHomeScreen()
            } else if let app = allowlist.app(bundleID: bundle) ?? Self.systemSurfaces.first(where: { $0.bundleID == bundle }) {
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

    /// Looks at SpringBoard's own UI tree to tell the home screen from the
    /// other things SpringBoard shows. Fails closed: home needs positive
    /// evidence (the icon grid) and no sign of the app switcher.
    private func springboardShowsHomeScreen() -> BridgeForeground {
        let result = raw.call("page_source", [
            "bundle_id": Self.springboard, "visible_only": true, "max_children": 50,
        ])
        guard case .success(let page) = result, let source = page["source"] as? String else {
            var reason = "home screen could not be inspected"
            if case .failure(let message) = result { reason = message }
            return .unverified(reason)
        }
        return Self.isHomeScreen(springboardSource: source) ? .home : .blocked
    }

    /// Element ids, as they appear in iCTRL's page_source text on iOS 27.
    static let homeScreenMarker = "id: 'Home screen icons'"
    /// App switcher and Control Centre. (On iOS 27 Control Centre already
    /// hides the icon grid; its marker is here as a second line of defence.)
    static let notHomeMarkers = ["AppSwitcherContentView", "SBSwitcherWindow", "cc-root-folder-view"]

    static func isHomeScreen(springboardSource source: String) -> Bool {
        guard source.contains(homeScreenMarker) else { return false }
        return !notHomeMarkers.contains { source.contains($0) }
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

    /// Runs `body` with no tool call in flight (and none starting meanwhile).
    func exclusive<T>(_ body: () -> T) -> T {
        runLock.lock(); defer { runLock.unlock() }
        return body()
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
        let after = settledProbe()
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

    /// Reads the foreground, re-checking a blocked reading a few times before
    /// accepting it. Records the final reading only.
    private func settledProbe() -> BridgeProbe {
        var reading = probe(record: false)
        var retries = settleRetries
        while case .blocked = reading.foreground, retries > 0 {
            sleep(settleDelay)
            reading = probe(record: false)
            retries -= 1
        }
        note(reading.foreground)
        return reading
    }

    /// Returns to the home screen. The only action permitted during lockout.
    ///
    /// It brings SpringBoard forward as an app, then falls back to the Home
    /// button. It does not use the bottom-edge swipe: that gesture can stop in
    /// the app switcher, which shows other apps' screens.
    func goHome() -> BridgeToolResult {
        runLock.lock(); defer { runLock.unlock() }

        let before = probe()
        switch before.foreground {
        case .phoneLocked:
            return .error(Self.phoneLockedMessage, status: .phoneLocked)
        case .home:
            return .text("Home screen is in front. All tools are available.")
        default:
            break
        }

        _ = raw.call("activate_app", ["bundle_id": Self.springboard])
        var after = settledProbe()
        // Stop as soon as something permitted is in front. (The iOS 27 search
        // screen ignores both methods and stays up; it is permitted, so that
        // is reported as it is rather than paid for with a slow Home press.)
        var clear = false
        switch after.foreground {
        case .home, .allowed: clear = true
        default: break
        }
        if !clear {
            _ = raw.call("home", [:])
            after = settledProbe()
        }
        switch after.foreground {
        case .home:
            return .text("Home screen is in front. All tools are available.")
        case .allowed(let app):
            return .text("\(app.name) is in front, which is permitted. All tools are available.")
        case .phoneLocked:
            return .error(Self.phoneLockedMessage, status: .phoneLocked)
        case .blocked, .unverified:
            return .error("go_home could not bring the home screen to the front. The bridge is still locked; try again, or ask the phone's owner to return to the home screen.", status: .lockedOut)
        }
    }
}
