// A clock a test owns outright.
//
// The reconnect story is made of durations — a ten-second connect timeout, a two-minute give-up
// deadline, a thirty-second re-arm cadence. Testing that against a real clock would mean a
// suite that takes minutes and fails on a loaded CI machine. Here time moves only when a test
// says so, and moves instantly.

import Foundation

@testable import AsyncBLE

/// A `Scheduler` whose clock only advances when a test advances it.
final class TestScheduler: Scheduler, @unchecked Sendable {
    private final class Item: ScheduledWork, @unchecked Sendable {
        let due: Duration
        let sequence: Int
        let work: @Sendable () -> Void
        private(set) var isCancelled = false

        init(due: Duration, sequence: Int, work: @escaping @Sendable () -> Void) {
            self.due = due
            self.sequence = sequence
            self.work = work
        }

        func cancel() {
            isCancelled = true
        }
    }

    /// How far the clock has been advanced.
    private(set) var now: Duration = .zero

    private var items: [Item] = []
    private var sequence = 0

    func schedule(after duration: Duration, _ work: @escaping @Sendable () -> Void) -> ScheduledWork {
        sequence += 1
        let item = Item(due: now + duration, sequence: sequence, work: work)
        items.append(item)
        return item
    }

    /// Moves the clock forward, running everything that comes due, earliest first.
    ///
    /// Work scheduled *during* the advance is honoured too, so a re-arm cadence that schedules
    /// its own next cycle behaves under a single `advance(by: .seconds(90))` exactly as it
    /// would over ninety real seconds.
    func advance(by duration: Duration) {
        let target = now + duration
        while let next = nextDue(upTo: target) {
            items.removeAll { $0 === next }
            now = next.due
            next.work()
        }
        now = target
        items.removeAll { $0.isCancelled }
    }

    /// How many pieces of work are scheduled and not yet cancelled.
    var pendingCount: Int {
        items.filter { !$0.isCancelled }.count
    }

    /// The delays that were asked for and are still live, earliest first — for asserting that
    /// the right timer was armed without waiting for it.
    var pendingDelays: [Duration] {
        items.filter { !$0.isCancelled }.map { $0.due - now }.sorted()
    }

    private func nextDue(upTo target: Duration) -> Item? {
        items
            .filter { !$0.isCancelled && $0.due <= target }
            .min { ($0.due, $0.sequence) < ($1.due, $1.sequence) }
    }
}
