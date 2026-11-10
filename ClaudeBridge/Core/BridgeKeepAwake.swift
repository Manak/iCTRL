import Foundation

/// Keeps the phone from idling into auto-lock while a session runs.
///
/// A backgrounded runner cannot switch the idle timer off (that only works
/// for the app in front). What iOS does count is input, so this sends a
/// harmless input event at intervals.
///
/// The event must not touch the screen. An earlier version tapped the bottom
/// edge, and that tap landed on real controls (it opened chats). The event is
/// now supplied by the runner and is a bare modifier-key press, which no app
/// reacts to; see `ClaudeBridgeIdleEvent`.
///
/// Rules:
/// - skipped when a tool call already produced input recently;
/// - never when the phone is locked (a key event would wake the display).
final class BridgeKeepAwake {
    /// iOS's shortest auto-lock setting is 30 s. A pulse must land well
    /// inside that after the last input, counting the timer's own tick.
    static let defaultInterval: TimeInterval = 12
    static let tick: TimeInterval = 4

    private let isLocked: () -> Bool
    private let sendEvent: () -> Bool
    private let clock: BridgeClock
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastActivity: TimeInterval
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - isLocked: whether the phone is locked right now (must be cheap).
    ///   - sendEvent: sends one idle-resetting input event; false on failure.
    init(clock: BridgeClock, interval: TimeInterval = BridgeKeepAwake.defaultInterval,
         isLocked: @escaping () -> Bool, sendEvent: @escaping () -> Bool) {
        self.isLocked = isLocked
        self.sendEvent = sendEvent
        self.clock = clock
        self.interval = interval
        lastActivity = clock.uptime
    }

    /// Call whenever a tool call ran: its own input resets the idle timer.
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

    /// Sends one keep-awake event if there has been no input for a full
    /// interval and the phone is unlocked.
    @discardableResult
    func pulseIfDue() -> Outcome {
        lock.lock()
        let due = clock.uptime - lastActivity >= interval
        lock.unlock()
        guard due else { return .notDue }

        let outcome: Outcome
        if isLocked() {
            outcome = .skipped
        } else {
            outcome = sendEvent() ? .pulsed : .failed
        }
        // Whatever happened, wait a full interval before trying again.
        noteActivity()
        return outcome
    }
}
