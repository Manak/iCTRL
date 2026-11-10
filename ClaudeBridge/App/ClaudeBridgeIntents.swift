import AppIntents
import Foundation

// Shortcuts actions for the companion app. "Stop Session" lives in
// ClaudeBridge/Shared because the Live Activity's button uses it too.

/// Starts a session: the runner, Claude via Funnel and the Live Activity.
/// It has to bring iCTRL to the front, because iOS only lets a foreground app
/// launch the runner.
@available(iOS 17.0, *)
struct StartClaudeSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Session"
    static var description = IntentDescription("Starts the iCTRL runner in Claude via Funnel mode and waits for the address to go live. Returns the host name, never the secret.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let outcome = await ClaudeBridgeSession.shared.start()
        return .result(value: outcome.value, dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

/// Remounts the Developer Disk Image, which iOS drops on every reboot. Needs
/// LocalDevVPN connected, Wi-Fi, and the pairing file and image already set
/// up in the app.
@available(iOS 17.0, *)
struct RemountDeveloperDiskImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Remount Developer Disk Image"
    static var description = IntentDescription("Mounts the Developer Disk Image so the iCTRL runner can launch, for example after a reboot. Reports success or the reason it failed.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let outcome = await ClaudeBridgeSession.shared.remount()
        return .result(value: outcome.value, dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

@available(iOS 17.0, *)
struct ClaudeBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartClaudeSessionIntent(),
                    phrases: ["Start \(.applicationName) session", "Start a Claude session with \(.applicationName)"],
                    shortTitle: "Start Session", systemImageName: "play.circle")
        AppShortcut(intent: StopClaudeSessionIntent(),
                    phrases: ["Stop \(.applicationName) session", "Stop the Claude session with \(.applicationName)"],
                    shortTitle: "Stop Session", systemImageName: "stop.circle")
        AppShortcut(intent: RemountDeveloperDiskImageIntent(),
                    phrases: ["Remount \(.applicationName) disk image"],
                    shortTitle: "Remount Disk Image", systemImageName: "externaldrive.badge.checkmark")
    }
}
