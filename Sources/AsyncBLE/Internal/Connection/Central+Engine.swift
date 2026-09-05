// The central's own engine: waiting for the adapter, and the registry rules
// One connection per peripheral, held until it ends, shared by every caller.

@preconcurrency import CoreBluetooth
import Foundation

extension Central {
    /// Waits for the adapter to say something definitive, and throws if that is bad news.
    ///
    /// `scan(_:)` and `connect(_:timeout:)` are `async throws` for exactly this: a freshly
    /// created central reports `unknown` for a few milliseconds, and failing during that window
    /// would make every app's first call a coin toss.
    func requirePoweredOn() async throws {
        guard case .unavailable(reason: let reason) = await definitiveAdapterState() else { return }
        log.error("bluetooth unavailable: \(reason)")
        throw BluetoothError.bluetoothUnavailable(reason: reason)
    }

    /// The adapter's state once it is something other than "not yet known".
    private func definitiveAdapterState() async -> AdapterState {
        let current = bridge.adapterStates.current
        guard current == .unavailable(reason: .unknown) else { return current }

        for await state in bridge.adapterStates.stream() where state != .unavailable(reason: .unknown) {
            return state
        }
        return bridge.adapterStates.current
    }

    /// The shared path behind ``Central/connect(_:timeout:)`` and
    /// ``Central/connectWhenInRange(_:)``.
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
            // rather than a second one.
            log.debug("connect \(peripheralID): returning the live connection", ["peripheral": peripheralID.uuidString])
            return connection
        }

        // Who owns the deadline depends on what this caller found. Starting an attempt arms the
        // state machine's timeout, which is what actually withdraws the CoreBluetooth request.
        // Joining one — or joining a reconnect wait, which may be indefinite — cannot restart
        // that, so the caller carries its own deadline and detaches when it expires.
        // Both the metadata dictionary and the `Duration` interpolation stay inside the
        // autoclosures — hoisted into `let`s they were built on every connect, logging or not.
        var callerTimeout = timeout
        if case .disconnected = core.state {
            log.info(
                "connect \(peripheralID) requested (timeout: \(timeout.map { "\($0)" } ?? "none"))",
                core.peripheralMetadata
            )
            core.requestConnect(timeout: timeout)
            callerTimeout = nil
        } else {
            log.debug("connect \(peripheralID): coalescing onto the attempt in flight", core.peripheralMetadata)
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
    /// handing them one object is the same thing.
    private func connection(for peripheralID: UUID) throws -> Connection {
        if let existing = registry.connection(for: peripheralID) {
            return existing
        }

        guard let peripheral = bridge.seam.peripheral(withID: peripheralID) else {
            // CoreBluetooth has never heard of this identifier — nothing has scanned for it and
            // no earlier session connected to it, so there is nothing to connect to.
            log.error(
                "connect \(peripheralID): CoreBluetooth has no peripheral with this identifier",
                ["peripheral": peripheralID.uuidString]
            )
            throw BluetoothError.connectionFailed(underlying: nil)
        }

        let core = ConnectionCore(
            peripheral: peripheral,
            bridge: bridge,
            library: library,
            scheduler: scheduler,
            policy: configuration.reconnectPolicy,
            log: logFacility
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
