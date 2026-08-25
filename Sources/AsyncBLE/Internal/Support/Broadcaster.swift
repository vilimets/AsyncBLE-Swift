// Fan-out for the observable streams: `Central.adapterStates` and `Connection.states`.
//
// Both are documented to hand every caller an independent stream that yields the current value
// immediately and then every change (PLAN.md §5). That is three requirements — fan-out, replay,
// and unsubscribe-on-termination — and none of them come free with AsyncStream.
//
// This is the one type in the library that uses a lock rather than the library queue, and it is
// deliberate: `states` and `adapterStates` are `nonisolated` properties, so subscribing happens
// on whatever thread the caller is on. Hopping to the queue to register would mean a subscriber
// could miss the value it was promised on subscription. A lock lets registration be synchronous.

import Foundation

/// Broadcasts a value to any number of independent `AsyncStream`s, replaying the latest to each
/// new subscriber.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element
    private var isFinished = false

    /// Creates a broadcaster holding an initial value, which every subscriber sees first.
    init(_ initial: Element) {
        latest = initial
    }

    /// The most recently broadcast value.
    var current: Element {
        lock.withLock { latest }
    }

    /// Whether the broadcast has ended. Subscribing afterwards yields the final value and ends.
    var hasFinished: Bool {
        lock.withLock { isFinished }
    }

    /// A new independent stream, starting with the current value.
    ///
    /// Iteration ending — cancelled, broken out of, or the stream dropped — unsubscribes.
    func stream(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            lock.lock()
            let value = latest
            let finished = isFinished
            if !finished {
                continuations[id] = continuation
            }
            lock.unlock()

            // Outside the lock: a `finish()` here runs `onTermination`, which takes it again.
            continuation.yield(value)
            if finished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    /// Broadcasts a value, and remembers it for later subscribers.
    ///
    /// Does nothing once the broadcast has finished, so a late transition cannot reopen a
    /// connection's state stream after it ended.
    func send(_ value: Element) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()

        for continuation in targets {
            continuation.yield(value)
        }
    }

    /// Ends every stream, now and in future. Idempotent.
    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        for continuation in targets {
            continuation.finish()
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
