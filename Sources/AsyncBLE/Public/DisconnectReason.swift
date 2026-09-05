// Why a link ended: user-initiated, timeout, connect failure, link drop, reconnect gave up.
//
// The user-initiated vs link-drop distinction is what routes reconnect.

/// Why a connection ended.
///
/// CoreBluetooth reports a user-requested disconnect and a peripheral walking out of range
/// through the *same* delegate callback. Telling them apart is what decides whether the
/// library keeps waiting, so the distinction is made explicit here rather than left to the
/// caller.
public enum DisconnectReason: Sendable, Equatable {
    /// ``Connection/disconnect()`` was called — by you, or by anything else holding this
    /// connection. No reconnect is waited for.
    case userInitiated

    /// The connect attempt exceeded its timeout.
    ///
    /// CoreBluetooth has no native connect timeout — a `connect` request stays pending
    /// forever — so this reason only exists because ``Central/connect(_:timeout:)-(UUID,_)`` imposes
    /// one. ``Central/connectWhenInRange(_:)`` never produces it.
    case connectTimeout

    /// CoreBluetooth reported that the connect attempt failed.
    case connectionFailed

    /// The link dropped: out of range, peripheral powered down, or supervision timeout.
    ///
    /// This is the reason that starts a reconnect wait when the policy allows one.
    case linkLost

    /// The reconnect policy's deadline expired while waiting for the link to come back.
    ///
    /// Only ``ReconnectPolicy/giveUp(after:reArmEvery:)`` can produce this; an indefinite
    /// policy waits as long as the peripheral takes. The deadline is wall-clock — see
    /// <doc:Reconnection>.
    case reconnectGaveUp

    /// The Bluetooth adapter became unusable and no reconnect was being waited for.
    ///
    /// Reported when the policy is ``ReconnectPolicy/never``. Under any waiting policy the
    /// connection stays in `reconnecting` instead, because the adapter coming back is exactly
    /// the event the pending connect is waiting for.
    case bluetoothUnavailable(reason: UnavailableReason)
}
