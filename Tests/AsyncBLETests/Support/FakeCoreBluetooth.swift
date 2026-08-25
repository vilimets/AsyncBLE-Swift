// Hand-written fakes behind the CoreBluetooth seam (PLAN.md §7 Q7).
//
// These are what make the risky 70% of the library testable: the bridge, the discovery cache,
// the I/O queue and the reconnect path all talk to `CentralSeam` / `PeripheralSeam`, and these
// stand in for the radio. Nothing here mocks an Apple class — the seam is our own protocol, and
// the alternative (CoreBluetoothMock) would put CBM* typealiases through the production source.
//
// Two things every fake does deliberately:
//   - It records calls, so a test can assert the library asked the radio for exactly what it
//     should have — one connect, not two.
//   - It holds its delegate weakly, exactly as CoreBluetooth does. A test that forgets to keep
//     the bridge alive fails the same way production would, rather than passing by luck.

@preconcurrency import CoreBluetooth
import Foundation

@testable import AsyncBLE

/// `CentralSeam` with no radio behind it.
final class FakeCentral: CentralSeam, @unchecked Sendable {
    /// Everything the library asked the manager to do, in order.
    enum Call: Equatable {
        case scan(services: [CBUUID]?, allowDuplicates: Bool)
        case stopScan
        case connect(UUID)
        case cancelConnection(UUID)
    }

    weak var seamDelegate: CentralSeamDelegate?

    /// The adapter state the library will read. Change it through ``emit(adapterState:)`` so
    /// the callback fires too.
    private(set) var adapterState: AdapterState

    /// Peripherals the "system" already knows about, for `peripheral(withID:)` to find — the
    /// path `connectWhenAvailable(_:)` takes when there has been no scan this session.
    var knownPeripherals: [UUID: FakePeripheral] = [:]

    private(set) var calls: [Call] = []

    /// No CoreBluetooth objects behind a fake, so the escape hatch is unavailable — which is
    /// the one thing about it that cannot be tested without a radio.
    let rawCentral: CBCentralManager? = nil

    init(adapterState: AdapterState = .poweredOn) {
        self.adapterState = adapterState
    }

    // MARK: CentralSeam

    func scanForPeripherals(services: [CBUUID]?, allowDuplicates: Bool) {
        calls.append(.scan(services: services, allowDuplicates: allowDuplicates))
    }

    func stopScan() {
        calls.append(.stopScan)
    }

    func peripheral(withID id: UUID) -> PeripheralSeam? {
        knownPeripherals[id]
    }

    func connect(_ peripheral: PeripheralSeam) {
        calls.append(.connect(peripheral.identifier))
    }

    func cancelConnection(_ peripheral: PeripheralSeam) {
        calls.append(.cancelConnection(peripheral.identifier))
    }

    // MARK: Synthetic callbacks

    /// Changes the adapter state and reports it, as `centralManagerDidUpdateState` would.
    func emit(adapterState state: AdapterState) {
        adapterState = state
        seamDelegate?.centralSeamDidUpdateAdapterState(self)
    }

    /// Reports an advertising packet.
    func emitDiscovery(
        of peripheral: FakePeripheral,
        advertisement: AdvertisementData = AdvertisementData(),
        rssi: Int? = -55
    ) {
        seamDelegate?.centralSeam(self, didDiscover: peripheral, advertisement: advertisement, rssi: rssi)
    }

    /// Reports a link coming up.
    func emitConnect(_ peripheral: FakePeripheral) {
        seamDelegate?.centralSeam(self, didConnect: peripheral)
    }

    /// Reports a connect attempt failing outright.
    func emitFailToConnect(_ peripheral: FakePeripheral, error: NSError? = cbFailure) {
        seamDelegate?.centralSeam(self, didFailToConnect: peripheral, error: error)
    }

    /// Reports a link ending — the callback CoreBluetooth uses for both a drop and a
    /// disconnect the library asked for, which is the ambiguity the library exists to resolve.
    func emitDisconnect(_ peripheral: FakePeripheral, error: NSError? = nil) {
        peripheral.linkDidDrop()
        seamDelegate?.centralSeam(self, didDisconnect: peripheral, error: error)
    }

    // MARK: Assertions

    /// How many times the library armed a connect. The reconnect story is largely this number.
    func connectCount(for id: UUID) -> Int {
        calls.filter { $0 == .connect(id) }.count
    }

    /// Forgets the call log, so a test can assert on what happened after some point.
    func clearCalls() {
        calls.removeAll()
    }
}
