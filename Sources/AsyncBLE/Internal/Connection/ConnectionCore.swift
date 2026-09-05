// One connection's engine: the state machine, the effects it asks for, and everything the
// callbacks land in.
//
// Why a class and not the actor itself. CoreBluetooth delivers callbacks synchronously on the
// library queue, and at the iOS 16 floor there is no way to tell the compiler that a synchronous
// call arriving on an actor's executor is actor-isolated (`assumeIsolated` is iOS 17). So the
// mutable state lives here, in a queue-confined class that both the callbacks and the actor can
// touch directly, and `Connection` — an actor on that same queue's executor — provides the async
// API on top. The custom serial executor is what makes the two mutually exclusive, so this is
// confinement rather than hope. See `LibraryQueue`.
//
// Everything here is synchronous. Anything that has to await lives in `Connection`.

@preconcurrency import CoreBluetooth
import Foundation

/// The engine behind one ``Connection``.
final class ConnectionCore: ConnectionSink, @unchecked Sendable {
    let peripheralID: UUID
    let library: LibraryQueue
    let peripheral: PeripheralSeam

    /// The state stream behind ``Connection/states``.
    let states: Broadcaster<ConnectionState>

    /// The FIFO every read and write passes through.
    let ioQueue = IOQueue()

    /// Lazy discovery for this link. Flushed and rebuilt on every reconnect.
    let cache: DiscoveryCache

    /// The live notification streams, which outlive the link they were made on.
    let subscriptions: SubscriptionRegistry

    /// Called once, when the connection reaches terminal `disconnected`, so the central can let
    /// it go. That is an explicit decision rather than something ARC works out.
    var onTerminated: (() -> Void)?

    /// The actor on top, for the two jobs that need to await: restoring subscriptions after a
    /// reconnect, and nothing else. Weak because the actor owns this, not the other way round.
    weak var connection: Connection?

    /// The central-side bridge: the radio, and the registry this connection unregisters from
    /// when it ends.
    let bridge: CentralDelegateBridge

    private let scheduler: Scheduler
    private var machine: ConnectionStateMachine

    /// Logging, shared with the owning ``Central``. Init-only, so it never changes under us.
    let log: LogFacility

    // Stored rather than computed: `ioLog` is touched one to three times per read or write,
    // and each `scoped(_:)` builds a fresh `Log`. `DiscoveryCache` and `SubscriptionRegistry`
    // already store theirs.

    /// Logging bound to the `connection` category — state-machine transitions and effects.
    let connLog: Log

    /// Logging bound to the `io` category — reads, writes, notification subscriptions.
    let ioLog: Log

    /// Logging bound to the `reconnect` category — arming, deadlines, subscription restore.
    let reconnectLog: Log

    /// Logging bound to the `gatt` category — the service/characteristic walk.
    let gattLog: Log

    /// The peripheral identifier, as log metadata.
    var peripheralMetadata: [String: String] { ["peripheral": peripheralID.uuidString] }

    private var connectTimer: ScheduledWork?
    private var giveUpTimer: ScheduledWork?
    private var reArmTimer: ScheduledWork?

    /// The last failure CoreBluetooth reported, so a waiter can be resumed with it. The state
    /// machine deliberately does not carry it — `DisconnectReason` has nowhere to put an error.
    private var lastConnectError: NSError?

    /// The single in-flight read, write or subscribe. Single because the FIFO guarantees it:
    /// ATT allows one outstanding request per connection anyway.
    var pendingRead: PendingOperation<Data>?
    var pendingWrite: PendingOperation<Void>?
    var pendingNotify: PendingOperation<Void>?

    /// Writers parked on `canSendWriteWithoutResponse`.
    var writeReadyWaiters: [(Result<Void, Error>) -> Void] = []

    private var connectWaiters: [(id: UUID, resume: (Result<Void, Error>) -> Void)] = []

    /// An operation waiting on a CoreBluetooth callback for one characteristic.
    struct PendingOperation<Value> {
        let uuid: CBUUID
        let deliver: (Result<Value, Error>) -> Void
    }

    init(
        peripheral: PeripheralSeam,
        bridge: CentralDelegateBridge,
        library: LibraryQueue,
        scheduler: Scheduler,
        policy: ReconnectPolicy,
        log: LogFacility = .disabled
    ) {
        peripheralID = peripheral.identifier
        self.peripheral = peripheral
        self.bridge = bridge
        self.library = library
        self.scheduler = scheduler
        self.log = log
        connLog = log.scoped(.connection)
        ioLog = log.scoped(.io)
        reconnectLog = log.scoped(.reconnect)
        gattLog = log.scoped(.gatt)
        machine = ConnectionStateMachine(policy: policy)
        cache = DiscoveryCache(peripheral: peripheral, log: log)
        subscriptions = SubscriptionRegistry(library: library, log: log)
        states = Broadcaster(machine.state)

        peripheral.seamDelegate = self
        subscriptions.onLastSubscriberRemoved = { [weak self] uuid in
            self?.stopNotifying(uuid)
        }
    }

    /// The current state, straight from the machine — there is no second copy to drift.
    var state: ConnectionState { machine.state }

    // MARK: Requests

    /// Asks for a link. `timeout` of `nil` is a pending connect with no deadline.
    func requestConnect(timeout: Duration?) {
        library.assertIsolated()
        handle(.connectRequested(timeout: timeout))
    }

    /// Ends the link and stops waiting for it, whatever the policy says.
    func requestDisconnect() {
        library.assertIsolated()
        handle(.disconnectRequested)
    }

    // MARK: Waiting for a link

    /// Registers a caller waiting for the link to come up.
    ///
    /// - Returns: A token for detaching that caller again if its task is cancelled.
    @discardableResult
    func addConnectWaiter(_ resume: @escaping (Result<Void, Error>) -> Void) -> UUID {
        let id = UUID()
        if case .connected = machine.state {
            resume(.success(()))
            return id
        }
        connectWaiters.append((id, resume))
        return id
    }

    /// Detaches one waiting caller, and withdraws the attempt if it was the last.
    ///
    /// Cancelling one caller detaches that caller only. The attempt continues
    /// while anyone is still waiting, and is cancelled when the last one goes — which refcounts
    /// the *attempt*, not the link, because an in-flight attempt has no device-wide effect.
    func removeConnectWaiter(_ id: UUID) {
        library.assertIsolated()
        connectWaiters.removeAll { $0.id == id }
        guard connectWaiters.isEmpty, machine.state == .connecting else { return }
        handle(.disconnectRequested)
    }

    /// Whether anyone is still waiting for this connection to come up.
    var hasConnectWaiters: Bool { !connectWaiters.isEmpty }

    // MARK: ConnectionSink

    func handleConnected() {
        handle(.didConnect)
    }

    func handleFailedToConnect(_ error: NSError?) {
        lastConnectError = error
        handle(.didFailToConnect(error))
    }

    func handleDisconnected(_ error: NSError?) {
        // Always `userInitiated: false`. A disconnect this library asked for has already moved
        // the machine to `disconnected`, where this late callback lands and is ignored — so the
        // flag is carried by the machine's own state rather than by a variable
        // that could get out of step with it.
        handle(.didDisconnect(error, userInitiated: false))
    }

    func handleAdapterChange(_ state: AdapterState) {
        handle(.adapterChanged(state))
    }

    // MARK: The loop

    private func handle(_ event: ConnectionEvent) {
        let before = machine.state
        let effects = machine.handle(event)

        for effect in effects {
            apply(effect)
        }

        guard machine.state != before else {
            connLog.debug("\(before) ignored \(event)")
            return
        }
        logTransition(from: before, on: event, to: machine.state)
        publish(machine.state)
    }

    /// Logs a state transition — `notice` when the machine enters `reconnecting` or a terminal
    /// `disconnected`, `info` for the routine connecting/connected steps.
    private func logTransition(from before: ConnectionState, on event: ConnectionEvent, to after: ConnectionState) {
        // Interpolation stays inside the autoclosure: none of these types are
        // `CustomStringConvertible`, so each `\(...)` costs reflection — paid on every
        // transition, even with logging off, if it were hoisted into a `let`.
        switch after {
        case .reconnecting, .disconnected(.some):
            connLog.notice("\(before) --\(event)--> \(after)", peripheralMetadata)
        case .connecting, .connected, .disconnected(nil):
            connLog.info("\(before) --\(event)--> \(after)", peripheralMetadata)
        }
    }

    private func publish(_ state: ConnectionState) {
        states.send(state)

        switch state {
        case .connected:
            resumeConnectWaiters(with: .success(()))
        case .disconnected(let reason?):
            // Terminal. Everyone still waiting learns why, the central stops routing to a
            // connection that will never be used again, and the state stream
            // ends because nothing else can ever be sent on it.
            resumeConnectWaiters(with: .failure(waiterError(for: reason)))
            bridge.unregister(peripheralID: peripheralID)
            onTerminated?()
            onTerminated = nil
            states.finish()
        case .connecting, .reconnecting, .disconnected(nil):
            break
        }
    }

    private func resumeConnectWaiters(with result: Result<Void, Error>) {
        let waiting = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiting {
            waiter.resume(result)
        }
    }

    /// What a caller awaiting a link is told when it ends instead.
    private func waiterError(for reason: DisconnectReason) -> BluetoothError {
        switch reason {
        case .connectTimeout: .connectTimeout
        case .connectionFailed: .connectionFailed(underlying: lastConnectError)
        case .bluetoothUnavailable(reason: let unavailable): .bluetoothUnavailable(reason: unavailable)
        case .userInitiated, .linkLost, .reconnectGaveUp: .disconnected(reason: reason)
        }
    }

    // MARK: Effects

    private func apply(_ effect: ConnectionEffect) {
        connLog.debug("effect \(effect)", peripheralMetadata)
        switch effect {
        case .armConnect:
            bridge.seam.connect(peripheral)
        case .cancelConnect:
            bridge.seam.cancelConnection(peripheral)

        case .startConnectTimeout(let duration):
            connectTimer = schedule(duration) { $0.handle(.connectTimedOut) }
        case .cancelConnectTimeout:
            connectTimer?.cancel()
            connectTimer = nil

        case .startGiveUpDeadline(let duration):
            reconnectLog.notice("holding the link open, giving up after \(duration)", peripheralMetadata)
            giveUpTimer = schedule(duration) {
                $0.reconnectLog.notice("give-up deadline reached, abandoning the link", $0.peripheralMetadata)
                $0.handle(.giveUpDeadlineReached)
            }
        case .cancelGiveUpDeadline:
            giveUpTimer?.cancel()
            giveUpTimer = nil

        case .startReArmTimer(let interval):
            reconnectLog.info("re-arm cadence: every \(interval)", peripheralMetadata)
            reArmTimer = schedule(interval) {
                $0.reconnectLog.info("re-arming the pending connect", $0.peripheralMetadata)
                $0.handle(.reArmTimerFired)
            }
        case .cancelReArmTimer:
            reArmTimer?.cancel()
            reArmTimer = nil

        case .invalidateDiscoveryCache:
            cache.invalidate()
        case .markSubscriptionsForRestore:
            subscriptions.markForRestore()
        case .restoreSubscriptions:
            startSubscriptionRestore()

        case .endPendingOperations(let reason):
            failAllOperations(with: BluetoothError.disconnected(reason: reason))
        case .endSubscriptions(let reason):
            subscriptions.endAll(reason: reason)
        }
    }

    private func schedule(_ duration: Duration, _ work: @escaping (ConnectionCore) -> Void) -> ScheduledWork {
        scheduler.schedule(after: duration) { [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    /// Fails everything a caller could currently be suspended on.
    ///
    /// Three places, one call: waiting for a turn in the FIFO, waiting on discovery, and waiting
    /// on a CoreBluetooth callback that is not coming. Missing any one of them strands a caller
    /// forever, which is the failure mode this library exists to not have.
    private func failAllOperations(with error: BluetoothError) {
        let hadWork = pendingRead != nil || pendingWrite != nil || pendingNotify != nil
            || !writeReadyWaiters.isEmpty || !ioQueue.isEmpty || cache.waiterCount > 0
        if hadWork {
            ioLog.info("failing in-flight I/O: \(error)", peripheralMetadata)
        }
        ioQueue.failAll(with: error)
        cache.failWaiters(with: error)

        let read = pendingRead
        let write = pendingWrite
        let notify = pendingNotify
        let parked = writeReadyWaiters
        pendingRead = nil
        pendingWrite = nil
        pendingNotify = nil
        writeReadyWaiters = []

        read?.deliver(.failure(error))
        write?.deliver(.failure(error))
        notify?.deliver(.failure(error))
        for waiter in parked {
            waiter(.failure(error))
        }
    }

    /// Re-establishes every subscription that was live when the link dropped.
    ///
    /// Takes its place in the FIFO synchronously, before handing off to the actor: a read issued
    /// the instant the link came back must not overtake the resubscribe that the caller never
    /// asked for but is entitled to.
    private func startSubscriptionRestore() {
        guard !subscriptions.pendingRestore.isEmpty else { return }
        reconnectLog.notice(
            "restoring \(subscriptions.pendingRestore.count) subscription(s) after the reconnect",
            peripheralMetadata
        )
        let ticket = ioQueue.enqueue()
        Task { [weak connection] in
            await connection?.restoreSubscriptions(holding: ticket)
        }
    }

    /// Turns the peripheral's notify flag off once the last subscriber has gone.
    private func stopNotifying(_ uuid: CBUUID) {
        guard machine.state == .connected, let characteristic = cache.cached(uuid) else { return }
        peripheral.setNotifyValue(false, for: characteristic)
    }
}
