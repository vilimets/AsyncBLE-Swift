// A live link to one peripheral. Actor-isolated; state escapes only through streams.
//
// Phase 1: `state`/`states`, `read`/`write`/`notifications(for:)`, `disconnect()`, and the
// `withRaw` escape hatch.

@preconcurrency import CoreBluetooth
import Foundation

/// A live link to one peripheral.
///
/// Created by ``Central/connect(_:timeout:)``, which returns only once the link is up. Address
/// characteristics by UUID and the connection discovers them for you, caching the result for
/// as long as the link lives.
///
/// A connection is an actor and its state escapes only through ``states``: there is no way to
/// observe a state the state machine did not produce.
///
/// ## Lifetime
///
/// The connection survives a dropped link — it moves to `reconnecting` and keeps its identity,
/// so held references stay valid and subscriptions are restored when the link returns. It ends
/// only when something explicitly ends it: ``disconnect()``, or the reconnect policy giving up.
/// Dropping your last reference does **not** close the link; the owning ``Central`` keeps it
/// until then (PLAN.md §7 Q9).
///
/// ## Sharing
///
/// Two callers connecting to the same peripheral get the *same* connection. A link is a
/// device-wide resource rather than a per-caller session, so ``disconnect()`` ends it for
/// everyone holding it.
///
/// ## Ordering
///
/// Reads and writes execute in the order they were called, across all callers — the connection
/// runs them through a single queue. That is close to free: ATT allows only one outstanding
/// request per connection anyway, so the queue mostly formalizes what the wire already does.
/// Without it, actor reentrancy would let concurrent callers interleave at suspension points
/// and reorder packets (PLAN.md §7 Q4, Q11).
public actor Connection {
    /// Whether a write waits for the peripheral to acknowledge it.
    public enum WriteMode: Sendable, Equatable {
        /// Wait for the peripheral's acknowledgement, and surface a failure as a thrown error.
        ///
        /// Slower — one round trip per write — but the only mode that can report a failure.
        case withResponse

        /// Fire and forget: the peripheral never acknowledges, so nothing can report a failure.
        ///
        /// Much faster, and the right choice for streaming throughput. The library still
        /// applies flow control, so a write suspends until the peripheral has room for it
        /// rather than being dropped on the floor.
        case withoutResponse
    }

    /// The identifier of the peripheral at the other end.
    public nonisolated let peripheralID: UUID

    /// The current state of the link.
    ///
    /// A point-in-time snapshot. To follow transitions, iterate ``states`` instead — polling
    /// this in a loop will miss states that pass quickly.
    public var state: ConnectionState {
        fatalError("Phase 2: read the state machine's current state")
    }

    /// The stream of state transitions.
    ///
    /// Each call returns an independent stream that yields the current state immediately and
    /// then every subsequent transition, so a late observer is never left guessing. The stream
    /// finishes when the connection reaches `disconnected` for good.
    ///
    /// ```swift
    /// for await state in connection.states {
    ///     if case .reconnecting(let attempt) = state { print("waiting, arm \(attempt)") }
    /// }
    /// ```
    public nonisolated var states: AsyncStream<ConnectionState> {
        fatalError("Phase 2: subscribe a new consumer to the state broadcaster")
    }

    /// Creates a connection. Not part of the public API surface — use ``Central``.
    init(peripheralID: UUID) {
        self.peripheralID = peripheralID
    }

    /// Reads a characteristic's current value.
    ///
    /// Discovers the characteristic on first use and caches it; concurrent readers of the same
    /// characteristic share one discovery rather than each starting their own. Queued behind
    /// any earlier read or write on this connection.
    ///
    /// - Parameter characteristic: The characteristic's UUID.
    /// - Returns: The bytes the peripheral returned.
    /// - Throws: ``BluetoothError/characteristicNotFound(_:)`` if the peripheral does not have
    ///   it, ``BluetoothError/operationNotSupported`` if it is not readable, or
    ///   ``BluetoothError/disconnected(reason:)`` if the link is down — including while the
    ///   connection is `reconnecting`, which fails immediately rather than waiting.
    public func read(_ characteristic: CBUUID) async throws -> Data {
        fatalError("Phase 2: enqueue, resolve the characteristic, then await readValue")
    }

    /// Writes a value to a characteristic.
    ///
    /// With ``WriteMode/withResponse`` this returns once the peripheral acknowledges. With
    /// ``WriteMode/withoutResponse`` it returns once the write has been handed to the radio,
    /// suspending first if the peripheral has no room — that flow control is what keeps a
    /// tight write loop from silently dropping packets.
    ///
    /// Writes issued while the connection is `reconnecting` fail rather than queue: a command
    /// composed against pre-drop state should not land on a device that may have rebooted
    /// into a different one.
    ///
    /// - Parameters:
    ///   - data: The bytes to write. Anything over the negotiated MTU is rejected by
    ///     CoreBluetooth rather than split; check `maximumWriteValueLength(for:)` through
    ///     ``withRaw(_:)`` if you are near the limit.
    ///   - characteristic: The characteristic's UUID.
    ///   - mode: Whether to wait for an acknowledgement. Defaults to
    ///     ``WriteMode/withResponse``.
    /// - Throws: ``BluetoothError/characteristicNotFound(_:)`` if the peripheral does not have
    ///   it, ``BluetoothError/operationNotSupported`` if it does not accept writes in this
    ///   mode, or ``BluetoothError/disconnected(reason:)`` if the link is down.
    public func write(_ data: Data, to characteristic: CBUUID, mode: WriteMode = .withResponse) async throws {
        fatalError("Phase 2: enqueue, resolve the characteristic, apply flow control, write")
    }

    /// Subscribes to a characteristic's notifications.
    ///
    /// Returns once the peripheral has confirmed the subscription, so a stream you receive is
    /// already live. Ending iteration — by cancelling the task, breaking out, or dropping the
    /// stream — unsubscribes.
    ///
    /// ## Across a reconnect
    ///
    /// The stream is a subscription to a characteristic, not to a link. When a dropped link
    /// comes back, the library re-walks discovery and re-subscribes underneath you, and the
    /// same stream keeps yielding. Values sent while the link was down are gone — watch
    /// ``states`` if you need to know a gap happened. If the subscription cannot be restored
    /// — the peripheral came back without that characteristic, say — the stream throws rather
    /// than finishing silently, because a stream that just stops is indistinguishable from a
    /// quiet sensor.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic's UUID.
    ///   - bufferingPolicy: What to do when values arrive faster than they are consumed.
    ///     Defaults to `.bufferingNewest(256)`: bounded, so a slow consumer cannot grow memory
    ///     without limit. Pass `.unbounded` when losing a packet is not acceptable — a
    ///     firmware image or any packetized protocol — and be sure you can keep up.
    /// - Returns: A stream of values, one per notification.
    /// - Throws: ``BluetoothError/characteristicNotFound(_:)`` if the peripheral does not have
    ///   it, ``BluetoothError/operationNotSupported`` if it neither notifies nor indicates, or
    ///   ``BluetoothError/disconnected(reason:)`` if the link is down.
    public func notifications(
        for characteristic: CBUUID,
        bufferingPolicy: AsyncThrowingStream<Data, Error>.Continuation.BufferingPolicy = .bufferingNewest(256)
    ) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("Phase 2: resolve the characteristic, setNotifyValue, bridge to a stream")
    }

    /// Closes the link and stops waiting for it to come back.
    ///
    /// This is the user-initiated path: the state goes to
    /// `disconnected(reason: .userInitiated)` and the reconnect policy is not consulted,
    /// however the link would otherwise have been waited for.
    ///
    /// > Important: A link is device-wide, not per-caller. If another part of your app
    /// > connected to the same peripheral it holds this same connection, and this call ends
    /// > the link for it too.
    ///
    /// Idempotent, and safe to call from any state. In-flight and queued reads and writes fail
    /// with ``BluetoothError/disconnected(reason:)``.
    public func disconnect() async {
        fatalError("Phase 2: feed disconnectRequested into the state machine")
    }
}
