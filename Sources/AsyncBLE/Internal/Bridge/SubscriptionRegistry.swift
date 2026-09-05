// The notification streams, and the bookkeeping that lets them outlive the link they were
// created on.
//
// A stream from `notifications(for:)` is a subscription to a characteristic, not to a link. So
// this registry — not the discovery cache, and not CoreBluetooth's `isNotifying` flag — is the
// record of what the caller asked for. A reconnect re-walks discovery and re-subscribes from
// this list, underneath a caller who never sees the gap.
//
// Several callers may subscribe to the same characteristic. CoreBluetooth has one notify flag
// per characteristic, so the registry fans one stream of values out to all of them, and only
// turns the flag off when the last one leaves — the same shape as the scan sessions.
//
// Queue-confined and synchronous.

@preconcurrency import CoreBluetooth
import Foundation

/// The live notification streams of one connection.
final class SubscriptionRegistry: @unchecked Sendable {
    /// One caller's `notifications(for:)` stream.
    final class Subscription: @unchecked Sendable {
        let uuid: CBUUID
        fileprivate let continuation: AsyncThrowingStream<Data, Error>.Continuation

        fileprivate init(uuid: CBUUID, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.uuid = uuid
            self.continuation = continuation
        }
    }

    /// Called when the last subscriber to a characteristic goes away, so the connection can
    /// turn the peripheral's notify flag back off.
    var onLastSubscriberRemoved: ((CBUUID) -> Void)?

    private let library: LibraryQueue
    private let log: Log
    private var subscriptions: [CBUUID: [Subscription]] = [:]
    private var awaitingRestore: Set<CBUUID> = []

    init(library: LibraryQueue, log: LogFacility = .disabled) {
        self.library = library
        self.log = log.scoped(.reconnect)
    }

    /// The characteristics with at least one live subscriber.
    var activeUUIDs: [CBUUID] { Array(subscriptions.keys) }

    /// The characteristics whose subscriptions are waiting for the link to come back.
    var pendingRestore: Set<CBUUID> { awaitingRestore }

    /// Whether anyone is subscribed to a characteristic.
    ///
    /// The connection uses this to decide whether a `setNotifyValue(true)` is needed at all: a
    /// second subscriber to a live characteristic joins without touching the radio.
    func hasSubscribers(for uuid: CBUUID) -> Bool {
        subscriptions[uuid]?.isEmpty == false
    }

    /// How many streams are live, across every characteristic.
    var count: Int { subscriptions.values.reduce(0) { $0 + $1.count } }

    /// Creates and registers a stream.
    ///
    /// Registered before the peripheral has confirmed, so that a caller who abandons the stream
    /// while the confirmation is in flight still unsubscribes cleanly. The connection removes
    /// it again if the subscribe fails.
    func subscribe(
        to uuid: CBUUID,
        bufferingPolicy: AsyncThrowingStream<Data, Error>.Continuation.BufferingPolicy
    ) -> (subscription: Subscription, stream: AsyncThrowingStream<Data, Error>) {
        var subscription: Subscription?
        let stream = AsyncThrowingStream(Data.self, bufferingPolicy: bufferingPolicy) { continuation in
            let new = Subscription(uuid: uuid, continuation: continuation)
            subscription = new
            subscriptions[uuid, default: []].append(new)
            continuation.onTermination = terminator(for: new)
        }
        // The builder closure runs synchronously, so this is never nil.
        guard let subscription else { preconditionFailure("AsyncThrowingStream did not build its continuation") }
        return (subscription, stream)
    }

    /// The termination handler for one subscription.
    ///
    /// Built at method scope rather than inline in the stream builder: a `[weak self]` capture
    /// written inside another closure captures *that* closure's `self`, which Swift 6 rejects as
    /// a reference to a captured var from concurrently-executing code.
    private func terminator(
        for subscription: Subscription
    ) -> @Sendable (AsyncThrowingStream<Data, Error>.Continuation.Termination) -> Void {
        // The weak reference is promoted before the queue hop rather than inside it. A weak
        // capture is a `var` — it can become nil — and Swift 6 rejects reading one from
        // concurrently-executing code. Promoting first also means that once termination has
        // decided the registry is alive, the removal is guaranteed to run.
        { [weak registry = self, library] _ in
            guard let registry else { return }
            library.dispatchQueue.async { registry.remove(subscription) }
        }
    }

    /// Removes one stream, and reports when it was the last one for its characteristic.
    func remove(_ subscription: Subscription) {
        // Mutated in place: binding the array out first would leave the dictionary holding a
        // second reference, forcing a copy of the whole subscriber list on every removal.
        // Identity is the object's — a `Subscription` is a class, so `===` needs no stored id.
        guard subscriptions[subscription.uuid] != nil else { return }
        subscriptions[subscription.uuid]?.removeAll { $0 === subscription }

        if subscriptions[subscription.uuid]?.isEmpty == true {
            subscriptions.removeValue(forKey: subscription.uuid)
            awaitingRestore.remove(subscription.uuid)
            onLastSubscriberRemoved?(subscription.uuid)
        }
    }

    /// Fans a notification out to everyone subscribed to that characteristic.
    func deliver(_ data: Data, for uuid: CBUUID) {
        for subscription in subscriptions[uuid] ?? [] {
            subscription.continuation.yield(data)
        }
    }

    /// Ends every stream for one characteristic, with an error.
    ///
    /// The reconnect case: the link came back but the characteristic did
    /// not. Throwing says so; finishing would be indistinguishable from a quiet sensor.
    func fail(_ uuid: CBUUID, with error: Error) {
        let ending = subscriptions.removeValue(forKey: uuid) ?? []
        if !ending.isEmpty {
            log.error("ending \(ending.count) subscriber(s) of \(uuid): \(error)")
        }
        awaitingRestore.remove(uuid)
        for subscription in ending {
            subscription.continuation.finish(throwing: error)
        }
    }

    // MARK: Across a reconnect

    /// Notes that every live subscription now needs re-establishing.
    ///
    /// The streams stay open and stay silent — there is nothing to yield while the link is
    /// down, and values sent during the outage are simply gone.
    func markForRestore() {
        awaitingRestore = Set(subscriptions.keys)
    }

    /// Notes that one characteristic's subscriptions are live again.
    func markRestored(_ uuid: CBUUID) {
        awaitingRestore.remove(uuid)
    }

    /// Ends every stream, because the connection is over.
    ///
    /// - Parameter reason: ``DisconnectReason/userInitiated`` finishes the streams — the caller
    ///   asked for this, and an error would be noise. Anything else throws, because a stream
    ///   that stops on its own reads exactly like a sensor that went quiet.
    func endAll(reason: DisconnectReason) {
        let ending = subscriptions.values.flatMap { $0 }
        subscriptions.removeAll()
        awaitingRestore.removeAll()

        for subscription in ending {
            if reason == .userInitiated {
                subscription.continuation.finish()
            } else {
                subscription.continuation.finish(throwing: BluetoothError.disconnected(reason: reason))
            }
        }
    }
}
