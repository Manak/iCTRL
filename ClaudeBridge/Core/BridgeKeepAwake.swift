import Foundation

/// Keeps the phone from idling into auto-lock while a session runs.
///
/// A backgrounded runner cannot switch the idle timer off (that only works
/// for the app in front). What does count as user activity is a touch, so
/// this sends a tiny, content-free one at intervals: a tap on the last point
/// of the bottom edge, under the home indicator, where no app puts a control.
///
/// Rules:
/// - only while the home screen, system search or an allowlisted app is in
///   front. During a lockout nothing is touched, so the phone may lock then;
/// - skipped when a tool call already touched the screen recently;
/// - never when the phone is already locked.
final class BridgeKeepAwake {
    /// iOS's shortest auto-lock setting is 30 s. A pulse must land well
    /// inside that after the last touch, counting the timer's own tick, its
    /// leeway and the foreground check that precedes the tap.
    static let defaultInterval: TimeInterval = 12
    static let tick: TimeInterval = 4

    private let raw: BridgeRawAPI
    private let guardian: BridgeGuard
    private let clock: BridgeClock
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastActivity: TimeInterval
    private var timer: DispatchSourceTimer?

    init(raw: BridgeRawAPI, guardian: BridgeGuard, clock: BridgeClock, interval: TimeInterval = BridgeKeepAwake.defaultInterval) {
        self.raw = raw
        self.guardian = guardian
        self.clock = clock
        self.interval = interval
        lastActivity = clock.uptime
    }

    /// Call whenever a tool call ran: its own touches reset the idle timer.
    func noteActivity() {
        lock.lock(); lastActivity = clock.uptime; lock.unlock()
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in _ = self?.pulseIfDue() }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    enum Outcome: Equatable { case notDue, skipped, pulsed, failed }

    /// Sends one keep-awake touch if the screen has been untouched for a
    /// full interval and a permitted screen is in front.
    @discardableResult
    func pulseIfDue() -> Outcome {
        lock.lock()
        let due = clock.uptime - lastActivity >= interval
        lock.unlock()
        guard due else { return .notDue }

        let outcome: Outcome = guardian.exclusive {
            let probe = self.guardian.probe(record: false)
            switch probe.foreground {
            case .home, .allowed:
                break
            case .blocked, .phoneLocked, .unverified:
                return .skipped
            }
            guard probe.pointWidth > 0, probe.pointHeight > 0 else { return .skipped }
            let result = self.raw.call("tap", [
                "x": probe.pointWidth / 2,
                "y": probe.pointHeight - 1,
                "settle": false,
                "fast": true,
            ])
            if case .failure = result { return .failed }
            return .pulsed
        }
        // Whatever happened, wait a full interval before trying again.
        noteActivity()
        return outcome
    }
}
