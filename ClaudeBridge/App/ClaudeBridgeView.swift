import SwiftUI
import UIKit

// Companion-app screens for the Claude bridge. Everything here talks to the
// runner over the app's existing paired channel (`RunnerClient`), using the
// runner's `claude_bridge` method. The URL secret is never drawn on screen
// and never kept in view state: it goes from the runner straight to the
// pasteboard when the owner taps Copy.

/// One row in Settings that opens the bridge screen.
struct ClaudeBridgeSettingsLink: View {
    var body: some View {
        Section {
            NavigationLink {
                ClaudeBridgeView()
            } label: {
                Label("Claude Bridge", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } footer: {
            Text("Let the Claude app operate allowlisted apps on this phone through a private Tailscale Funnel address.")
        }
        // Whenever the app comes to the front, bring the Live Activity in
        // line with the runner (it may have stopped while this app slept).
        .task { await ClaudeBridgeSession.shared.refreshAndSync() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await ClaudeBridgeSession.shared.refreshAndSync() }
        }
    }
}

/// What the runner reports. Holds nothing secret.
struct ClaudeBridgeStatus: Equatable {
    var mode = "off"
    var running = false
    var tunnelState = "stopped"
    var tunnelError: String?
    var host: String?
    var hostname = ""
    var hasAuthKey = false
    var lockedOut = false
    var sessionStarted: Date?
    /// When the session ends if Claude stays quiet.
    var endsAt: Date?
    var idleLimitMinutes = 30.0
    var allowedAppNames: [String] = []

    init() {}

    init(_ result: [String: Any]) {
        mode = result["mode"] as? String ?? "off"
        running = result["running"] as? Bool ?? false
        tunnelState = result["tunnel_state"] as? String ?? "stopped"
        tunnelError = result["tunnel_error"] as? String
        host = result["host"] as? String
        hostname = result["hostname"] as? String ?? ""
        hasAuthKey = result["has_auth_key"] as? Bool ?? false
        lockedOut = result["locked_out"] as? Bool ?? false
        sessionStarted = (result["session_started"] as? Double).map(Date.init(timeIntervalSince1970:))
        endsAt = (result["ends_at"] as? Double).map(Date.init(timeIntervalSince1970:))
        idleLimitMinutes = result["idle_limit_minutes"] as? Double ?? 30
        allowedAppNames = (result["allowed_apps"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}

@MainActor
final class ClaudeBridgeModel: ObservableObject {
    @Published private(set) var status: ClaudeBridgeStatus?
    @Published private(set) var busy = false
    /// Short, non-secret message about the last action.
    @Published var notice: String?
    @Published private(set) var runnerDown = false

    private func call(_ action: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        var params = extra
        params["action"] = action
        // A fresh client picks up the pairing key the app already holds.
        return try await RunnerClient(port: 8200).call("claude_bridge", params)
    }

    func refresh() async {
        do {
            let fresh = ClaudeBridgeStatus(try await call("status"))
            status = fresh
            runnerDown = false
            await ClaudeBridgeSession.shared.sync(fresh)
        } catch RunnerClient.Failure.notRunning {
            runnerDown = true
            status = nil
            await ClaudeBridgeSession.shared.endActivity()
        } catch RunnerClient.Failure.notPaired, RunnerClient.Failure.keyRejected {
            status = nil
        } catch {
            notice = Self.describe(error)
        }
    }

    func setFunnel(_ on: Bool) async {
        await run {
            self.status = ClaudeBridgeStatus(try await self.call("set_mode", ["mode": on ? "funnel" : "off"]))
            self.notice = on ? "Claude via Funnel is on. The address goes live in a few seconds." : "Claude via Funnel is off. Nothing is reachable from the internet."
        }
    }

    func stopSession() async {
        await run {
            let outcome = await ClaudeBridgeSession.shared.stop()
            self.notice = outcome.message
            self.status = nil
            self.runnerDown = outcome.ok
        }
    }

    func saveAuthKey(_ key: String) async -> Bool {
        var ok = false
        await run {
            self.status = ClaudeBridgeStatus(try await self.call("set_auth_key", ["auth_key": key]))
            self.notice = key.isEmpty ? "Auth key removed." : "Auth key saved in the runner's keychain."
            ok = true
        }
        return ok
    }

    /// Fetches the full URL and puts it on the pasteboard. It stays on this
    /// device and expires, and it is never stored in this object.
    func copyURL() async {
        await run {
            let result = try await self.call("connector_url")
            guard let url = result["url"] as? String else { throw RunnerClient.Failure.server("The runner returned no address.") }
            Self.putOnPasteboard(url)
            self.notice = "Address copied. It clears from the clipboard in 2 minutes."
        }
    }

    func rotate() async {
        await run {
            let result = try await self.call("rotate_secret")
            guard let url = result["url"] as? String else { throw RunnerClient.Failure.server("The runner returned no address.") }
            Self.putOnPasteboard(url)
            self.notice = "Secret rotated. The old address no longer works. The new one is on the clipboard: update the connector in Claude."
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await work()
            runnerDown = false
        } catch RunnerClient.Failure.notRunning {
            runnerDown = true
            notice = "The runner is not running. Start it first."
        } catch {
            notice = Self.describe(error)
        }
    }

    private static func putOnPasteboard(_ text: String) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct ClaudeBridgeView: View {
    @EnvironmentObject private var admin: RunnerAdmin
    @StateObject private var model = ClaudeBridgeModel()
    @State private var authKey = ""
    @State private var confirmRotate = false

    var body: some View {
        List {
            if !admin.isPaired {
                pairSection
            } else if model.runnerDown {
                Section {
                    Text("The runner is not running. Start the server from the main screen, then come back.")
                        .foregroundColor(.secondary)
                }
            } else if let status = model.status {
                modeSection(status)
                allowlistSection(status)
                addressSection(status)
                tailscaleSection(status)
            } else {
                Section { ProgressView() }
            }
            if let notice = model.notice {
                Section { Text(notice).font(.callout).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("Claude Bridge")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Light polling while the screen is open, so "starting" turns
            // into "live" without a manual refresh.
            while !Task.isCancelled {
                if admin.isPaired { await model.refresh() }
                // Fast while something is changing, slow once it is settled:
                // each poll is a line in the runner's log.
                let settling = model.status.map { $0.mode == "funnel" && $0.tunnelState != "running" } ?? true
                try? await Task.sleep(nanoseconds: settling ? 3_000_000_000 : 15_000_000_000)
            }
        }
        .confirmationDialog("Rotate the secret?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate and copy new address", role: .destructive) {
                Task { await model.rotate() }
            }
        } message: {
            Text("The current address stops working immediately. You will need to update the connector in Claude with the new one.")
        }
    }

    private var pairSection: some View {
        Section {
            Text("This app needs a one-time approval from the runner before it can manage the bridge. Start the runner, tap Connect, then long-press the runner's notification and choose Allow.")
                .font(.callout)
                .foregroundColor(.secondary)
            Button {
                Task { await admin.connect() }
            } label: {
                if admin.pairing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for approval…") }
                } else {
                    Label("Connect to runner", systemImage: "link")
                }
            }
            .disabled(admin.pairing)
        }
    }

    private func modeSection(_ status: ClaudeBridgeStatus) -> some View {
        Section {
            Toggle("Claude via Funnel", isOn: Binding(
                get: { status.mode == "funnel" },
                set: { on in Task { await model.setFunnel(on) } }))
                .disabled(model.busy)
            HStack {
                Text("Status")
                Spacer()
                Text(Self.statusText(status)).foregroundColor(Self.statusColor(status))
            }
            if status.lockedOut {
                Label("Locked: a non-allowlisted app is in front", systemImage: "lock.fill")
                    .foregroundColor(.orange)
            }
            if let error = status.tunnelError {
                Text(error).font(.footnote).foregroundColor(.orange)
            }
            if status.running, let ends = status.endsAt {
                HStack {
                    Text("Auto-off if idle")
                    Spacer()
                    Text(ends, style: .time).foregroundColor(.secondary)
                }
            }
            if status.running {
                Button(role: .destructive) {
                    Task { await model.stopSession() }
                } label: {
                    Label("Stop session", systemImage: "stop.circle")
                }
                .disabled(model.busy)
            }
        } footer: {
            Text("While this is on, the raw iCTRL API is limited to this device and only the Claude bridge is reachable from outside. The session ends by itself after \(Int(status.idleLimitMinutes)) minutes without a request from Claude. Stop session shuts down the address, the bridge and the runner.")
        }
    }

    private func allowlistSection(_ status: ClaudeBridgeStatus) -> some View {
        Section {
            NavigationLink {
                ClaudeBridgeAllowlistView()
            } label: {
                HStack {
                    Label("Allowed apps", systemImage: "checklist")
                    Spacer()
                    Text(status.allowedAppNames.isEmpty ? "None" : status.allowedAppNames.prefix(2).joined(separator: ", ")
                         + (status.allowedAppNames.count > 2 ? " +\(status.allowedAppNames.count - 2)" : ""))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text("Claude can only read and act inside these apps, the home screen and search.")
        }
    }

    private func addressSection(_ status: ClaudeBridgeStatus) -> some View {
        Section {
            if let host = status.host {
                // The secret segment is never shown, so a screenshot or a
                // screen recording of this screen cannot leak it.
                Text(verbatim: "https://\(host)/••••••••/mcp")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.disabled)
                Button {
                    Task { await model.copyURL() }
                } label: {
                    Label("Copy address", systemImage: "doc.on.doc")
                }
                .disabled(model.busy)
                Button(role: .destructive) {
                    confirmRotate = true
                } label: {
                    Label("Rotate secret", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.busy)
            } else {
                Text("The address appears once Funnel has been live for the first time.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Connector address")
        } footer: {
            Text("Paste this into Claude as a custom connector. Anyone who has it can use the bridge, so treat it like a password. The host name never changes; only the hidden part does when you rotate.")
        }
    }

    private func tailscaleSection(_ status: ClaudeBridgeStatus) -> some View {
        Section {
            HStack {
                Text("Device name")
                Spacer()
                Text(status.hostname).foregroundColor(.secondary)
            }
            HStack {
                Text("Auth key")
                Spacer()
                Text(status.hasAuthKey ? "Saved" : "Not set").foregroundColor(.secondary)
            }
            SecureField("tskey-auth-…", text: $authKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save auth key") {
                let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { if await model.saveAuthKey(key) { authKey = "" } }
            }
            .disabled(model.busy || authKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Tailscale")
        } footer: {
            Text("Create a one-off key tagged tag:ictrl in the Tailscale admin console. It is used once to join your tailnet and is stored only in the runner's keychain.")
        }
    }

    private static func statusText(_ status: ClaudeBridgeStatus) -> String {
        guard status.mode == "funnel" else { return "Off" }
        switch status.tunnelState {
        case "running": return "Live"
        case "starting": return "Starting…"
        case "needs_login": return "Needs auth key"
        case "error": return "Error"
        default: return "Stopped"
        }
    }

    private static func statusColor(_ status: ClaudeBridgeStatus) -> Color {
        guard status.mode == "funnel" else { return .secondary }
        switch status.tunnelState {
        case "running": return .green
        case "error", "needs_login": return .orange
        default: return .secondary
        }
    }
}
