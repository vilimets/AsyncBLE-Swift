// Lazy discovery: one walk per link, however many callers ask; cached afterwards; and gone the
// moment the link drops, because CoreBluetooth invalidated every object in it.
//
// PLAN.md §5 calls this the hardest part of Phase 2. These are the cases that make it so.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

/// Feeds the peripheral's discovery callbacks into a cache, which is the connection engine's
/// job in the finished library. Here it is the smallest thing that makes the cache testable.
private final class CacheDriver: PeripheralSeamDelegate, @unchecked Sendable {
    let cache: DiscoveryCache

    init(cache: DiscoveryCache) {
        self.cache = cache
    }

    func peripheralSeam(_ seam: PeripheralSeam, didDiscoverServices error: NSError?) {
        cache.handleServicesDiscovered(error: error)
    }

    func peripheralSeam(
        _ seam: PeripheralSeam,
        didDiscoverCharacteristicsFor service: ServiceSeam,
        error: NSError?
    ) {
        cache.handleCharacteristicsDiscovered(for: service, error: error)
    }

    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateValueFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {}
    func peripheralSeam(
        _ seam: PeripheralSeam,
        didWriteValueFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {}
    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateNotificationStateFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {}
    func peripheralSeamIsReadyForWriteWithoutResponse(_ seam: PeripheralSeam) {}
}

@Suite("The discovery cache")
struct DiscoveryCacheTests {
    private let heartRate = CBUUID(string: "180D")
    private let measurement = CBUUID(string: "2A37")
    private let battery = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    /// Collects what the cache handed back, so a test can assert on answers and failures alike.
    private final class Answers: @unchecked Sendable {
        private(set) var resolved: [CBUUID] = []
        private(set) var errors: [Error] = []

        func deliver(_ result: Result<CharacteristicSeam, Error>) {
            switch result {
            case .success(let characteristic): resolved.append(characteristic.uuid)
            case .failure(let error): errors.append(error)
            }
        }

        var kinds: [ErrorKind] { errors.map(\.kind) }
    }

    /// A cache, the peripheral it walks, and the driver wiring the two together.
    private struct Rig {
        let cache: DiscoveryCache
        let peripheral: FakePeripheral
        /// Held only so the peripheral's weak delegate stays alive for the test.
        let driver: CacheDriver
        let answers = Answers()
    }

    private func makeRig(gatt: [FakeService]? = nil) -> Rig {
        let peripheral = FakePeripheral(gatt: gatt ?? [
            FakeService(uuid: heartRate, characteristic: measurement),
            FakeService(uuid: battery, characteristic: batteryLevel)
        ])
        let cache = DiscoveryCache(peripheral: peripheral)
        let driver = CacheDriver(cache: cache)
        peripheral.seamDelegate = driver
        return Rig(cache: cache, peripheral: peripheral, driver: driver)
    }

    @Test("the first request walks the peripheral and answers from what it found")
    func firstRequestWalks() {
        let rig = makeRig()

        rig.cache.resolve(measurement, rig.answers.deliver)
        #expect(rig.peripheral.calls == [.discoverServices(nil)])
        #expect(rig.answers.resolved.isEmpty)

        rig.peripheral.flush()

        #expect(rig.answers.resolved == [measurement])
        #expect(rig.cache.isComplete)
    }

    @Test("concurrent callers share one walk")
    func callersCoalesce() {
        // The risk the plan names: N callers must not start N discoveries. One walk, N answers.
        let rig = makeRig()

        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.cache.resolve(batteryLevel, rig.answers.deliver)
        rig.cache.resolve(measurement, rig.answers.deliver)
        #expect(rig.cache.waiterCount == 3)

        rig.peripheral.flush()

        #expect(rig.peripheral.calls.filter { $0 == .discoverServices(nil) }.count == 1)
        #expect(rig.answers.resolved == [measurement, batteryLevel, measurement])
    }

    @Test("a second request after the walk is answered from the cache")
    func cachedAfterTheWalk() {
        let rig = makeRig()
        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.peripheral.flush()
        rig.peripheral.clearCalls()

        rig.cache.resolve(batteryLevel, rig.answers.deliver)

        #expect(rig.peripheral.calls.isEmpty)
        #expect(rig.answers.resolved == [measurement, batteryLevel])
        #expect(rig.cache.cached(batteryLevel) != nil)
    }

    @Test("a UUID the peripheral does not have is characteristicNotFound")
    func missingCharacteristic() {
        let rig = makeRig()
        let absent = CBUUID(string: "2A00")

        rig.cache.resolve(absent, rig.answers.deliver)
        rig.peripheral.flush()

        #expect(rig.answers.kinds == [.characteristicNotFound(absent)])
    }

    @Test("a peripheral with no services answers rather than hanging")
    func emptyPeripheral() {
        let rig = makeRig(gatt: [])

        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.peripheral.flush()

        #expect(rig.answers.kinds == [.characteristicNotFound(measurement)])
        #expect(rig.cache.isComplete)
    }

    @Test("one unreadable service does not fail the whole walk")
    func oneServiceFailing() {
        // The characteristic the caller wants is probably in one of the others.
        let failing = FakeService(uuid: heartRate, characteristic: measurement)
        failing.discoveryError = cbFailure
        let rig = makeRig(gatt: [failing, FakeService(uuid: battery, characteristic: batteryLevel)])

        rig.cache.resolve(batteryLevel, rig.answers.deliver)
        rig.peripheral.flush()

        #expect(rig.cache.isComplete)
        #expect(rig.answers.resolved == [batteryLevel])
        #expect(rig.cache.cached(measurement) == nil)
    }

    @Test("service discovery failing fails the callers and leaves the walk retryable")
    func serviceDiscoveryFailure() {
        let rig = makeRig()
        rig.peripheral.servicesDiscoveryError = cbFailure

        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.peripheral.flush()

        #expect(rig.answers.errors.count == 1)
        #expect(!rig.cache.isComplete)

        // Retryable: the next caller starts a fresh walk rather than waiting on a dead one.
        rig.peripheral.clearCalls()
        rig.cache.resolve(measurement, rig.answers.deliver)
        #expect(rig.peripheral.calls == [.discoverServices(nil)])
    }

    @Test("a drop empties the cache, and the next link walks again")
    func invalidateForcesAFreshWalk() {
        // Apple invalidates every CBService and CBCharacteristic on disconnect, so a cache that
        // survived a reconnect would be handing out dead objects (PLAN.md §7 Q2).
        let rig = makeRig()
        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.peripheral.flush()
        #expect(rig.cache.cached(measurement) != nil)

        rig.cache.invalidate()
        #expect(rig.cache.cached(measurement) == nil)
        #expect(!rig.cache.isComplete)

        rig.peripheral.clearCalls()
        rig.cache.resolve(measurement, rig.answers.deliver)
        #expect(rig.peripheral.calls == [.discoverServices(nil)])
    }

    @Test("a caller waiting on discovery when the link drops is failed, not stranded")
    func waitersAreFailedOnDrop() {
        let rig = makeRig()
        rig.cache.resolve(measurement, rig.answers.deliver)

        rig.cache.failWaiters(with: BluetoothError.disconnected(reason: .linkLost))

        #expect(rig.answers.kinds == [.disconnected(.linkLost)])
        #expect(rig.cache.waiterCount == 0)
    }

    @Test("invalidating with a straggler still waiting fails it")
    func invalidateFailsStragglers() {
        let rig = makeRig()
        rig.cache.resolve(measurement, rig.answers.deliver)

        rig.cache.invalidate()

        #expect(rig.answers.kinds == [.disconnected(.linkLost)])
    }

    @Test("late callbacks from an abandoned walk are ignored")
    func staleCallbacksIgnored() {
        // Discovery was in flight when the link dropped. CoreBluetooth may still call back.
        let rig = makeRig()
        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.cache.invalidate()

        rig.peripheral.flush()

        #expect(!rig.cache.isComplete)
        #expect(rig.answers.resolved.isEmpty)
    }

    @Test("a characteristic that comes back missing after a reconnect is not found")
    func characteristicGoneAfterReconnect() {
        // PLAN.md §7 Q8's premise, at the cache layer: the peripheral came back in a different
        // firmware mode and simply does not have it any more.
        let rig = makeRig()
        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.peripheral.flush()

        rig.cache.invalidate()
        rig.peripheral.gatt = [FakeService(uuid: battery, characteristic: batteryLevel)]

        rig.cache.resolve(measurement, rig.answers.deliver)
        rig.peripheral.flush()

        #expect(rig.answers.resolved == [measurement])
        #expect(rig.answers.kinds == [.characteristicNotFound(measurement)])
    }
}
