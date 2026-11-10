import Foundation

// Claude Bridge core. Foundation only: no XCTest, UIKit or iCTRL types, so the
// same files compile into the runner and into the Mac unit tests.

/// JSON object as produced by JSONSerialization.
typealias BridgeJSON = [String: Any]

/// Result of one call to iCTRL's existing JSON-RPC API.
enum BridgeRawResult {
    case success(BridgeJSON)
    case failure(String)
}

/// iCTRL's existing raw API (tap, page_source, device_info, …), called
/// in-process. The bridge is the only caller; it is never exposed directly.
protocol BridgeRawAPI {
    func call(_ method: String, _ params: BridgeJSON) -> BridgeRawResult
}

/// One app Claude may operate.
struct BridgeAllowedApp: Equatable {
    let bundleID: String
    let name: String
    /// When true, typing is refused in this app.
    var readOnly: Bool = false
    /// Custom URL schemes that open this app (lowercase, no "://").
    var urlSchemes: [String] = []
    /// https hosts whose links open this app (lowercase).
    var urlHosts: [String] = []

}

/// Link formats of some common apps, so `open_url` can tell which app a URL
/// belongs to. This is reference data, not policy: an app is only usable if
/// the owner put it on the allowlist, and an app that is not in this table
/// simply has no deep links (`launch_app` still works for it).
enum BridgeKnownLinks {
    static let table: [String: (schemes: [String], hosts: [String])] = [
        "net.whatsapp.WhatsApp": (["whatsapp"], ["wa.me", "api.whatsapp.com", "chat.whatsapp.com"]),
        "ph.telegra.Telegraph": (["tg"], ["t.me"]),
        "org.whispersystems.signal": (["sgnl"], ["signal.me"]),
    ]

    /// An allowlist entry for `bundleID`, with its known links filled in.
    static func app(bundleID: String, name: String, readOnly: Bool = false) -> BridgeAllowedApp {
        let links = table[bundleID]
        return BridgeAllowedApp(bundleID: bundleID, name: name, readOnly: readOnly,
                                urlSchemes: links?.schemes ?? [], urlHosts: links?.hosts ?? [])
    }
}

/// Rules for what may be put on the allowlist at all.
enum BridgeAllowlistPolicy {
    static let maxApps = 50

    /// Never allowed, whatever the stored list says: the apps that control
    /// the phone, its money and its installs. SpringBoard is listed because
    /// "home" is granted through the home-screen check, not through the list.
    static let neverAllowed: Set<String> = [
        "com.apple.springboard",
        "com.apple.Preferences",       // Settings
        "com.apple.AppStore",
        "com.apple.Passbook",          // Wallet
        "com.apple.PassbookUIService",
        "com.apple.shortcuts",
        "com.apple.TestFlight",
    ]

    /// Suffixes of this project's own apps: the companion (which can copy
    /// the connector address) and the runner.
    static let neverAllowedSuffixes = [".ictrl", ".ictrl.uitests.xctrunner", ".ictrl.bridgewidget"]

    static func isForbidden(_ bundleID: String) -> Bool {
        neverAllowed.contains(bundleID) || neverAllowedSuffixes.contains { bundleID.hasSuffix($0) }
    }

    /// A plausible bundle identifier: reverse-DNS, two or more parts.
    static func isValidBundleID(_ id: String) -> Bool {
        guard id.count <= 155, id.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return id.unicodeScalars.allSatisfy(allowed.contains) && !id.hasPrefix(".") && !id.hasSuffix(".")
    }

    /// Cleans a list before it is stored or used: drops forbidden and
    /// malformed entries and duplicates, and caps the length.
    static func sanitize(_ apps: [BridgeAllowedApp]) -> [BridgeAllowedApp] {
        var seen = Set<String>()
        var out: [BridgeAllowedApp] = []
        for app in apps where isValidBundleID(app.bundleID) && !isForbidden(app.bundleID) && seen.insert(app.bundleID).inserted {
            out.append(app)
            if out.count == maxApps { break }
        }
        return out
    }
}

/// The allowlist is owned by the phone. Nothing in the MCP layer can write it.
protocol BridgeAllowlistProvider {
    var allowedApps: [BridgeAllowedApp] { get }
}

struct BridgeStaticAllowlist: BridgeAllowlistProvider {
    var allowedApps: [BridgeAllowedApp]
}

extension BridgeAllowlistProvider {
    func app(bundleID: String) -> BridgeAllowedApp? {
        allowedApps.first { $0.bundleID == bundleID }
    }

    /// The allowlisted app a URL would open, or nil if it is not clearly one.
    func app(forURL string: String) -> BridgeAllowedApp? {
        guard let comps = URLComponents(string: string),
              let scheme = comps.scheme?.lowercased() else { return nil }
        if scheme == "https" {
            guard let host = comps.host?.lowercased() else { return nil }
            return allowedApps.first { $0.urlHosts.contains(host) }
        }
        return allowedApps.first { $0.urlSchemes.contains(scheme) }
    }
}

/// Injectable time source so rate limits and logs are testable.
protocol BridgeClock {
    /// Monotonic seconds.
    var uptime: TimeInterval { get }
    var now: Date { get }
}

struct BridgeSystemClock: BridgeClock {
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var now: Date { Date() }
}

/// Token bucket. Thread-safe.
final class BridgeRateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private let clock: BridgeClock
    private var tokens: Double
    private var last: TimeInterval
    private let lock = NSLock()

    init(burst: Int, perSecond: Double, clock: BridgeClock) {
        capacity = Double(burst)
        refillPerSecond = perSecond
        self.clock = clock
        tokens = Double(burst)
        last = clock.uptime
    }

    /// Takes one token. False when the caller is going too fast.
    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = clock.uptime
        tokens = min(capacity, tokens + (t - last) * refillPerSecond)
        last = t
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Record of one MCP tool call. Holds no arguments and no screen content.
struct BridgeLogEntry: Equatable {
    enum Status: String {
        case ok
        case error
        case refused
        case lockedOut = "locked_out"
        case phoneLocked = "phone_locked"
        case rateLimited = "rate_limited"
    }
    let time: Date
    let tool: String
    let status: Status
}

/// Fixed-size action log. Thread-safe.
final class BridgeActionLog {
    private var entries: [BridgeLogEntry] = []
    private let capacity: Int
    private let lock = NSLock()
    /// Called after every append (for persistence or a live indicator).
    var onAppend: ((BridgeLogEntry) -> Void)?

    init(capacity: Int = 500) { self.capacity = capacity }

    func append(_ entry: BridgeLogEntry) {
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        onAppend?(entry)
    }

    var all: [BridgeLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
