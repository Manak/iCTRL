import Foundation

/// Ends the session when Claude has been quiet for too long.
///
/// "Activity" is an authentic MCP request. Keep-awake pulses and the
/// companion's own status checks do not count. When the limit passes,
/// `onExpire` runs once; the runner uses it to stop the bridge, the raw API
/// and itself, after which nothing is reachable until the owner starts a new
/// session.
final class BridgeIdleShutdown {
    static let defaultLimit: TimeInterval = 30 * 60

    private let clock: BridgeClock
    /// 0 or less means never.
    let limit: TimeInterval
    private let lock = NSLock()
    private var lastActivity: TimeInterval
    private let startedUptime: TimeInterval
    private var fired = false
    private var timer: DispatchSourceTimer?
    var onExpire: (() -> Void)?

    init(limit: TimeInterval = BridgeIdleShutdown.defaultLimit, clock: BridgeClock) {
        self.limit = limit
        self.clock = clock
        lastActivity = clock.uptime
        startedUptime = clock.uptime
    }

    func noteActivity() {
        lock.lock(); lastActivity = clock.uptime; lock.unlock()
    }

    /// Seconds left before the session ends, or nil when there is no limit.
    var remaining: TimeInterval? {
        guard limit > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return max(0, limit - (clock.uptime - lastActivity))
    }

    /// Seconds since the last request from Claude.
    var idleFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return clock.uptime - lastActivity
    }

    /// Fires `onExpire` if the limit has passed. Returns true when it fired.
    @discardableResult
    func check() -> Bool {
        guard limit > 0 else { return false }
        lock.lock()
        let due = !fired && clock.uptime - lastActivity >= limit
        if due { fired = true }
        lock.unlock()
        if due { onExpire?() }
        return due
    }

    func start() {
        guard limit > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // A minute's slack on a 30-minute limit is fine, and cheap.
        t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}
