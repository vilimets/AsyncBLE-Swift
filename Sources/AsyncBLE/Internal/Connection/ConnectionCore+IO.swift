// The synchronous half of every I/O operation: take a place in line, start something on the
// radio, park a continuation for the callback that answers it.
//
// The `Connection` actor supplies the awaiting. Splitting it this way is what keeps FIFO order
// honest — a caller's place in line is taken before it suspends, so nothing can be reordered by
// a hop (PLAN.md §7 Q4, Q11).

@preconcurrency import CoreBluetooth
import Foundation

extension ConnectionCore {
    // MARK: Preconditions

    /// Throws unless the link is up right now.
    ///
    /// This is "I/O fails fast while reconnecting" (PLAN.md §7 Q2). A read or write issued
    /// during an outage does not queue and wait: a command composed against pre-drop state
    /// should not land on a device that may have rebooted into a different one.
    func ensureConnected() throws {
        switch state {
        case .connected:
            return
        case .reconnecting, .connecting:
            throw BluetoothError.disconnected(reason: .linkLost)
        case .disconnected(let reason):
            throw BluetoothError.disconnected(reason: reason ?? .userInitiated)
        }
    }

    // MARK: The queue

    /// Takes a place in line.
    func enqueue() -> IOQueue.Ticket {
        library.assertIsolated()
        return ioQueue.enqueue()
    }

    /// Waits for that place to come up.
    func attachTurn(_ resume: @escaping IOQueue.Resume, to ticket: IOQueue.Ticket) {
        ioQueue.attach(resume, to: ticket)
    }

    /// Gives the place up, whether the operation ran or not.
    func complete(_ ticket: IOQueue.Ticket) {
        ioQueue.complete(ticket)
    }

    /// Abandons a place because the caller's task was cancelled.
    func cancel(_ ticket: IOQueue.Ticket) {
        ioQueue.cancel(ticket)
    }

    // MARK: Discovery

    /// Resolves a characteristic UUID, walking discovery if this link has not been walked yet.
    func resolve(_ uuid: CBUUID, _ deliver: @escaping DiscoveryCache.Deliver) {
        cache.resolve(uuid, deliver)
    }

    // MARK: Reads and writes

    /// Starts a read. The value arrives on the delegate, which is why this parks a callback
    /// rather than returning anything.
    func startRead(_ characteristic: CharacteristicSeam, _ deliver: @escaping (Result<Data, Error>) -> Void) {
        pendingRead = PendingOperation(uuid: characteristic.uuid, deliver: deliver)
        peripheral.readValue(for: characteristic)
    }

    /// Starts a write that the peripheral will acknowledge.
    func startWrite(
        _ data: Data,
        to characteristic: CharacteristicSeam,
        _ deliver: @escaping (Result<Void, Error>) -> Void
    ) {
        pendingWrite = PendingOperation(uuid: characteristic.uuid, deliver: deliver)
        peripheral.writeValue(data, for: characteristic, mode: .withResponse)
    }

    /// Hands a write to the radio with nothing to wait for.
    ///
    /// Fire-and-forget by definition: the peripheral never acknowledges it, so there is no
    /// callback and nothing that could report a failure. Flow control is the only protection,
    /// which is why it is not optional.
    func sendWriteWithoutResponse(_ data: Data, to characteristic: CharacteristicSeam) {
        peripheral.writeValue(data, for: characteristic, mode: .withoutResponse)
    }

    /// Whether the radio has room for a write-without-response right now.
    var canSendWriteWithoutResponse: Bool {
        peripheral.canSendWriteWithoutResponse
    }

    /// Parks a writer until the radio reports room.
    ///
    /// Without this, a tight write loop hands CoreBluetooth packets it silently drops.
    func awaitWriteReady(_ resume: @escaping (Result<Void, Error>) -> Void) {
        writeReadyWaiters.append(resume)
    }

    // MARK: Notifications

    /// Whether anyone is already subscribed to a characteristic.
    ///
    /// A second subscriber joins the existing one rather than touching the radio: CoreBluetooth
    /// has one notify flag per characteristic, not one per interested caller.
    func hasSubscribers(for uuid: CBUUID) -> Bool {
        subscriptions.hasSubscribers(for: uuid)
    }

    /// Creates a notification stream and registers it.
    func subscribe(
        to uuid: CBUUID,
        bufferingPolicy: AsyncThrowingStream<Data, Error>.Continuation.BufferingPolicy
    ) -> (subscription: SubscriptionRegistry.Subscription, stream: AsyncThrowingStream<Data, Error>) {
        subscriptions.subscribe(to: uuid, bufferingPolicy: bufferingPolicy)
    }

    /// Removes a stream — used when the subscribe that would have fed it failed.
    func remove(_ subscription: SubscriptionRegistry.Subscription) {
        subscriptions.remove(subscription)
    }

    /// Turns a characteristic's notifications on or off, and waits for the confirmation.
    func setNotify(
        _ enabled: Bool,
        on characteristic: CharacteristicSeam,
        _ deliver: @escaping (Result<Void, Error>) -> Void
    ) {
        pendingNotify = PendingOperation(uuid: characteristic.uuid, deliver: deliver)
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    /// The characteristics whose subscriptions are waiting for the link to come back.
    var pendingRestore: [CBUUID] {
        Array(subscriptions.pendingRestore)
    }

    /// Notes that one characteristic's subscriptions are live again.
    func markRestored(_ uuid: CBUUID) {
        subscriptions.markRestored(uuid)
    }

    /// Ends one characteristic's streams because the subscription could not be restored.
    func failSubscriptions(_ uuid: CBUUID, with error: Error) {
        subscriptions.fail(uuid, with: error)
    }

    // MARK: The escape hatch

    /// Runs a closure with the live CoreBluetooth objects (PLAN.md §7 Q6).
    ///
    /// Called from the `Connection` actor, whose executor *is* the library queue — so "the
    /// closure runs on the library's queue" is true by construction rather than by convention.
    func withRawObjects<T: Sendable>(
        _ body: @Sendable (CBPeripheral, CBCentralManager) throws -> T
    ) rethrows -> T {
        library.assertIsolated()
        guard let rawPeripheral = peripheral.rawPeripheral, let rawCentral = bridge.seam.rawCentral else {
            // Only reachable behind the test fakes, which have no CoreBluetooth objects to hand
            // out. A real connection always has both.
            preconditionFailure("withRaw is only available over real CoreBluetooth objects")
        }
        return try body(rawPeripheral, rawCentral)
    }
}
