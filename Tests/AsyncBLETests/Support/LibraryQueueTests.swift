// The isolation decision, asserted rather than assumed: an actor whose executor is the library
// queue really does run its body on that queue — the same queue CoreBluetooth delivers its
// callbacks on. Everything `@unchecked Sendable` in this library rests on that being true.

import Foundation
import Testing

@testable import AsyncBLE

/// The label of the dispatch queue the caller is running on.
private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// A stand-in for `Central` and `Connection`, which adopt the same executor in Phase 2c.
private actor Probe {
    private let library: LibraryQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor { library.unownedExecutor }

    init(library: LibraryQueue) {
        self.library = library
    }

    func queueLabel() -> String {
        currentQueueLabel()
    }

    /// Traps unless the actor body is running on the library queue.
    func assertIsolated() {
        library.assertIsolated()
    }

    /// Counts a step either side of a suspension point, so a caller can prove the actor
    /// remained on its own executor across an await.
    func labelsAcrossSuspension() async -> [String] {
        let before = currentQueueLabel()
        await Task.yield()
        return [before, currentQueueLabel()]
    }
}

@Suite("The library queue")
struct LibraryQueueTests {
    @Test("an actor on the library executor runs on the library queue")
    func actorRunsOnTheQueue() async {
        let library = LibraryQueue(label: "test.library.queue")
        let probe = Probe(library: library)

        #expect(await probe.queueLabel() == "test.library.queue")
        await probe.assertIsolated()
    }

    @Test("and stays there across a suspension point")
    func actorStaysOnTheQueue() async {
        // The property that makes a delegate callback and an actor method mutually exclusive:
        // an actor that hopped back onto the global pool after an await would be free to run
        // alongside CoreBluetooth touching the same non-thread-safe objects.
        let library = LibraryQueue(label: "test.library.resume")
        let probe = Probe(library: library)

        #expect(await probe.labelsAcrossSuspension() == ["test.library.resume", "test.library.resume"])
    }

    @Test("each central gets its own queue")
    func queuesAreIndependent() async {
        let first = Probe(library: LibraryQueue(label: "test.library.first"))
        let second = Probe(library: LibraryQueue(label: "test.library.second"))

        #expect(await first.queueLabel() == "test.library.first")
        #expect(await second.queueLabel() == "test.library.second")
    }

    @Test("concurrent submitters cannot lose an update")
    func queueIsSerial() async {
        // Fifty tasks writing to an unsynchronized array. The queue is the only thing making
        // that safe, so a dropped or torn write means the executor is not serial after all.
        let library = LibraryQueue(label: "test.library.serial")
        let recorded = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        library.dispatchQueue.async {
                            recorded.append(index)
                            continuation.resume()
                        }
                    }
                }
            }
        }

        #expect(recorded.values.count == 50)
        #expect(Set(recorded.values).count == 50)
    }
}

/// Somewhere for the serial-queue test to write from, without a lock — the queue is the lock.
private final class Recorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
