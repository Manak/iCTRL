import SwiftUI

/// One app, as the companion shows it.
struct ClaudeBridgeApp: Identifiable, Equatable {
    var bundleID: String
    var name: String
    var readOnly = false
    /// False for apps that ship with iOS.
    var isUser = true
    var id: String { bundleID }

    init(bundleID: String, name: String, readOnly: Bool = false, isUser: Bool = true) {
        self.bundleID = bundleID
        self.name = name
        self.readOnly = readOnly
        self.isUser = isUser
    }

    init?(_ entry: [String: Any]) {
        guard let bundle = entry["bundle_id"] as? String, !bundle.isEmpty else { return nil }
        bundleID = bundle
        let given = entry["name"] as? String ?? ""
        name = given.isEmpty ? bundle : given
        readOnly = entry["read_only"] as? Bool ?? false
        isUser = entry["user"] as? Bool ?? true
    }

    var json: [String: Any] { ["bundle_id": bundleID, "name": name, "read_only": readOnly] }
}

@MainActor
final class ClaudeBridgeAllowlistModel: ObservableObject {
    /// Apps Claude may operate.
    @Published private(set) var allowed: [ClaudeBridgeApp] = []
    /// Apps the phone reports as installed.
    @Published private(set) var installed: [ClaudeBridgeApp] = []
    /// True when iOS only let the runner see some of the installed apps.
    @Published private(set) var partial = false
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var notice: String?

    private func call(_ action: String, _ extra: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        var params = extra
        params["action"] = action
        return try await RunnerClient(port: 8200).call("claude_bridge", params, timeout: timeout)
    }

    func load() async {
        do {
            allowed = Self.parse(try await call("status"), key: "allowed_apps")
            let listing = try await call("installed_apps", timeout: 30)
            installed = Self.parse(listing, key: "apps")
            partial = listing["partial"] as? Bool ?? false
            loaded = true
        } catch {
            notice = Self.describe(error)
        }
    }

    func isAllowed(_ app: ClaudeBridgeApp) -> Bool {
        allowed.contains { $0.bundleID == app.bundleID }
    }

    /// Every app to show: the installed ones, plus any allowed app the phone
    /// did not report (so it can still be switched off).
    var rows: [ClaudeBridgeApp] {
        let known = Set(installed.map(\.bundleID))
        return installed + allowed.filter { !known.contains($0.bundleID) }
    }

    func setAllowed(_ app: ClaudeBridgeApp, _ on: Bool) async {
        var next = allowed.filter { $0.bundleID != app.bundleID }
        if on { next.append(ClaudeBridgeApp(bundleID: app.bundleID, name: app.name)) }
        await save(next)
    }

    func setReadOnly(_ app: ClaudeBridgeApp, _ on: Bool) async {
        await save(allowed.map { $0.bundleID == app.bundleID ? ClaudeBridgeApp(bundleID: $0.bundleID, name: $0.name, readOnly: on) : $0 })
    }

    func addByBundleID(_ id: String) async {
        guard !allowed.contains(where: { $0.bundleID == id }) else { return }
        await save(allowed + [ClaudeBridgeApp(bundleID: id, name: id)])
    }

    /// Sends the whole list. The runner filters it and answers with what it
    /// kept, which is what this screen then shows.
    private func save(_ next: [ClaudeBridgeApp]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await call("set_allowlist", ["apps": next.map(\.json)])
            allowed = Self.parse(reply, key: "allowed_apps")
            let rejected = reply["rejected"] as? [String] ?? []
            notice = rejected.isEmpty ? nil
                : "Not allowed: \(rejected.joined(separator: ", ")). Settings, the App Store, Wallet, Shortcuts and iCTRL itself can never be switched on."
        } catch {
            notice = Self.describe(error)
        }
    }

    private static func parse(_ reply: [String: Any], key: String) -> [ClaudeBridgeApp] {
        (reply[key] as? [[String: Any]] ?? []).compactMap(ClaudeBridgeApp.init)
    }

    private static func describe(_ error: Error) -> String {
        if case RunnerClient.Failure.notRunning = error { return "The runner is not running. Start it first." }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The allowlist: every installed app with a switch. The list lives in the
/// runner and can only be changed from this phone; no MCP tool can touch it.
struct ClaudeBridgeAllowlistView: View {
    @StateObject private var model = ClaudeBridgeAllowlistModel()
    @State private var filter = ""
    @State private var bundleID = ""

    private var shown: [ClaudeBridgeApp] {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = model.rows
        guard !term.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(term) || $0.bundleID.lowercased().contains(term) }
    }

    var body: some View {
        List {
            if !model.loaded {
                Section { ProgressView() }
            } else {
                let allowed = shown.filter { model.isAllowed($0) }
                let others = shown.filter { !model.isAllowed($0) }

                if !allowed.isEmpty || filter.isEmpty {
                    Section {
                        if allowed.isEmpty {
                            Text("No apps are switched on. Claude can only see the home screen and search.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(allowed) { app in row(app, isOn: true) }
                    } header: {
                        Text("Allowed")
                    }
                }

                Section {
                    ForEach(others.filter(\.isUser)) { app in row(app, isOn: false) }
                } header: {
                    Text("Installed apps")
                } footer: {
                    if model.partial {
                        Text("iOS only shows the runner apps that include an extension (most do) and apps it has opened before. If one is missing, add it by bundle id below.")
                    }
                }

                let system = others.filter { !$0.isUser }
                if !system.isEmpty {
                    Section {
                        ForEach(system) { app in row(app, isOn: false) }
                    } header: {
                        Text("Apple apps")
                    }
                }

                Section {
                    HStack {
                        TextField("com.example.app", text: $bundleID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Add") {
                            let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.addByBundleID(id)
                                bundleID = ""
                            }
                        }
                        .disabled(model.busy || !bundleID.contains("."))
                    }
                } header: {
                    Text("Not in the list? Add by bundle id")
                }
            }

            if let notice = model.notice {
                Section { Text(notice).font(.callout).foregroundColor(.secondary) }
            }
        }
        .searchable(text: $filter, prompt: "Filter this list")
        .navigationTitle("Allowed apps")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private func row(_ app: ClaudeBridgeApp, isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { on in Task { await model.setAllowed(app, on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                    Text(app.bundleID).font(.caption).foregroundColor(.secondary)
                }
            }
            if isOn, let current = model.allowed.first(where: { $0.bundleID == app.bundleID }) {
                Toggle("Read-only (no typing)", isOn: Binding(
                    get: { current.readOnly },
                    set: { on in Task { await model.setReadOnly(app, on) } }))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(model.busy)
    }
}
