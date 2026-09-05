// CBCentralManagerDelegate → state machine events / async continuations.
//
// Translates only; never sets state directly. Talks to the manager
// through the seam, not to CBCentralManager directly.
//
// Also owns the adapter-state broadcast behind `Central.adapterStates`.
//
// Queue-confined: every method here runs on the library queue, either because CoreBluetooth
// delivered the callback there or because the caller is an actor on that queue's executor.

import Foundation

/// A connection, as far as the central-side bridge is concerned.
///
/// The connection's engine implements this. Keeping it a protocol means the bridge
/// can be tested on its own — routing is a thing that can be got wrong, and it is much easier
/// to see wrong here than three layers up.
protocol ConnectionSink: AnyObject, Sendable {
    /// The peripheral this connection is for. The routing key.
    var peripheralID: UUID { get }

    /// The link came up.
    func handleConnected()

    /// The connect attempt failed outright.
    func handleFailedToConnect(_ error: NSError?)

    /// The link ended — for whatever reason; the connection knows whether it asked for it.
    func handleDisconnected(_ error: NSError?)

    /// The adapter's availability changed. Every connection hears about it, because a pending
    /// connect is void while the radio is off and worth re-arming when it returns.
    func handleAdapterChange(_ state: AdapterState)
}

/// Turns the central manager's callbacks into the library's own vocabulary, and owns everything
/// that is central-wide rather than per-connection: the adapter broadcast and the scan.
final class CentralDelegateBridge: CentralSeamDelegate, @unchecked Sendable {
    /// The manager, for whoever needs to arm a connect. Reachable, not hidden: the connections
    /// this bridge routes to are the ones that ask it to connect and cancel.
    let seam: CentralSeam

    /// The adapter state, broadcast to every ``Central/adapterStates`` subscriber.
    let adapterStates: Broadcaster<AdapterState>

    private let library: LibraryQueue
    private let log: Log
    private let bridgeLog: Log
    private var scans: [UUID: ScanSession] = [:]
    private var activePlan: ScanPlan?
    private var sinks: [UUID: ConnectionSink] = [:]

    init(seam: CentralSeam, library: LibraryQueue, log: LogFacility = .disabled) {
        self.seam = seam
        self.library = library
        self.log = log.scoped(.central)
        bridgeLog = log.scoped(.bridge)
        adapterStates = Broadcaster(seam.adapterState)
        seam.seamDelegate = self
    }

    // MARK: Scanning

    /// Starts a scan for one caller and returns their stream.
    ///
    /// The radio is scanning for the union of every live session's filter; this caller sees
    /// only what it asked for. Ending iteration ends this session, and the last session ending
    /// stops the radio — a scan that outlives its consumer is a battery bug.
    func startScan(_ options: ScanOptions) -> AsyncStream<Discovery> {
        library.assertIsolated()
        log.notice(
            "scan requested (filter: \(options.services.count) service(s), "
                + "duplicates: \(options.allowDuplicates))"
        )
        return AsyncStream { continuation in
            let session = ScanSession(options: options, continuation: continuation)
            scans[session.id] = session
            applyScanPlan()
            // `id`, not `session`: capturing the session would keep it — and its `reported`
            // set, which grows with every peripheral seen — alive from the stream's storage.
            let id = session.id
            continuation.onTermination = scanTerminator(for: id)
        }
    }

    /// The termination handler for one scan session.
    ///
    /// Built at method scope rather than inline in the `AsyncStream` builder: a `[weak self]`
    /// capture written inside another closure captures *that* closure's `self`, which Swift 6
    /// rejects as a reference to a captured var from concurrently-executing code. Here there is
    /// nothing to capture but the reference itself.
    private func scanTerminator(
        for id: UUID
    ) -> @Sendable (AsyncStream<Discovery>.Continuation.Termination) -> Void {
        // The weak reference is promoted before the queue hop rather than inside it. A weak
        // capture is a `var` — it can become nil — and Swift 6 rejects reading one from
        // concurrently-executing code. Promoting first also means that once termination has
        // decided the bridge is alive, the cleanup is guaranteed to run rather than quietly
        // becoming a no-op mid-hop.
        { [weak bridge = self, library] _ in
            guard let bridge else { return }
            library.dispatchQueue.async { bridge.endScan(id) }
        }
    }

    /// How many scans are running. For tests, and for reasoning about the radio.
    var activeScanCount: Int { scans.count }

    private func endScan(_ id: UUID) {
        scans.removeValue(forKey: id)?.finish()
        applyScanPlan()
    }

    private func finishAllScans() {
        let sessions = scans.values
        scans.removeAll()
        for session in sessions {
            session.finish()
        }
        applyScanPlan()
    }

    private func applyScanPlan() {
        guard !scans.isEmpty else {
            if activePlan != nil {
                activePlan = nil
                log.notice("radio scan stopped: no sessions left")
                seam.stopScan()
            }
            return
        }
        let plan = ScanPlan(sessions: scans.values)
        // Re-issuing an identical scan would restart CoreBluetooth's duplicate filtering, so a
        // second session with the same filter must not disturb the first.
        guard plan != activePlan else { return }
        activePlan = plan
        log.notice(
            "radio scan started (union of \(scans.count) session(s): "
                + "\(plan.services?.count ?? 0) service(s), duplicates: \(plan.allowDuplicates))"
        )
        seam.scanForPeripherals(services: plan.services, allowDuplicates: plan.allowDuplicates)
    }

    // MARK: Connection routing

    /// Starts routing this peripheral's callbacks to a connection.
    ///
    /// Registration is explicit in both directions rather than weak: a link
    /// lives until something closes it, so its lifetime is a decision the central makes, never
    /// something ARC works out on its own.
    func register(_ sink: ConnectionSink) {
        library.assertIsolated()
        sinks[sink.peripheralID] = sink
    }

    /// Stops routing a peripheral's callbacks. Called when a connection reaches `disconnected`.
    func unregister(peripheralID: UUID) {
        library.assertIsolated()
        sinks.removeValue(forKey: peripheralID)
    }

    /// Whether a connection is currently registered for a peripheral.
    func isRegistered(peripheralID: UUID) -> Bool {
        sinks[peripheralID] != nil
    }

    // MARK: CentralSeamDelegate

    func centralSeamDidUpdateAdapterState(_ seam: CentralSeam) {
        let state = seam.adapterState
        log.notice("adapter → \(state)")
        adapterStates.send(state)

        if case .unavailable = state {
            // A scan cannot survive the radio going away, and CoreBluetooth has already stopped
            // it. Finishing the streams says so, rather than leaving them silently empty.
            finishAllScans()
        }

        for sink in sinks.values {
            sink.handleAdapterChange(state)
        }
    }

    func centralSeam(
        _ seam: CentralSeam,
        didDiscover peripheral: PeripheralSeam,
        advertisement: AdvertisementData,
        rssi: Int?
    ) {
        let discovery = Discovery(
            peripheralID: peripheral.identifier,
            // The advertised name first: `CBPeripheral.name` may be a GAP name cached from an
            // earlier connection, which is not what this packet said.
            name: advertisement.localName ?? peripheral.name,
            rssi: rssi,
            advertisementData: advertisement
        )
        bridgeLog.debug(
            "didDiscover \(peripheral.identifier) rssi=\(rssi.map(String.init) ?? "nil")",
            ["peripheral": peripheral.identifier.uuidString]
        )
        for session in scans.values {
            session.offer(discovery)
        }
    }

    func centralSeam(_ seam: CentralSeam, didConnect peripheral: PeripheralSeam) {
        let metadata = ["peripheral": peripheral.identifier.uuidString]
        bridgeLog.debug("didConnect \(peripheral.identifier)", metadata)
        guard let sink = sinks[peripheral.identifier] else {
            // Nobody is waiting for this link. It is the detach race: the last
            // caller cancelled, the attempt was withdrawn, and it landed anyway. Close it —
            // nothing else ever would.
            log.notice("connect landed with no waiter, closing", metadata)
            seam.cancelConnection(peripheral)
            return
        }
        sink.handleConnected()
    }

    func centralSeam(_ seam: CentralSeam, didFailToConnect peripheral: PeripheralSeam, error: NSError?) {
        bridgeLog.debug(
            "didFailToConnect \(peripheral.identifier): \(error.map(String.init(describing:)) ?? "no error")",
            ["peripheral": peripheral.identifier.uuidString]
        )
        sinks[peripheral.identifier]?.handleFailedToConnect(error)
    }

    func centralSeam(_ seam: CentralSeam, didDisconnect peripheral: PeripheralSeam, error: NSError?) {
        bridgeLog.debug(
            "didDisconnect \(peripheral.identifier): \(error.map(String.init(describing:)) ?? "no error")",
            ["peripheral": peripheral.identifier.uuidString]
        )
        sinks[peripheral.identifier]?.handleDisconnected(error)
    }
}
