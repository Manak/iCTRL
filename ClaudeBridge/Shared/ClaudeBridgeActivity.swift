import ActivityKit
import AppIntents
import Foundation

// Shared by the companion app and its widget extension: the Live Activity's
// data, and the Stop button's intent. The intent's real work happens in the
// app (iOS runs Live Activity intents in the app's process); the extension
// only needs the type to exist so the button can name it.

@available(iOS 17.0, *)
struct ClaudeBridgeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "live", "starting" or "ended".
        var phase: String
        /// When the companion last heard from the runner.
        var checkedAt: Date
        /// When the session will end if Claude stays quiet, as of `checkedAt`.
        var endsAt: Date?
    }

    /// Public host name only. The URL secret is never part of the activity.
    var host: String
    var startedAt: Date
}

/// Ends the session: the public address, the bridge, the raw API and the
/// runner. This is the Stop button on the Live Activity and the "Stop Session"
/// action in Shortcuts.
@available(iOS 17.0, *)
struct StopClaudeSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Session"
    static var description = IntentDescription("Stops the Claude bridge, its Funnel address and the iCTRL runner. Nothing is reachable afterwards.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        #if CLAUDE_BRIDGE_WIDGET
        // Never executed here: iOS runs this intent in the app.
        return .result(value: "unavailable", dialog: "Open iCTRL to stop the session.")
        #else
        let outcome = await ClaudeBridgeSession.shared.stop()
        return .result(value: outcome.value, dialog: IntentDialog(stringLiteral: outcome.message))
        #endif
    }
}
