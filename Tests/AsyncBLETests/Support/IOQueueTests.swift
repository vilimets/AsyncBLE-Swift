// The FIFO, tested on its own terms: order in, order out, and what happens to everyone waiting
// when the link goes away underneath them.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("The connection I/O queue")
struct IOQueueTests {
    /// Records the order callers were let through, or the errors they were turned away with.
    private final class Log: @unchecked Sendable {
        private(set) var started: [String] = []
        private(set) var failed: [String] = []

        func resumer(_ label: String) -> IOQueue.Resume {
            { [self] result in
                switch result {
                case .success: started.append(label)
                case .failure: failed.append(label)
                }
            }
        }
    }

    @Test("the first caller runs immediately")
    func firstCallerRunsImmediately() {
        let queue = IOQueue()
        let log = Log()

        let ticket = queue.enqueue()
        queue.attach(log.resumer("a"), to: ticket)

        #expect(log.started == ["a"])
        #expect(queue.depth == 1)
    }

    @Test("callers run in the order they took their place in line")
    func callersRunInOrder() {
        // The property the whole type exists for. Enqueueing is synchronous, so arrival order
        // is fixed before anyone suspends — actor reentrancy has nothing left to reorder.
        let queue = IOQueue()
        let log = Log()
        let tickets = ["a", "b", "c"].map { label -> (String, IOQueue.Ticket) in
            let ticket = queue.enqueue()
            queue.attach(log.resumer(label), to: ticket)
            return (label, ticket)
        }

        #expect(log.started == ["a"])

        queue.complete(tickets[0].1)
        #expect(log.started == ["a", "b"])

        queue.complete(tickets[1].1)
        #expect(log.started == ["a", "b", "c"])

        queue.complete(tickets[2].1)
        #expect(queue.isEmpty)
    }

    @Test("a caller that gives up while queued lets the line move on without it")
    func cancelledCallerIsSkipped() {
        let queue = IOQueue()
        let log = Log()
        let first = queue.enqueue()
        let second = queue.enqueue()
        let third = queue.enqueue()
        queue.attach(log.resumer("first"), to: first)
        queue.attach(log.resumer("second"), to: second)
        queue.attach(log.resumer("third"), to: third)

        queue.cancel(second)
        queue.complete(second)
        queue.complete(first)

        #expect(log.failed == ["second"])
        #expect(log.started == ["first", "third"])
    }

    @Test("attaching to an already-cancelled ticket fails immediately")
    func cancelBeforeAttach() {
        // The race where a caller's task is cancelled between taking its place and suspending.
        let queue = IOQueue()
        let log = Log()
        let running = queue.enqueue()
        let ticket = queue.enqueue()

        queue.cancel(ticket)
        queue.attach(log.resumer("late"), to: ticket)

        #expect(log.failed == ["late"])
        withExtendedLifetime(running) {}
    }

    @Test("a drop fails everyone waiting, in line order")
    func dropFailsEveryoneInOrder() {
        // Queued writes at the moment of a drop fail, in order, before any new I/O
        // is accepted — which is why the state machine emits endPendingOperations before it
        // arms a reconnect.
        let queue = IOQueue()
        let log = Log()
        for label in ["a", "b", "c"] {
            queue.attach(log.resumer(label), to: queue.enqueue())
        }

        let running = queue.failAll(with: BluetoothError.disconnected(reason: .linkLost))

        #expect(log.started == ["a"])
        #expect(log.failed == ["b", "c"])
        #expect(running != nil)
        #expect(queue.isEmpty)
    }

    @Test("a drop reports the operation that was already running")
    func dropReportsTheRunningOperation() {
        // Its caller is past the queue and suspended on a CoreBluetooth callback that is never
        // coming, so the connection has to fail it where it now is.
        let queue = IOQueue()
        let log = Log()
        let running = queue.enqueue()
        queue.attach(log.resumer("running"), to: running)

        let reported = queue.failAll(with: BluetoothError.disconnected(reason: .linkLost))

        #expect(reported === running)
        #expect(log.failed.isEmpty)
    }

    @Test("a drop with an empty queue reports nothing")
    func dropWithNothingRunning() {
        let queue = IOQueue()
        #expect(queue.failAll(with: BluetoothError.disconnected(reason: .linkLost)) == nil)
    }

    @Test("completing a ticket twice is harmless")
    func completeIsIdempotent() {
        let queue = IOQueue()
        let log = Log()
        let first = queue.enqueue()
        let second = queue.enqueue()
        queue.attach(log.resumer("first"), to: first)
        queue.attach(log.resumer("second"), to: second)

        queue.complete(first)
        queue.complete(first)

        #expect(log.started == ["first", "second"])
        #expect(queue.depth == 1)
    }
}
