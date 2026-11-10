import Foundation

/// Works out which app is in front, for the bridge's guard.
///
/// iCTRL's own answer is not used for this. On iOS 27 it names the front app
/// by asking known apps whether they are "in the foreground", and that state
/// lags by seconds; with an app shown in a window the frontmost process is
/// the system's window host, so the first app with a stale state was named
/// (and remembered) as the front app. Here a process id has to agree.
///
/// (Asking iOS which process owns the element at a screen point was tried
/// too. It answers "SpringBoard" for a windowed app, so it cannot tell the
/// apps apart.)
enum ClaudeBridgeScreenProbe {
    static let search = "com.apple.campo"
    /// XCUIApplication.State.runningForeground
    private static let runningForeground = 4

    /// Hops to the main thread, like every other use of XCTest in this runner.
    static func inspect(allowlist: BridgeAllowlistProvider) -> BridgeScreenInspection {
        var result = BridgeScreenInspection(foregroundBundle: nil, appWindow: nil)
        let work = { result = BridgeScreenInspection(foregroundBundle: frontBundleOnMain(allowlist: allowlist), appWindow: nil) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    private static func foreground(_ bundles: [String]) -> [String: Int32] {
        var out: [String: Int32] = [:]
        for bundle in bundles where bundle != search && bundle != BridgeGuard.springboard {
            guard ForegroundApp.appState(forBundleID: bundle) == runningForeground else { continue }
            let pid = ForegroundApp.processID(forBundleID: bundle)
            if pid > 0 { out[bundle] = pid }
        }
        return out
    }

    private static func frontBundleOnMain(allowlist: BridgeAllowlistProvider) -> String? {
        let frontPID = ForegroundApp.frontmostPID()
        let springboardPID = ForegroundApp.processID(forBundleID: BridgeGuard.springboard)
        let searchPID = ForegroundApp.processID(forBundleID: search)
        let searchActive = ForegroundApp.appState(forBundleID: search) == runningForeground

        // Usually the frontmost process is an allowlisted app, or SpringBoard.
        var apps = foreground(allowlist.allowedApps.map(\.bundleID))
        let windowed = frontPID == searchPID && searchPID > 0 && !searchActive
        if windowed {
            // An app is shown in a window. Before naming it, look at every
            // app the phone is known to have, so a second foreground claim
            // (from an app that is not allowlisted) is noticed.
            let started = ProcessInfo.processInfo.systemUptime
            let others = installedBundles().filter { apps[$0] == nil }
            apps.merge(foreground(others)) { a, _ in a }
            noteScanCost(ProcessInfo.processInfo.systemUptime - started, count: others.count)
        }
        if ProcessInfo.processInfo.environment["ICTRL_BRIDGE_DIAG"] == "1" {
            let line = "front=\(frontPID) springboard=\(springboardPID) search=\(searchPID) searchActive=\(searchActive) windowed=\(windowed) foreground=\(apps.map { "\($0.key.suffix(14)):\($0.value)" })"
            if line != lastDiag { lastDiag = line; iCTRLUITests.logBuffer.append("🤖🔬 \(line)") }
        }
        return BridgeForegroundDecision.decide(
            frontPID: frontPID, springboardPID: springboardPID, searchPID: searchPID, searchActive: searchActive,
            foregroundApps: apps, springboard: BridgeGuard.springboard, search: search)
    }

    private static var lastDiag = ""

    // MARK: Installed apps (cached; the list rarely changes)

    private static var installed: (at: TimeInterval, bundles: [String])?

    private static func installedBundles() -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = installed, now - c.at < 600 { return c.bundles }
        let bundles = ClaudeBridgeInstalledApps.list().apps.filter(\.isUser).map(\.bundleID)
        installed = (now, bundles)
        return bundles
    }

    private static var loggedScan = false
    private static func noteScanCost(_ seconds: TimeInterval, count: Int) {
        guard !loggedScan else { return }
        loggedScan = true
        iCTRLUITests.logBuffer.append(String(format: "🤖 windowed app check: asked %d apps for their state in %.0f ms", count, seconds * 1000))
    }
}
