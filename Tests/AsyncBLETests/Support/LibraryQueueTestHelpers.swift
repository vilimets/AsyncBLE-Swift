// Getting a test onto the library queue, and a stand-in for the connections the bridge routes
// to before Phase 2d builds the real ones.

import Foundation

@testable import AsyncBLE

extension LibraryQueue {
    /// Runs `body` on the library queue and waits for it.
    ///
    /// The engine asserts it is on the queue, because everything `@unchecked Sendable` in the
    /// library depends on that being true. A test drives it from the outside, so it has to say
    /// so explicitly — which is the same hop the `Central` actor's executor performs for real
    /// callers, made visible.
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        try dispatchQueue.sync(execute: body)
    }
}

/// Records what the central-side bridge routed to a connection.
final class FakeSink: ConnectionSink, @unchecked Sendable {
    enum Event: Equatable {
        case connected
        case failedToConnect(NSError?)
        case disconnected(NSError?)
        case adapterChanged(AdapterState)
    }

    let peripheralID: UUID
    private(set) var events: [Event] = []

    init(peripheralID: UUID) {
        self.peripheralID = peripheralID
    }

    func handleConnected() {
        events.append(.connected)
    }

    func handleFailedToConnect(_ error: NSError?) {
        events.append(.failedToConnect(error))
    }

    func handleDisconnected(_ error: NSError?) {
        events.append(.disconnected(error))
    }

    func handleAdapterChange(_ state: AdapterState) {
        events.append(.adapterChanged(state))
    }
}
