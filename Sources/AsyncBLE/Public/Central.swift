// Entry point of the library: adapter lifecycle, scanning, and connecting.
//
// Phase 1: `scan(_:)`, `connect(_:timeout:)` with a configurable timeout,
// `connectWhenAvailable(_:)` for the pend-until-it-appears case, and `adapterStates`.

@preconcurrency import CoreBluetooth
import Foundation

/// The entry point: owns the Bluetooth adapter, scans for peripherals, and connects to them.
///
/// Create one and keep it alive for as long as you need Bluetooth — creating a central is what
/// triggers the system permission prompt, and each one is a real `CBCentralManager`.
///
/// ```swift
/// let central = Central()
/// for await device in try await central.scan(services: [heartRate]) {
///     let connection = try await central.connect(device)
///     print(try await connection.read(measurement))
///     await connection.disconnect()
///     break
/// }
/// ```
///
/// No CoreBluetooth type appears in any signature here — `CBUUID` excepted, as the identifier
/// type (PLAN.md §3).
public actor Central {
    /// The tunables this central was created with.
    public nonisolated let configuration: Configuration

    /// Creates a central and begins bringing up the Bluetooth adapter.
    ///
    /// The adapter takes a moment to report its state, and on first use the system asks the
    /// user for permission. You do not need to wait: ``scan(_:)`` and ``connect(_:timeout:)``
    /// each await a definitive adapter state before acting, and throw
    /// ``BluetoothError/bluetoothUnavailable(reason:)`` if it is not usable.
    ///
    /// - Parameter configuration: Connect timeout, reconnect policy, and power alert
    ///   behavior. Defaults to a 10-second timeout and indefinite reconnection.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The stream of Bluetooth adapter availability.
    ///
    /// Yields the current state immediately, then every change. This is how an app knows to
    /// re-try a scan that failed with ``BluetoothError/bluetoothUnavailable(reason:)``, and how
    /// it drives a "Bluetooth is off" banner without creating a second `CBCentralManager`.
    ///
    /// Each call returns an independent stream. The stream never finishes while the central
    /// is alive.
    ///
    /// ```swift
    /// for await state in central.adapterStates {
    ///     banner.isHidden = (state == .poweredOn)
    /// }
    /// ```
    public nonisolated var adapterStates: AsyncStream<AdapterState> {
        fatalError("Phase 2: subscribe a new consumer to the adapter-state broadcaster")
    }

    /// Scans for peripherals.
    ///
    /// The scan starts when you begin iterating and stops when you stop: cancelling the task,
    /// breaking out of the loop, or dropping the stream all call through to `stopScan()`. A
    /// scan that outlives its consumer is a battery bug, so the library will not let one
    /// happen.
    ///
    /// An adapter that becomes unavailable *during* a scan finishes the stream. Only an
    /// adapter that is unusable when the scan starts throws — watch ``adapterStates`` to know
    /// when it is worth trying again.
    ///
    /// - Parameter options: What to scan for, and whether to report repeat advertisements.
    ///   Defaults to an unfiltered scan reporting each peripheral once.
    /// - Returns: A stream of discoveries, one per advertising packet reported.
    /// - Throws: ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not
    ///   powered on.
    public func scan(_ options: ScanOptions = ScanOptions()) async throws -> AsyncStream<Discovery> {
        fatalError("Phase 2: await poweredOn, scanForPeripherals, bridge delegate to a stream")
    }

    /// Scans for peripherals advertising the given services.
    ///
    /// Convenience for the common case. See ``scan(_:)`` for the full contract.
    ///
    /// - Parameters:
    ///   - services: The service UUIDs a peripheral must advertise to be reported.
    ///   - allowDuplicates: Whether to report repeated advertising packets from the same
    ///     peripheral. Defaults to `false`.
    /// - Returns: A stream of discoveries.
    /// - Throws: ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not
    ///   powered on.
    public func scan(
        services: [CBUUID],
        allowDuplicates: Bool = false
    ) async throws -> AsyncStream<Discovery> {
        try await scan(ScanOptions(services: services, allowDuplicates: allowDuplicates))
    }

    /// Connects to a peripheral by identifier, within a deadline.
    ///
    /// Returns only once the link is up. If it does not come up within the timeout, the pending
    /// CoreBluetooth request is cancelled and ``BluetoothError/connectTimeout`` is thrown —
    /// CoreBluetooth itself would have waited forever. Use ``connectWhenAvailable(_:)`` when
    /// waiting forever is what you actually want.
    ///
    /// Concurrent calls for the same peripheral coalesce onto a single attempt and all resume
    /// with the same ``Connection``; a call for an already-connected peripheral returns the
    /// live connection. Cancelling one caller's task detaches that caller only — the attempt
    /// continues while any other caller is still waiting (PLAN.md §7 Q10).
    ///
    /// - Parameters:
    ///   - peripheralID: The peripheral's identifier, from a ``Discovery`` or persisted from
    ///     an earlier session.
    ///   - timeout: Overrides ``Central/Configuration/connectTimeout`` for this call.
    /// - Returns: A live connection, shared with any other caller connecting to the same
    ///   peripheral.
    /// - Throws: ``BluetoothError/connectTimeout`` if the attempt runs out of time,
    ///   ``BluetoothError/connectionFailed(underlying:)`` if CoreBluetooth rejects it, or
    ///   ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not powered on.
    public func connect(_ peripheralID: UUID, timeout: Duration? = nil) async throws -> Connection {
        fatalError("Phase 2: dedupe via the registry, arm the timeout, await didConnect")
    }

    /// Connects to a peripheral found while scanning.
    ///
    /// Convenience for ``connect(_:timeout:)`` taking the discovery's identifier.
    ///
    /// - Parameters:
    ///   - discovery: A peripheral reported by ``scan(_:)``.
    ///   - timeout: Overrides ``Central/Configuration/connectTimeout`` for this call.
    /// - Returns: A live connection.
    /// - Throws: ``BluetoothError/connectTimeout`` if the attempt runs out of time,
    ///   ``BluetoothError/connectionFailed(underlying:)`` if CoreBluetooth rejects it, or
    ///   ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not powered on.
    public func connect(_ discovery: Discovery, timeout: Duration? = nil) async throws -> Connection {
        try await connect(discovery.peripheralID, timeout: timeout)
    }

    /// Waits for a peripheral to come into range, however long that takes.
    ///
    /// Arms a pending CoreBluetooth connect and suspends until the peripheral appears — which
    /// may be minutes or hours. This is the canonical way to reconnect to a known device at
    /// app launch: no scanning, no polling, and the radio scheduling is the OS's problem.
    ///
    /// Cancel the calling task to stop waiting. There is no timeout by design; if you want a
    /// deadline, use ``connect(_:timeout:)``.
    ///
    /// - Parameter peripheralID: The peripheral's identifier, typically persisted from an
    ///   earlier session.
    /// - Returns: A live connection, once the peripheral is reachable.
    /// - Throws: ``BluetoothError/connectionFailed(underlying:)`` if CoreBluetooth rejects the
    ///   request, or ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not
    ///   powered on.
    public func connectWhenAvailable(_ peripheralID: UUID) async throws -> Connection {
        fatalError("Phase 2: arm a pending connect with no deadline, await didConnect")
    }
}
