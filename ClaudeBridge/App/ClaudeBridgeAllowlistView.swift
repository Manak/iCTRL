import SwiftUI

/// One app Claude may operate, as the companion shows it.
struct ClaudeBridgeApp: Identifiable, Equatable {
    var bundleID: String
    var name: String
    var readOnly: Bool
    var id: String { bundleID }

    init(bundleID: String, name: String, readOnly: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.readOnly = readOnly
    }

    init?(_ entry: [String: Any]) {
        guard let bundle = entry["bundle_id"] as? String, !bundle.isEmpty else { return nil }
        bundleID = bundle
        name = entry["name"] as? String ?? bundle
        readOnly = entry["read_only"] as? Bool ?? false
    }

    var json: [String: Any] { ["bundle_id": bundleID, "name": name, "read_only": readOnly] }
}

@MainActor
final class ClaudeBridgeAllowlistModel: ObservableObject {
    @Published private(set) var apps: [ClaudeBridgeApp] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var results: [ClaudeBridgeApp] = []
    @Published var notice: String?

    private func client() -> RunnerClient { RunnerClient(port: 8200) }

    func load() async {
        do {
            let status = try await client().call("claude_bridge", ["action": "status"])
            apps = Self.parse(status)
            loaded = true
        } catch {
            notice = Self.describe(error)
        }
    }

    /// Sends the whole list. The runner filters it and answers with what it
    /// kept, which is what this screen then shows.
    private func save(_ next: [ClaudeBridgeApp]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await client().call("claude_bridge", ["action": "set_allowlist", "apps": next.map(\.json)])
            apps = Self.parse(reply)
            let rejected = reply["rejected"] as? [String] ?? []
            notice = rejected.isEmpty ? nil
                : "Not added: \(rejected.joined(separator: ", ")). Settings, the App Store, Wallet, Shortcuts and iCTRL itself can never be allowed."
        } catch {
            notice = Self.describe(error)
        }
    }

    func add(_ app: ClaudeBridgeApp) async {
        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else {
            notice = "\(app.name) is already on the list."
            return
        }
        await save(apps + [app])
    }

    func remove(at offsets: IndexSet) async {
        var next = apps
        next.remove(atOffsets: offsets)
        await save(next)
    }

    func setReadOnly(_ app: ClaudeBridgeApp, _ on: Bool) async {
        await save(apps.map { $0.bundleID == app.bundleID ? ClaudeBridgeApp(bundleID: $0.bundleID, name: $0.name, readOnly: on) : $0 })
    }

    /// Looks an app up by name through the runner (its built-in catalogue
    /// first, then the App Store search).
    func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await client().call("resolve_app", ["text": term, "distance": 8], timeout: 20)
            let found = (reply["apps"] as? [[String: Any]] ?? []).compactMap(ClaudeBridgeApp.init)
            results = found
            notice = found.isEmpty ? "No app found for “\(term)”. You can add it by bundle id below." : nil
        } catch {
            notice = Self.describe(error)
        }
    }

    func clearResults() { results = [] }

    private static func parse(_ reply: [String: Any]) -> [ClaudeBridgeApp] {
        (reply["allowed_apps"] as? [[String: Any]] ?? []).compactMap(ClaudeBridgeApp.init)
    }

    private static func describe(_ error: Error) -> String {
        if case RunnerClient.Failure.notRunning = error { return "The runner is not running. Start it first." }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Edits the list of apps Claude may operate. The list lives in the runner
/// and can only be changed from this phone; no MCP tool can touch it.
struct ClaudeBridgeAllowlistView: View {
    @StateObject private var model = ClaudeBridgeAllowlistModel()
    @State private var query = ""
    @State private var bundleID = ""

    var body: some View {
        List {
            Section {
                if !model.loaded {
                    ProgressView()
                } else if model.apps.isEmpty {
                    Text("No apps. Claude can only see the home screen and search.")
                        .foregroundColor(.secondary)
                }
                ForEach(model.apps) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundColor(.secondary)
                        Toggle("Read-only (no typing)", isOn: Binding(
                            get: { app.readOnly },
                            set: { on in Task { await model.setReadOnly(app, on) } }))
                            .font(.footnote)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in Task { await model.remove(at: offsets) } }
            } header: {
                Text("Allowed apps")
            } footer: {
                Text("Claude can read and act inside these apps, plus the home screen and search. Anywhere else, every tool refuses. Swipe to remove.")
            }
            .disabled(model.busy)

            Section {
                HStack {
                    TextField("App name, e.g. Telegram", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await model.search(query) } }
                    Button("Search") { Task { await model.search(query) } }
                        .disabled(model.busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.results) { app in
                    Button {
                        Task {
                            await model.add(app)
                            model.clearResults()
                            query = ""
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(app.name, systemImage: "plus.circle")
                            Text(app.bundleID).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Add by name")
            } footer: {
                Text("The search checks a built-in list first and otherwise asks the App Store, which sends the name you typed to Apple.")
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
                            await model.add(ClaudeBridgeApp(bundleID: id, name: id))
                            bundleID = ""
                        }
                    }
                    .disabled(model.busy || !bundleID.contains("."))
                }
            } header: {
                Text("Add by bundle id")
            }

            if let notice = model.notice {
                Section { Text(notice).font(.callout).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("Allowed apps")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}
