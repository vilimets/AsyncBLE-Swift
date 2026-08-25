// Injectable delay source, so timeout and reconnect logic can be tested without real waiting.
//
// The state machine emits `startConnectTimeout`, `startGiveUpDeadline` and `startReArmTimer`
// as values; something has to turn them into a callback that arrives later. A protocol here
// means the reconnect tests advance a fake clock by two minutes in a microsecond, instead of
// sleeping and hoping.

import Foundation

/// Something that can run work later, and be told not to.
protocol Scheduler: AnyObject, Sendable {
    /// Schedules `work` to run on the library queue after `duration`.
    ///
    /// - Returns: A handle that cancels the work if it has not run yet.
    func schedule(after duration: Duration, _ work: @escaping @Sendable () -> Void) -> ScheduledWork
}

/// A scheduled piece of work that has not necessarily run yet.
protocol ScheduledWork: AnyObject, Sendable {
    /// Prevents the work from running, if it has not already. Idempotent.
    func cancel()
}

/// The real scheduler: `DispatchQueue.asyncAfter` on the library queue.
final class QueueScheduler: Scheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(after duration: Duration, _ work: @escaping @Sendable () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        // Wall time, not uptime. PLAN.md §7 Q20 says a give-up deadline means what it says, and
        // a deadline measured on the uptime clock silently stops counting while the device is
        // asleep — which is most of a two-minute wait on a locked phone.
        queue.asyncAfter(wallDeadline: .now() + duration.seconds, execute: item)
        return DispatchScheduledWork(item)
    }
}

/// `ScheduledWork` over a `DispatchWorkItem`.
private final class DispatchScheduledWork: ScheduledWork {
    private let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

extension Duration {
    /// The duration in seconds, for the APIs that predate `Duration`.
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
