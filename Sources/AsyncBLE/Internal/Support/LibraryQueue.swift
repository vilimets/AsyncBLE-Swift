// The one queue everything in this library runs on, and the serial executor that makes the
// actors run on it too.
//
// CoreBluetooth wants a DispatchQueue and delivers every delegate callback on it. Actors want
// an executor. Giving the actors *this* queue as their executor collapses the two into one
// execution context, which buys three things that are otherwise all bought separately:
//
//   1. A delegate callback and an actor method cannot run concurrently, so the CB objects —
//      none of which are thread-safe — have exactly one thread touching them.
//   2. Callbacks need no hop to reach the engine, so nothing can be reordered on the way in.
//      An unstructured `Task { await ... }` per callback would lose delivery order, which is
//      precisely what the FIFO queue exists to preserve (PLAN.md §7 Q4).
//   3. `withRaw` can promise "the closure runs on the library's queue" and have it be true by
//      construction rather than by convention (PLAN.md §7 Q6).

import Foundation

/// The library's execution context: one serial queue, plus its executor.
///
/// One per ``Central``, shared with every ``Connection`` that central creates.
final class LibraryQueue: @unchecked Sendable {
    /// The queue handed to `CBCentralManager`, and the queue the executor runs jobs on.
    let dispatchQueue: DispatchQueue

    private let executor: LibraryExecutor

    /// The executor to return from an actor's `unownedExecutor`.
    var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// Creates a queue and its executor.
    ///
    /// - Parameter label: The dispatch queue label, which is what shows up in a crash report
    ///   or Instruments trace — worth keeping recognizable.
    init(label: String = "com.asyncble.library") {
        dispatchQueue = DispatchQueue(label: label)
        executor = LibraryExecutor(queue: dispatchQueue)
    }

    /// Traps if the caller is not on the library queue.
    ///
    /// For the confinement contract that every `@unchecked Sendable` in this library leans on:
    /// cheap in release builds, and it turns "should be on the queue" into a testable claim.
    func assertIsolated(_ message: @autoclosure () -> String = "must run on the library queue") {
        dispatchPrecondition(condition: .onQueue(dispatchQueue))
    }
}

/// A `SerialExecutor` that runs actor jobs on a `DispatchQueue`.
private final class LibraryExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
