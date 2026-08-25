// The central's record of which peripherals it currently has connections for.
//
// PLAN.md §7 Q9: a link lives until something explicitly closes it. Dropping the last app
// reference does not close it — ARC deciding when the radio turns off is not debuggable, and it
// contradicts Q3, where a link is device-wide rather than per-caller. So the registry holds a
// connection strongly until it reaches terminal `disconnected`, and lets go then.
//
// Cost accepted, and written down: a link nobody closes leaks. `Central.activeConnections` and
// `disconnectAll()` are on the Planned list for exactly that.
//
// Queue-confined, so the connection's own terminal callback can clear its entry synchronously
// from the queue it fires on.

import Foundation

/// The live connections of one ``Central``, by peripheral identifier.
final class ConnectionRegistry: @unchecked Sendable {
    private var connections: [UUID: Connection] = [:]

    /// The connection for a peripheral, if one is live.
    func connection(for peripheralID: UUID) -> Connection? {
        connections[peripheralID]
    }

    /// Takes ownership of a connection.
    func insert(_ connection: Connection) {
        connections[connection.peripheralID] = connection
    }

    /// Lets one go, once it has ended.
    func remove(peripheralID: UUID) {
        connections.removeValue(forKey: peripheralID)
    }

    /// How many links this central is holding.
    var count: Int { connections.count }
}
