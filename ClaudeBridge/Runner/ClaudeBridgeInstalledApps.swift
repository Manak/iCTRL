import Foundation

/// Lists the apps installed on the phone, for the companion's allowlist
/// screen. iOS has no public API for this and keeps closing the private
/// ones, so several routes are tried in order and the result says which one
/// answered.
enum ClaudeBridgeInstalledApps {
    struct App {
        let bundleID: String
        let name: String
        /// False for apps that ship with iOS.
        let isUser: Bool
    }

    struct Listing {
        /// "workspace", "records", "plugins" or "history".
        let source: String
        let apps: [App]
        /// True when the route can only see some of the installed apps.
        let partial: Bool
    }

    static func list() -> Listing {
        // A complete route wins outright.
        for (source, partial, route) in routes where !partial {
            let apps = dedupe(route())
            if !apps.isEmpty { return Listing(source: source, apps: apps, partial: false) }
        }
        // Otherwise combine everything the partial routes can see. On
        // iOS 27 that is: every app that contains an extension (most do),
        // plus every app this runner has opened.
        let combined = dedupe(routes.filter { $0.1 }.flatMap { $0.2() })
        return Listing(source: combined.isEmpty ? "none" : "plugins+history", apps: combined, partial: true)
    }

    /// Count per route, for diagnostics. No names or ids.
    static func counts() -> String {
        routes.map { "\($0.0)=\(dedupe($0.2()).count)" }.joined(separator: " ")
    }

    private static let routes: [(String, Bool, () -> [App])] = [
        ("workspace", false, fromWorkspace),
        ("records", false, fromRecords),
        ("plugins", true, fromPlugins),
        ("history", true, fromHistory),
    ]

    private static func dedupe(_ apps: [App]) -> [App] {
        var seen = Set<String>()
        return apps
            .filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// LSApplicationWorkspace, through the runner's existing helper.
    private static func fromWorkspace() -> [App] {
        (ForegroundApp.installedAppsUserOnly(false) ?? []).compactMap { entry in
            guard let id = entry["bundle_id"] as? String else { return nil }
            let type = entry["type"] as? String
            return App(bundleID: id, name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                       isUser: type == nil || type == "" || type == "User")
        }
    }

    /// LSApplicationRecord enumeration (the newer CoreServices interface).
    private static func fromRecords() -> [App] {
        guard let cls = NSClassFromString("LSApplicationRecord") else { return [] }
        let selector = NSSelectorFromString("enumeratorWithOptions:")
        guard let method = class_getClassMethod(cls, selector) else { return [] }
        typealias Enumerate = @convention(c) (AnyClass, Selector, UInt64) -> AnyObject?
        let enumerate = unsafeBitCast(method_getImplementation(method), to: Enumerate.self)
        var out: [App] = []
        _ = ObjCException.catching {
            guard let enumerator = enumerate(cls, selector, 0) as? NSEnumerator else { return }
            for case let record as NSObject in enumerator {
                guard let id = string(record, "bundleIdentifier") else { continue }
                if let prohibited = record.value(forKey: "launchProhibited") as? Bool, prohibited { continue }
                let system = (string(record, "typeForInstallMachinery") ?? "") == "System"
                out.append(App(bundleID: id, name: string(record, "localizedName") ?? id, isUser: !system))
            }
        }
        return out
    }

    /// Apps that contain at least one extension, found through the plug-in list.
    private static func fromPlugins() -> [App] {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return [] }
        var out: [App] = []
        _ = ObjCException.catching {
            guard let workspace = cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
                  workspace.responds(to: NSSelectorFromString("installedPlugins")),
                  let plugins = workspace.perform(NSSelectorFromString("installedPlugins"))?.takeUnretainedValue() as? [NSObject] else { return }
            for plugin in plugins {
                guard plugin.responds(to: NSSelectorFromString("containingBundle")),
                      let app = plugin.perform(NSSelectorFromString("containingBundle"))?.takeUnretainedValue() as? NSObject,
                      let id = string(app, "applicationIdentifier") ?? string(app, "bundleIdentifier") else { continue }
                let type = string(app, "applicationType")
                out.append(App(bundleID: id, name: string(app, "localizedName") ?? id, isUser: type == nil || type == "User"))
            }
        }
        return out
    }

    /// Apps this runner has opened before. Always real, never complete.
    private static func fromHistory() -> [App] {
        AppMemory.shared.openedApps().compactMap { entry in
            guard let id = entry["bundle_id"] as? String else { return nil }
            return App(bundleID: id, name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id, isUser: true)
        }
    }

    private static func string(_ object: NSObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel),
              let value = object.perform(sel)?.takeUnretainedValue() as? String, !value.isEmpty else { return nil }
        return value
    }
}
