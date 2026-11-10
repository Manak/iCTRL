import Foundation
import XCTest

/// Asks an app to bring one of its elements into view by itself.
///
/// This is the accessibility "scroll to visible" action, the same one XCTest
/// uses before tapping an off-screen element. The app scrolls programmatically
/// to the right place in one go, instead of the bridge dragging the list a
/// screen at a time.
enum ClaudeBridgeJump {
    /// Longest the element lookup may take before giving up on the jump.
    private static let lookupTimeout: TimeInterval = 4

    static func scrollToVisible(bundleID: String, text: String, contains: Bool, occurrence: Int) -> Bool {
        var ok = false
        let work = { ok = onMain(bundleID: bundleID, text: text, contains: contains, occurrence: occurrence) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return ok
    }

    private static func onMain(bundleID: String, text: String, contains: Bool, occurrence: Int) -> Bool {
        var ok = false
        let started = ProcessInfo.processInfo.systemUptime
        let failure = ObjCException.catching {
            let app = XCUIApplication(bundleIdentifier: bundleID)
            let predicate = contains
                ? NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", text, text)
                : NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", text, text)
            let element = app.descendants(matching: .any).matching(predicate).element(boundBy: max(0, occurrence - 1))
            guard element.waitForExistence(timeout: lookupTimeout) else { return }
            let selector = NSSelectorFromString("scrollToVisible")
            guard element.responds(to: selector) else { return }
            _ = element.perform(selector)
            ok = true
        }
        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let failure = failure {
            iCTRLUITests.logBuffer.append("🤖 jump to element failed after \(ms) ms: \(failure.prefix(120))")
            return false
        }
        iCTRLUITests.logBuffer.append("🤖 jump to element: \(ok ? "asked the app to scroll" : "element not found") (\(ms) ms)")
        return ok
    }
}
