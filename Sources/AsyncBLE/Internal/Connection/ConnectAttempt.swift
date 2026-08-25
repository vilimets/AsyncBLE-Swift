// One caller's wait for a link, and the two ways it can end early.
//
// PLAN.md §7 Q10: cancelling one caller detaches that caller only; the attempt survives while
// anyone is still waiting, and is withdrawn when the last one leaves. That means a waiter can be
// resumed from three directions — the link coming up, the connection ending, the caller's own
// task being cancelled or its deadline expiring — and exactly one of them may win.
//
// Queue-confined: every method runs on the library queue, either from the `Central` actor or
// from a cancellation hop onto it.

import Foundation

/// A continuation that can be resumed from several places and will only resume once.
final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    /// Resumes, unless something already did.
    func resume(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// One caller waiting for a connection to come up.
final class ConnectAttemptHandle: @unchecked Sendable {
    private var once: ResumeOnce?
    private var core: ConnectionCore?
    private var waiterID: UUID?
    private var deadline: ScheduledWork?
    private var cancelledBeforeStart = false

    /// Registers this caller with the connection, and arms its own deadline if it has one.
    ///
    /// - Parameters:
    ///   - core: The connection being waited on.
    ///   - continuation: The caller, to be resumed exactly once.
    ///   - timeout: A deadline belonging to *this caller* rather than to the attempt. Used only
    ///     when joining an attempt or a reconnect wait that is already running: a fresh attempt
    ///     gets its deadline from the state machine instead, so the two never both fire.
    ///   - scheduler: Where the deadline is armed.
    func begin(
        core: ConnectionCore,
        continuation: CheckedContinuation<Void, Error>,
        timeout: Duration?,
        scheduler: Scheduler
    ) {
        let once = ResumeOnce(continuation)
        self.once = once
        self.core = core

        guard !cancelledBeforeStart else {
            // The caller's task was cancelled before this even got to run.
            once.resume(.failure(CancellationError()))
            return
        }

        waiterID = core.addConnectWaiter { [weak self] result in
            self?.waiterID = nil
            self?.deadline?.cancel()
            once.resume(result)
        }

        guard let timeout else { return }
        deadline = scheduler.schedule(after: timeout) { [weak self] in
            self?.detach()
            once.resume(.failure(BluetoothError.connectTimeout))
        }
    }

    /// The caller went away. Detach it, and let the connection decide whether the attempt has
    /// anyone left to serve.
    func cancel() {
        cancelledBeforeStart = true
        detach()
        once?.resume(.failure(CancellationError()))
    }

    private func detach() {
        deadline?.cancel()
        deadline = nil
        guard let waiterID, let core else { return }
        self.waiterID = nil
        core.removeConnectWaiter(waiterID)
    }
}
