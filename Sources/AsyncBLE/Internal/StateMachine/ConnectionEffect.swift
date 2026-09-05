// Outputs of the state machine: side effects for the caller to perform — arm/cancel a CB
// connect, arm/cancel the timeout, start/stop the give-up deadline, arm/cancel the re-arm
// timer, invalidate the discovery cache, restore subscriptions, fail queued I/O.
//
// Effects are values, not closures — that keeps them assertable in tests.

import Foundation

/// A side effect the state machine wants performed, as a value.
///
/// Values rather than closures on purpose: a test asserts on the array the machine returned,
/// which is the whole reason the transition table can be verified without a radio, a clock, or
/// a mock. Performing them is somebody else's job — the delegate bridge drives the radio, the
/// connection drives its cache, queue and subscriptions.
///
/// The order within a returned array is meaningful and is asserted in tests: teardown before
/// setup, and queued I/O is always failed before a reconnect is armed, so a caller can never
/// see a write land on the far side of a drop it was queued before.
enum ConnectionEffect: Sendable, Equatable {
    /// Issue `connect(peripheral:options:)`. Stays pending until fulfilled or cancelled.
    case armConnect

    /// Issue `cancelPeripheralConnection(_:)`, which both closes a live link and withdraws a
    /// pending connect — CoreBluetooth uses the one call for both.
    case cancelConnect

    /// Start the connect attempt's deadline. Fires ``ConnectionEvent/connectTimedOut``.
    ///
    /// - Parameter duration: How long the attempt may run.
    case startConnectTimeout(Duration)

    /// Cancel the connect attempt's deadline.
    case cancelConnectTimeout

    /// Start the reconnect policy's give-up deadline. Fires
    /// ``ConnectionEvent/giveUpDeadlineReached``.
    ///
    /// Wall-clock: it is never paused, including while the adapter is off.
    ///
    /// - Parameter duration: How long to keep waiting.
    case startGiveUpDeadline(Duration)

    /// Cancel the give-up deadline.
    case cancelGiveUpDeadline

    /// Start one cycle of the optional re-arm cadence. Fires
    /// ``ConnectionEvent/reArmTimerFired``.
    ///
    /// One-shot, re-issued each cycle rather than repeating, so that "cancel" needs no
    /// separate bookkeeping and a test can step the cadence one arm at a time.
    ///
    /// - Parameter interval: The cadence from ``ReconnectPolicy/reArmInterval``.
    case startReArmTimer(Duration)

    /// Cancel the re-arm cadence. Emitted when the adapter goes away, because re-arming
    /// against a dead radio achieves nothing.
    case cancelReArmTimer

    /// Drop every cached `CBService` and `CBCharacteristic`.
    ///
    /// CoreBluetooth invalidates those objects on disconnect, so they cannot survive a drop —
    /// and on the way back in they are rebuilt lazily, on first use.
    case invalidateDiscoveryCache

    /// Hold notification streams open but stop yielding: the link is gone and the
    /// subscriptions behind them are to be re-established if it comes back.
    case markSubscriptionsForRestore

    /// Re-walk discovery and re-subscribe every marked notification stream.
    ///
    /// A stream whose characteristic did not come back throws rather than finishing quietly;
    /// the machine does not model that, since it is per-characteristic.
    case restoreSubscriptions

    /// Fail every queued and in-flight read and write, in call order.
    ///
    /// - Parameter reason: What to report as ``BluetoothError/disconnected(reason:)``.
    case endPendingOperations(reason: DisconnectReason)

    /// End every notification stream, because the connection is over for good.
    ///
    /// - Parameter reason: Why it ended. The subscription layer decides how that reads to a
    ///   consumer: ``DisconnectReason/userInitiated`` finishes a stream, anything else throws,
    ///   because a stream that stops on its own is indistinguishable from a quiet sensor.
    case endSubscriptions(reason: DisconnectReason)
}
