// The central's own engine: waiting for the adapter, and the registry rules from PLAN.md §7
// Q3, Q9 and Q10 — one connection per peripheral, held until it ends, shared by every caller.

@preconcurrency import CoreBluetooth
import Foundation

extension Central {
    /// Waits for the adapter to say something definitive, and throws if that is bad news.
    ///
    /// `scan(_:)` and `connect(_:timeout:)` are `async throws` for exactly this (PLAN.md §7
    /// Q7.4): a freshly created central reports `unknown` for a few milliseconds, and failing
    /// during that window would make every app's first call a coin toss.
    func requirePoweredOn() async throws {
        guard case .unavailable(let reason) = await definitiveAdapterState() else { return }
        throw BluetoothError.bluetoothUnavailable(reason: reason)
    }

    /// The adapter's state once it is something other than "not yet known".
    private func definitiveAdapterState() async -> AdapterState {
        let current = bridge.adapterStates.current
        guard current == .unavailable(.unknown) else { return current }

        for await state in bridge.adapterStates.stream() where state != .unavailable(.unknown) {
            return state
        }
        return bridge.adapterStates.current
    }

    /// The shared path behind ``Central/connect(_:timeout:)`` and
    /// ``Central/connectWhenAvailable(_:)``.
    ///
    /// - Parameters:
    ///   - peripheralID: Which peripheral.
    ///   - timeout: The deadline for the attempt, or `nil` to pend indefinitely.
    func establish(_ peripheralID: UUID, timeout: Duration?) async throws -> Connection {
        try await requirePoweredOn()
        let connection = try connection(for: peripheralID)
        let core = connection.core

        if core.state == .connected {
            // Already up. A link is device-wide, so this caller gets the one that exists
            // (PLAN.md §7 Q3) rather than a second one.
            return connection
        }

        // Who owns the deadline depends on what this caller found. Starting an attempt arms the
        // state machine's timeout, which is what actually withdraws the CoreBluetooth request.
        // Joining one — or joining a reconnect wait, which may be indefinite — cannot restart
        // that, so the caller carries its own deadline and detaches when it expires.
        var callerTimeout = timeout
        if case .disconnected = core.state {
            core.requestConnect(timeout: timeout)
            callerTimeout = nil
        }

        try await waitForLink(on: core, timeout: callerTimeout)
        return connection
    }

    /// Suspends until the link comes up, this caller gives up, or the connection ends.
    private func waitForLink(on core: ConnectionCore, timeout: Duration?) async throws {
        let handle = ConnectAttemptHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handle.begin(core: core, continuation: continuation, timeout: timeout, scheduler: scheduler)
            }
        } onCancel: { [library] in
            library.dispatchQueue.async { handle.cancel() }
        }
    }

    /// The connection for a peripheral, creating one if this central has none.
    ///
    /// One per peripheral, for the whole central: coalescing two callers onto one attempt and
    /// handing them one object is the same thing (PLAN.md §7 Q7.1, Q3).
    private func connection(for peripheralID: UUID) throws -> Connection {
        if let existing = registry.connection(for: peripheralID) {
            return existing
        }

        guard let peripheral = bridge.seam.peripheral(withID: peripheralID) else {
            // CoreBluetooth has never heard of this identifier — nothing has scanned for it and
            // no earlier session connected to it, so there is nothing to connect to.
            throw BluetoothError.connectionFailed(underlying: nil)
        }

        let core = ConnectionCore(
            peripheral: peripheral,
            bridge: bridge,
            library: library,
            scheduler: scheduler,
            policy: configuration.reconnectPolicy
        )
        let connection = Connection(core: core)
        core.onTerminated = { [weak registry] in
            registry?.remove(peripheralID: peripheralID)
        }
        registry.insert(connection)
        bridge.register(core)
        return connection
    }
}
