// The awaiting half of a connection: the actor-isolated helpers that turn the engine's
// synchronous callbacks into suspension points.
//
// Everything here is actor-isolated, which is the point. `withCheckedContinuation` runs its body
// in the caller's context, so registering a callback happens on the library queue with no hop,
// and the resumption comes back to the same queue — the two properties the FIFO's ordering
// guarantee is built on.

@preconcurrency import CoreBluetooth
import Foundation

extension Connection {
    /// Suspends until the engine hands back a result.
    ///
    /// - Parameter register: Parks a callback with the engine. Runs synchronously, on the
    ///   library queue, before this function suspends.
    func suspend<T: Sendable>(
        _ register: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            register { continuation.resume(with: $0) }
        }
    }

    /// Waits for this operation's turn in the FIFO.
    ///
    /// Cancelling the calling task while queued gives the place up, so the callers behind it
    /// move on. A cancellation that arrives once the operation is already running is ignored:
    /// CoreBluetooth has no way to withdraw a read or a write that is on the wire.
    func waitForTurn(_ ticket: IOQueue.Ticket) async throws {
        try await withTaskCancellationHandler {
            try await suspend { resume in
                core.attachTurn({ resume($0) }, to: ticket)
            }
        } onCancel: { [core] in
            core.library.dispatchQueue.async { core.cancel(ticket) }
        }
    }

    /// Resolves a characteristic UUID against this link, walking discovery if it has not been
    /// walked yet. Concurrent callers share the one walk.
    func resolveCharacteristic(_ uuid: CBUUID) async throws -> CharacteristicSeam {
        try await suspend { deliver in
            core.resolve(uuid, deliver)
        }
    }

    /// Re-establishes every subscription that was live when the link dropped.
    ///
    /// Runs holding a place taken the moment the link came back, so a read issued in the same
    /// breath cannot overtake it. A characteristic that did not come back fails its own streams
    /// and leaves the others alone — the connection stays up.
    func restoreSubscriptions(holding ticket: IOQueue.Ticket) async {
        defer { core.complete(ticket) }
        do {
            try await waitForTurn(ticket)
        } catch {
            return
        }

        for uuid in core.pendingRestore {
            do {
                let characteristic = try await resolveCharacteristic(uuid)
                try await suspend { resume in
                    core.setNotify(true, on: characteristic, resume)
                }
                core.markRestored(uuid)
                core.reconnectLog.debug("restored subscription \(uuid)", core.peripheralMetadata)
            } catch {
                core.reconnectLog.error(
                    "subscription restore failed for \(uuid): \(error)", core.peripheralMetadata
                )
                core.failSubscriptions(uuid, with: error)
            }
        }
    }
}
