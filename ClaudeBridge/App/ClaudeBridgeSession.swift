import ActivityKit
import Foundation
import UIKit

/// Starts and stops a Claude session from the companion app, and keeps the
/// Live Activity in step with what the runner reports. Used by the Shortcuts
/// actions, the Live Activity's Stop button and the Claude Bridge screen.
@MainActor
final class ClaudeBridgeSession {
    static let shared = ClaudeBridgeSession()

    /// Result of an action, for Shortcuts. Never contains the URL secret.
    struct Outcome {
        var ok: Bool
        /// Machine-readable: "live", "stopped", "failed", …
        var value: String
        /// One sentence for the person.
        var message: String
    }

    private static let startURL = URL(string: "ictrl://start?callback=ictrl-app://started")!

    private func call(_ action: String, _ extra: [String: Any] = [:], timeout: TimeInterval = 8) async throws -> [String: Any] {
        var params = extra
        params["action"] = action
        return try await RunnerClient(port: 8200).call("claude_bridge", params, timeout: timeout)
    }

    private func status() async throws -> ClaudeBridgeStatus {
        ClaudeBridgeStatus(try await call("status"))
    }

    // MARK: Start

    /// Starts the runner if needed, switches Claude via Funnel on, waits for
    /// the address to go live and shows the Live Activity.
    func start() async -> Outcome {
        guard RunnerClient(port: 8200).isPaired else {
            return Outcome(ok: false, value: "not_paired",
                           message: "Open iCTRL, go to Claude Bridge and connect to the runner once before using this action.")
        }
        // Ask for a little background time: opening the runner takes this app
        // off screen for a few seconds before the runner hands back.
        let task = UIApplication.shared.beginBackgroundTask(withName: "claude-bridge-start")
        defer { UIApplication.shared.endBackgroundTask(task) }

        var current = try? await status()
        if current == nil {
            guard DeveloperDiskImage.status().isMounted else {
                return Outcome(ok: false, value: "ddi_not_mounted",
                               message: "The Developer Disk Image is not mounted. Run Remount Developer Disk Image first.")
            }
            guard await UIApplication.shared.open(Self.startURL) else {
                return Outcome(ok: false, value: "runner_not_installed",
                               message: "Couldn't open the iCTRL runner. Is it installed?")
            }
            current = await waitFor(seconds: 30) { _ in true }
            guard current != nil else {
                return Outcome(ok: false, value: "runner_not_responding",
                               message: "The runner did not come up. Open it once by hand; iOS may be asking for your passcode.")
            }
        }

        if current?.mode != "funnel" {
            do { current = ClaudeBridgeStatus(try await call("set_mode", ["mode": "funnel"])) }
            catch { return Outcome(ok: false, value: "failed", message: Self.describe(error)) }
        }

        let live = await waitFor(seconds: 60) { $0.tunnelState == "running" || $0.tunnelState == "error" || $0.tunnelState == "needs_login" }
        guard let live = live, live.tunnelState == "running" else {
            let reason = live?.tunnelError ?? (live?.tunnelState == "needs_login" ? "A Tailscale auth key is needed." : "Funnel did not come up in time.")
            return Outcome(ok: false, value: live?.tunnelState ?? "timeout", message: reason)
        }
        await sync(live)
        return Outcome(ok: true, value: "live", message: "Claude Bridge is live at \(live.host ?? "your Funnel address").")
    }

    /// Polls the runner until `done` accepts a status or time runs out.
    private func waitFor(seconds: Double, until done: (ClaudeBridgeStatus) -> Bool) async -> ClaudeBridgeStatus? {
        let deadline = Date().addingTimeInterval(seconds)
        var last: ClaudeBridgeStatus?
        while Date() < deadline {
            if let s = try? await status() {
                last = s
                if done(s) { return s }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return last.flatMap { done($0) ? $0 : nil } ?? last
    }

    // MARK: Stop

    /// Stops the public address, the bridge, the raw API and the runner.
    func stop() async -> Outcome {
        defer { Task { await self.endActivity() } }
        do {
            // iCTRL's own stop: the runner's run loop exits and takes the
            // bridge and the Funnel connection down with it.
            _ = try await RunnerClient(port: 8200).call("config", ["stop_server": true], timeout: 6)
            return Outcome(ok: true, value: "stopped", message: "Session stopped. Nothing is reachable from the internet.")
        } catch RunnerClient.Failure.notRunning {
            return Outcome(ok: true, value: "stopped", message: "The runner was not running.")
        } catch RunnerClient.Failure.notPaired {
            return Outcome(ok: false, value: "not_paired", message: "This app is not connected to the runner. Stop it from its notification instead.")
        } catch {
            return Outcome(ok: false, value: "failed", message: Self.describe(error))
        }
    }

    // MARK: Remount

    func remount() async -> Outcome {
        if DeveloperDiskImage.status().isMounted {
            return Outcome(ok: true, value: "mounted", message: "The Developer Disk Image is already mounted.")
        }
        let mounter = DDIMounter()
        await mounter.mount()
        while mounter.isRunning { try? await Task.sleep(nanoseconds: 300_000_000) }
        switch mounter.phase {
        case .mounted:
            return Outcome(ok: true, value: "mounted", message: "Developer Disk Image mounted.")
        case .failed(let why):
            return Outcome(ok: false, value: "failed", message: why)
        default:
            let mounted = DeveloperDiskImage.status().isMounted
            return Outcome(ok: mounted, value: mounted ? "mounted" : "failed",
                           message: mounted ? "Developer Disk Image mounted." : "The mount did not finish.")
        }
    }

    // MARK: Live Activity

    /// Asks the runner how things stand and updates the Live Activity.
    func refreshAndSync() async {
        guard RunnerClient(port: 8200).isPaired else { return }
        do { await sync(try await status()) }
        catch RunnerClient.Failure.notRunning { await endActivity() }
        catch { /* leave the activity as it is; it goes stale on its own */ }
    }

    /// Shows, updates or removes the Live Activity to match `status`.
    func sync(_ status: ClaudeBridgeStatus) async {
        guard #available(iOS 17.0, *) else { return }
        let live = status.running && status.mode == "funnel"
        guard live, let host = status.host else {
            await endActivity()
            return
        }
        let phase = status.tunnelState == "running" ? "live" : "starting"
        let state = ClaudeBridgeActivityAttributes.ContentState(phase: phase, checkedAt: Date(), endsAt: status.endsAt)
        // After this moment the session may have ended without this app
        // hearing about it, so the activity marks itself as needing a check.
        let stale = (status.endsAt ?? Date().addingTimeInterval(30 * 60)).addingTimeInterval(60)
        let content = ActivityContent(state: state, staleDate: stale)

        if let activity = Activity<ClaudeBridgeActivityAttributes>.activities.first {
            await activity.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled,
                  UIApplication.shared.applicationState == .active {
            let attributes = ClaudeBridgeActivityAttributes(host: host, startedAt: status.sessionStarted ?? Date())
            _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
        // Tell the runner whether its own status notification is still needed.
        let showing = !Activity<ClaudeBridgeActivityAttributes>.activities.isEmpty
        _ = try? await call("live_activity", ["showing": showing])
    }

    func endActivity() async {
        guard #available(iOS 17.0, *) else { return }
        for activity in Activity<ClaudeBridgeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
