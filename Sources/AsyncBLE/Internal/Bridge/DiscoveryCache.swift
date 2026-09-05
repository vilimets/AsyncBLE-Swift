// Lazy service/characteristic discovery, cached per connection.
//
// The hardest part of the bridge: concurrent callers asking for the same characteristic
// must coalesce onto one in-flight discovery, not start N of them.
//
// And the cache is not stable for the life of the connection — CoreBluetooth invalidates every
// CBService/CBCharacteristic on disconnect, so a reconnect flushes it, re-walks discovery, and
// restores whatever notification subscriptions were live.
//
// Shape: one full walk — all services, then all characteristics of each — rather than a
// targeted search. The public API addresses characteristics by UUID alone, so there is no
// service to target; a "targeted" search would still have to walk every service to find out
// which one holds the UUID. Walking once and caching the lot is the same work, done once, and
// it makes coalescing trivial: every waiter is waiting for the same thing.
//
// Queue-confined, synchronous throughout. The awaiting happens in the `Connection` actor.

@preconcurrency import CoreBluetooth
import Foundation

/// Resolves characteristic UUIDs to live CoreBluetooth objects, once per link.
final class DiscoveryCache: @unchecked Sendable {
    private enum Walk: Equatable {
        /// Nothing discovered, nothing in flight. Where every link starts and returns to.
        case notStarted
        case discoveringServices
        /// Characteristic discovery is out for this many services.
        case discoveringCharacteristics(remaining: Int)
        case complete
    }

    /// How a waiting caller is handed its answer. A closure rather than a `CheckedContinuation`
    /// so the walk can be tested without an actor around it.
    typealias Deliver = (Result<CharacteristicSeam, Error>) -> Void

    private let peripheral: PeripheralSeam
    private let log: Log
    private var resolved: [CBUUID: CharacteristicSeam] = [:]
    private var waiters: [(uuid: CBUUID, deliver: Deliver)] = []
    private var walk: Walk = .notStarted

    init(peripheral: PeripheralSeam, log: LogFacility = .disabled) {
        self.peripheral = peripheral
        self.log = log.scoped(.gatt)
    }

    /// Whether a full walk has completed on the current link.
    var isComplete: Bool { walk == .complete }

    /// How many callers are waiting on discovery. Should be one walk's worth, however many.
    var waiterCount: Int { waiters.count }

    /// Asks for a characteristic, starting a discovery walk if one has not run on this link.
    ///
    /// Every caller that arrives while a walk is in flight joins it. That is the coalescing the
    /// plan calls the risky part: N callers, one walk, N resumptions.
    func resolve(_ uuid: CBUUID, _ deliver: @escaping Deliver) {
        if walk == .complete {
            answer(uuid, with: deliver)
            return
        }
        waiters.append((uuid, deliver))
        guard walk == .notStarted else { return }
        log.info("walking discovery for \(uuid)")
        walk = .discoveringServices
        peripheral.discoverServices(nil)
    }

    /// The cached answer, if the walk has already run. Never starts one.
    func cached(_ uuid: CBUUID) -> CharacteristicSeam? {
        resolved[uuid]
    }

    // MARK: Discovery callbacks

    /// Service discovery came back.
    ///
    /// A failure here is reported as ``BluetoothError/operationFailed(underlying:)``: discovery
    /// is a GATT operation on a link that is still up, not a connect attempt that failed.
    func handleServicesDiscovered(error: NSError?) {
        guard walk == .discoveringServices else { return }

        if let error {
            log.error("service discovery failed: \(error)")
            fail(with: BluetoothError.operationFailed(underlying: error))
            walk = .notStarted
            return
        }

        let services = peripheral.services
        guard !services.isEmpty else {
            // A peripheral with no services is not an error; it just has nothing this caller
            // asked for, which `characteristicNotFound` says exactly.
            finishWalk()
            return
        }

        log.debug("discovered \(services.count) service(s)")
        walk = .discoveringCharacteristics(remaining: services.count)
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// One service's characteristics came back.
    func handleCharacteristicsDiscovered(for service: ServiceSeam, error: NSError?) {
        guard case .discoveringCharacteristics(let remaining) = walk else { return }

        if error == nil {
            // First service wins. A UUID appearing in two services is legal and rare, and
            // the public API has no way to say which one was meant — so the library takes
            // the first it walked rather than inventing a rule the caller cannot see.
            for characteristic in service.characteristics where resolved[characteristic.uuid] == nil {
                resolved[characteristic.uuid] = characteristic
            }
        }
        // A service that failed to enumerate is skipped rather than failing the walk: the
        // characteristic the caller wants is probably in one of the others.

        let left = remaining - 1
        if left <= 0 {
            finishWalk()
        } else {
            walk = .discoveringCharacteristics(remaining: left)
        }
    }

    // MARK: Lifecycle

    /// Fails everyone still waiting on discovery.
    ///
    /// Part of failing a connection's in-flight I/O: a caller suspended here is as much
    /// mid-operation as one waiting on a read callback.
    func failWaiters(with error: Error) {
        fail(with: error)
    }

    /// Drops everything, because CoreBluetooth has invalidated it.
    ///
    /// Called on every transition into and out of a live link. Any waiter still here is a
    /// straggler — the connection fails its in-flight operations first — so one is failed
    /// rather than left suspended forever.
    func invalidate() {
        if walk != .notStarted {
            log.notice("discovery cache flushed")
        }
        resolved.removeAll()
        walk = .notStarted
        if !waiters.isEmpty {
            fail(with: BluetoothError.disconnected(reason: .linkLost))
        }
    }

    private func finishWalk() {
        walk = .complete
        log.info("discovery complete: \(resolved.count) characteristic(s) cached")
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            answer(waiter.uuid, with: waiter.deliver)
        }
    }

    private func answer(_ uuid: CBUUID, with deliver: Deliver) {
        if let characteristic = resolved[uuid] {
            deliver(.success(characteristic))
        } else {
            log.info("characteristic \(uuid) not found on the peripheral")
            deliver(.failure(BluetoothError.characteristicNotFound(uuid)))
        }
    }

    private func fail(with error: Error) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.deliver(.failure(error))
        }
    }
}
