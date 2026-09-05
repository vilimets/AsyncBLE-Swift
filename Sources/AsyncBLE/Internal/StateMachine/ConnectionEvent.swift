// Inputs to the state machine: connectRequested, didConnect, didFailToConnect,
// didDisconnect(error:userInitiated:), connectTimedOut, disconnectRequested, reArmTimerFired,
// giveUpDeadlineReached, adapterChanged(AdapterState), restored(connected:).
//
// `reconnectTimerFired` is gone with the backoff curve; re-arming is now an optional cadence
// rather than the mechanism.

import Foundation

/// Everything that can move a connection from one state to another.
///
/// The set mirrors CoreBluetooth's central-manager callbacks plus the library's own timers, so
/// the delegate bridge translates one-to-one and never has to decide anything: it builds an
/// event, feeds it in, and performs whatever effects come back.
///
/// Errors ride along as `NSError?` — CoreBluetooth's errors are all `NSError`, and `Error?`
/// would cost `Equatable`, which is what lets a test assert on a whole event sequence. The
/// machine itself never reads the payload: `DisconnectReason` deliberately carries no error,
/// and the bridge that *built* the event is the thing that still holds the error when it comes
/// time to resume a waiter with ``BluetoothError/connectionFailed(underlying:)``.
enum ConnectionEvent: Sendable, Equatable {
    /// Someone asked for a link.
    ///
    /// - Parameter timeout: The deadline for the attempt, or `nil` for a pending connect with
    ///   no deadline — ``Central/connectWhenInRange(_:)``.
    case connectRequested(timeout: Duration?)

    /// CoreBluetooth reported the link is up.
    case didConnect

    /// CoreBluetooth reported the connect attempt failed outright.
    case didFailToConnect(NSError?)

    /// The link ended.
    ///
    /// CoreBluetooth fires one callback for both a peripheral walking out of range and a
    /// disconnect this library asked for; `userInitiated` is the internal flag that tells them
    /// apart, and it is the whole reason a drop can start a reconnect wait while
    /// a deliberate disconnect cannot.
    case didDisconnect(NSError?, userInitiated: Bool)

    /// The connect attempt ran out of time. Only a bounded attempt can produce this.
    case connectTimedOut

    /// ``Connection/disconnect()`` was called.
    case disconnectRequested

    /// The optional re-arm cadence came round: cancel the pending connect and re-issue it.
    case reArmTimerFired

    /// A bounded reconnect policy's deadline expired.
    case giveUpDeadlineReached

    /// The Bluetooth adapter's availability changed.
    case adapterChanged(AdapterState)

    /// iOS handed this connection back after relaunching the app, and it starts life mid-story
    /// rather than at `disconnected`.
    ///
    /// - Parameter connected: Whether the link is up. `false` means the OS was still holding a
    ///   pending connect on the library's behalf, which is a reconnect wait by another name.
    case restored(connected: Bool)
}
