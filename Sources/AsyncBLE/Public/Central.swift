// Entry point of the library: adapter lifecycle, scanning, and connecting.
//
// Like `Connection`, this actor runs on the library queue — the queue CoreBluetooth delivers its
// callbacks on — so a connect request is ordered against everything else happening on the radio
// without a hop. See LibraryQueue.

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
/// type. It is spelled ``CharacteristicID`` in characteristic positions and ``ServiceID`` in
/// service positions, so that neither obliges you to import CoreBluetooth.
public actor Central {
    /// The tunables this central was created with.
    nonisolated public let configuration: Configuration

    /// The queue this actor, its connections, and CoreBluetooth's callbacks all share.
    nonisolated let library: LibraryQueue

    /// The manager's callbacks, translated — and the adapter broadcast behind
    /// ``adapterStates``.
    nonisolated let bridge: CentralDelegateBridge

    /// Where every timer in this central and its connections is armed.
    nonisolated let scheduler: Scheduler

    /// The resolved logging configuration, shared with the bridge and every connection.
    nonisolated let logFacility: LogFacility

    /// Logging bound to the `central` category.
    nonisolated var log: Log { logFacility.scoped(.central) }

    /// The links this central is holding open.
    nonisolated let registry = ConnectionRegistry()

    /// The links iOS handed back after relaunching the app, behind ``restoredConnections``.
    ///
    /// Replays rather than holding a current value: a relaunch may restore several links, and
    /// the app is asleep when they arrive. See `ReplayBroadcaster`.
    nonisolated let restored = ReplayBroadcaster<Connection>()

    /// Runs this actor on the library queue rather than the global concurrency pool.
    ///
    /// An implementation detail that has to be public because `Actor` says so. It is what puts
    /// this actor, its connections, and CoreBluetooth's delegate callbacks in one execution
    /// context, so none of them can run at the same time as another.
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        library.unownedExecutor
    }

    /// Creates a central and begins bringing up the Bluetooth adapter.
    ///
    /// The adapter takes a moment to report its state, and on first use the system asks the
    /// user for permission. You do not need to wait: ``scan(_:)`` and ``connect(_:timeout:)-(UUID,_)``
    /// each await a definitive adapter state before acting, and throw
    /// ``BluetoothError/bluetoothUnavailable(reason:)`` if it is not usable.
    ///
    /// - Parameters:
    ///   - configuration: Connect timeout, reconnect policy, and power alert behavior. Defaults
    ///     to a 10-second timeout and indefinite reconnection.
    ///   - logging: What the library logs, at what level, and where. Defaults to OSLog, on, at
    ///     ``LogLevel/notice``.
    public init(configuration: Configuration = Configuration(), logging: LogConfiguration = LogConfiguration()) {
        let library = LibraryQueue()
        let seam = LiveCentral(
            queue: library.dispatchQueue,
            showPowerAlert: configuration.showPowerAlert,
            restoreIdentifier: configuration.restoreIdentifier
        )
        self.init(
            configuration: configuration,
            seam: seam,
            library: library,
            scheduler: QueueScheduler(queue: library.dispatchQueue),
            logFacility: LogFacility(logging)
        )
    }

    /// Creates a central over an arbitrary seam. Internal: this is the library's own test
    /// injection point, not a supported way to substitute a mock from outside.
    init(
        configuration: Configuration,
        seam: CentralSeam,
        library: LibraryQueue,
        scheduler: Scheduler,
        logFacility: LogFacility = .disabled
    ) {
        self.configuration = configuration
        self.library = library
        self.scheduler = scheduler
        self.logFacility = logFacility
        bridge = CentralDelegateBridge(seam: seam, library: library, log: logFacility)
        // Last, and after every stored property: setting this drains whatever restoration
        // already buffered, which calls straight back into `self`.
        //
        // Weak, like the registry's back-reference: an app that has let its central go has
        // nothing to restore into, and holding one alive from CoreBluetooth's side would keep
        // the radio busy for an owner that no longer exists.
        bridge.onRestoredPeripherals = { [weak self] peripherals in
            self?.adopt(restored: peripherals)
        }
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
    nonisolated public var adapterStates: AsyncStream<AdapterState> {
        bridge.adapterStates.stream()
    }

    /// The links iOS handed back after relaunching this app in the background.
    ///
    /// When a central is created with a ``Central/Configuration/restoreIdentifier`` and the app
    /// declares the `bluetooth-central` background mode, iOS may terminate the app and relaunch
    /// it later — when a peripheral this central was connected to reconnects, or when a pending
    /// connect it was holding is fulfilled. The links come back here, as ``Connection`` objects
    /// the app holds no reference to and could not otherwise reach.
    ///
    /// Every restored connection is also in ``activeConnections``. This stream exists because
    /// nothing tells you *when* to look: restoration is delivered before the app has run a line
    /// of its own code, so the stream replays everything restored so far to each new subscriber
    /// and there is no window to miss.
    ///
    /// A restored connection carries its state and — where iOS kept the link up — the
    /// peripheral's notify flags. It does not carry a discovery cache or the notification
    /// streams from the previous process: re-subscribe, and a characteristic still notifying is
    /// re-attached without a round trip to the peripheral.
    ///
    /// Each call returns an independent stream, and the stream never finishes: the app can be
    /// relaunched more than once in a process's life.
    ///
    /// ```swift
    /// for await connection in central.restoredConnections {
    ///     for try await beat in try await connection.notifications(measurement) { … }
    /// }
    /// ```
    ///
    /// See <doc:BackgroundModes>.
    nonisolated public var restoredConnections: AsyncStream<Connection> {
        restored.stream()
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
    /// Several scans can run at once. CoreBluetooth has only one, so the library scans for the
    /// union of every caller's filter and gives each caller only what it asked for.
    ///
    /// - Parameter options: What to scan for, and whether to report repeat advertisements.
    ///   Defaults to an unfiltered scan reporting each peripheral once.
    /// - Returns: A stream of discoveries, one per advertising packet reported.
    /// - Throws: ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not
    ///   powered on.
    public func scan(_ options: ScanOptions = ScanOptions()) async throws -> AsyncStream<Discovery> {
        try await requirePoweredOn()
        return bridge.startScan(options)
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
        services: [ServiceID],
        allowDuplicates: Bool = false
    ) async throws -> AsyncStream<Discovery> {
        try await scan(ScanOptions(services: services, allowDuplicates: allowDuplicates))
    }

    /// Connects to a peripheral by identifier, within a deadline.
    ///
    /// Returns only once the link is up. If it does not come up within the timeout, the pending
    /// CoreBluetooth request is cancelled and ``BluetoothError/connectTimeout`` is thrown —
    /// CoreBluetooth itself would have waited forever. Use ``connectWhenInRange(_:)`` when
    /// waiting forever is what you actually want.
    ///
    /// Concurrent calls for the same peripheral coalesce onto a single attempt and all resume
    /// with the same ``Connection``; a call for an already-connected peripheral returns the
    /// live connection. Cancelling one caller's task detaches that caller only — the attempt
    /// continues while any other caller is still waiting.
    ///
    /// > Note: A caller that starts the attempt sets its deadline, and that deadline is what
    /// > withdraws the CoreBluetooth request. A caller that coalesces onto an attempt already
    /// > running — or onto a reconnect wait — cannot restart it: its own timeout then bounds
    /// > its own wait, and expiring detaches it without ending the attempt for anyone else.
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
        try await establish(peripheralID, timeout: timeout ?? configuration.connectTimeout)
    }

    /// Connects to a peripheral found while scanning.
    ///
    /// Convenience for ``connect(_:timeout:)-(UUID,_)`` taking the discovery's identifier.
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
    /// deadline, use ``connect(_:timeout:)-(UUID,_)``.
    ///
    /// - Parameter peripheralID: The peripheral's identifier, typically persisted from an
    ///   earlier session.
    /// - Returns: A live connection, once the peripheral is reachable.
    /// - Throws: ``BluetoothError/connectionFailed(underlying:)`` if CoreBluetooth rejects the
    ///   request, or ``BluetoothError/bluetoothUnavailable(reason:)`` if the adapter is not
    ///   powered on.
    public func connectWhenInRange(_ peripheralID: UUID) async throws -> Connection {
        try await establish(peripheralID, timeout: nil)
    }

    /// Every connection this central is currently holding.
    ///
    /// A link lives until something explicitly closes it — dropping your last reference does
    /// not. The cost of that rule is that a link nobody closes stays open, and
    /// this is how you find one: an inventory of what the radio is actually doing.
    ///
    /// Includes connections that are `connecting` or `reconnecting`, not only live links,
    /// because those hold a pending CoreBluetooth request and are equally worth auditing. A
    /// connection drops off this list the moment it reaches `disconnected` for good.
    ///
    /// The order is stable across calls but not otherwise meaningful.
    ///
    /// ```swift
    /// for connection in await central.activeConnections {
    ///     print(connection.peripheralID, await connection.state)
    /// }
    /// ```
    public var activeConnections: [Connection] {
        registry.all
    }

    /// Closes every link this central is holding, and stops waiting for any of them.
    ///
    /// The same contract as ``Connection/disconnect()``, applied to all of them: reconnect
    /// policies are not consulted, in-flight and queued I/O fails, and notification streams
    /// finish. Returns once every connection has been asked to close.
    ///
    /// > Important: A link is device-wide, not per-caller. This ends every link this central
    /// > holds, including any that another part of your app opened and is still using.
    ///
    /// Useful at logout, on entering a background state you do not want radio activity in, or
    /// in a test's teardown. Idempotent, and safe to call when there is nothing to close.
    public func disconnectAll() async {
        // Snapshotted first: each disconnect reaches terminal and removes itself from the
        // registry, which would otherwise be mutating out from under the iteration.
        let open = registry.all
        if !open.isEmpty {
            log.notice("disconnecting all \(open.count) connection(s)")
        }
        // Straight to the engine rather than `await connection.disconnect()`: that method only
        // calls this, and `Central` and every `Connection` already share the library queue, so
        // the awaits bought a suspension point each and no ordering.
        for connection in open {
            connection.core.requestDisconnect()
        }
    }
}
