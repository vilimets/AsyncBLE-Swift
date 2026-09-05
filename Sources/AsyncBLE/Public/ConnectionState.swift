// The four observable states: disconnected(reason:), connecting, connected, reconnecting(arm:).
//
// Mirrors the state machine; the pure machine in Internal/StateMachine owns transitions.

/// The state of a ``Connection``.
///
/// These four cases are the whole truth about a link. Observe them through
/// ``Connection/states``; nothing else in the library changes state behind their back.
public enum ConnectionState: Sendable, Equatable {
    /// No link, and none being waited for.
    ///
    /// - Parameter reason: Why the last link ended, or `nil` if no link has ended yet —
    ///   which is the state a connection starts in.
    case disconnected(reason: DisconnectReason?)

    /// A connect attempt is in flight, with the configured timeout running against it.
    case connecting

    /// The link is up and I/O is possible.
    case connected

    /// The link dropped and the reconnect policy is still waiting for it to come back.
    ///
    /// - Parameter arm: The 1-based number of the current arm of the pending connect.
    ///   Not a retry count — see below.
    ///
    /// The OS holds a pending connect and fulfils it when the peripheral reappears, so there is
    /// usually exactly *one* attempt no matter how long the wait: expect this to read `1` for
    /// the whole outage unless you set ``ReconnectPolicy/reArmInterval``, which increments it
    /// on every re-arm. CoreBluetooth reporting an outright connect failure also increments it.
    ///
    /// A connection stays here while Bluetooth is switched off. A bounded policy's deadline
    /// keeps running during that time — see <doc:Reconnection> — so a long power-off can end
    /// the wait in ``DisconnectReason/reconnectGaveUp``.
    case reconnecting(arm: Int)
}

extension ConnectionState {
    /// Whether the link is currently up.
    ///
    /// Convenience for driving UI; the same information as matching on ``connected``.
    public var isConnected: Bool {
        self == .connected
    }
}
