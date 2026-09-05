// Fan-out for `Central.restoredConnections`, replaying every element rather than the latest.
//
// `Broadcaster` cannot serve here, and the difference is not a detail. It replays one value —
// the current state, which is exactly right for `adapterStates` and `Connection.states`, where
// history is noise. Restoration has no current value: a relaunch may hand back several links,
// and an app that starts iterating after they have all arrived has to see all of them. There is
// no state to be caught up on, only a list.
//
// The other difference: no `finish()`. A connection's state stream ends because the connection
// does; restoration can happen again, in the same process, whenever iOS relaunches this app
// after another termination.
//
// Same locking rationale as `Broadcaster`: subscribing happens on whatever thread the caller is
// on, so registration is synchronous under a lock rather than hopped onto the library queue,
// which would let a subscriber miss the replay it was promised.

import Foundation

/// Broadcasts to any number of independent `AsyncStream`s, replaying everything sent so far to
/// each new subscriber.
final class ReplayBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var history: [Element] = []

    /// Everything broadcast so far, in order.
    var replay: [Element] {
        lock.withLock { history }
    }

    /// A new independent stream, starting with everything sent so far.
    ///
    /// Never finishes: more may always arrive. Iteration ending — cancelled, broken out of, or
    /// the stream dropped — unsubscribes.
    func stream() -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            let backlog = history
            continuations[id] = continuation
            lock.unlock()

            // Outside the lock: `yield` can run the termination handler, which takes it again.
            for element in backlog {
                continuation.yield(element)
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    /// Broadcasts an element, and remembers it for later subscribers.
    func send(_ element: Element) {
        lock.lock()
        history.append(element)
        let targets = Array(continuations.values)
        lock.unlock()

        for continuation in targets {
            continuation.yield(element)
        }
    }

    /// How many streams are currently subscribed. For tests: a subscriber that unsubscribed and
    /// was not removed is a leak that nothing else would notice.
    var subscriberCount: Int {
        lock.withLock { continuations.count }
    }

    private func remove(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }
}
