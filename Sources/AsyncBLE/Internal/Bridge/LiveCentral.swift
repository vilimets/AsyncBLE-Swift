// The real `CBCentralManager`, behind `CentralSeam`.
//
// A wrapper rather than a conformance on CBCentralManager itself: the seam needs its own
// delegate storage, and an extension cannot add one. Keeping it a wrapper also means every CB
// callback is translated in exactly one place, which is the layering the whole design rests on.
//
// Thread confinement: every member here is touched only on the library queue — the queue this
// object hands to CoreBluetooth, so callbacks arrive on it too. That is what `@unchecked
// Sendable` is standing for. See `LibraryQueue`.

@preconcurrency import CoreBluetooth
import Foundation

/// `CentralSeam` over a real `CBCentralManager`.
final class LiveCentral: NSObject, CentralSeam, @unchecked Sendable {
    private let manager: CBCentralManager

    /// One `LivePeripheral` per `CBPeripheral`, so wrapper identity tracks CoreBluetooth's.
    ///
    /// Without this, two lookups of the same peripheral would produce two wrappers, and every
    /// `===` the library relies on — is this the peripheral that just connected? — would fail.
    private var wrappers: [ObjectIdentifier: LivePeripheral] = [:]

    /// The same wrappers, by peripheral identifier — the key `connect(_:)` arrives with.
    private var wrappersByID: [UUID: LivePeripheral] = [:]

    weak var seamDelegate: CentralSeamDelegate?

    var adapterState: AdapterState { AdapterState(manager.state) }

    var rawCentral: CBCentralManager? { manager }

    /// Creates a manager, which is what triggers the system permission prompt.
    ///
    /// - Parameters:
    ///   - queue: The library queue. CoreBluetooth delivers every callback on it, and it backs
    ///     the actors' serial executor, so callbacks and actor work are the same context.
    ///   - showPowerAlert: Whether the system may show its "Turn On Bluetooth" alert.
    init(queue: DispatchQueue, showPowerAlert: Bool) {
        manager = CBCentralManager(
            delegate: nil,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: showPowerAlert]
        )
        super.init()
        manager.delegate = self
    }

    func scanForPeripherals(services: [CBUUID]?, allowDuplicates: Bool) {
        manager.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    func stopScan() {
        manager.stopScan()
    }

    func peripheral(withID id: UUID) -> PeripheralSeam? {
        // A peripheral seen in this session's scan is already wrapped. Asking CoreBluetooth for
        // it again would work, but this also keeps wrapper identity stable for free.
        if let known = wrappersByID[id] { return known }
        return manager.retrievePeripherals(withIdentifiers: [id]).first.map(wrapper(for:))
    }

    func connect(_ peripheral: PeripheralSeam) {
        guard let live = peripheral as? LivePeripheral else { return }
        manager.connect(live.peripheral, options: nil)
    }

    func cancelConnection(_ peripheral: PeripheralSeam) {
        guard let live = peripheral as? LivePeripheral else { return }
        manager.cancelPeripheralConnection(live.peripheral)
    }

    private func wrapper(for peripheral: CBPeripheral) -> LivePeripheral {
        let key = ObjectIdentifier(peripheral)
        if let existing = wrappers[key] { return existing }
        let wrapper = LivePeripheral(peripheral)
        wrappers[key] = wrapper
        wrappersByID[peripheral.identifier] = wrapper
        return wrapper
    }
}

// MARK: - CBCentralManagerDelegate

extension LiveCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        seamDelegate?.centralSeamDidUpdateAdapterState(self)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        seamDelegate?.centralSeam(
            self,
            didDiscover: wrapper(for: peripheral),
            advertisement: AdvertisementData(rawAdvertisementData: advertisementData),
            rssi: Int(rssiReading: RSSI)
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        seamDelegate?.centralSeam(self, didConnect: wrapper(for: peripheral))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        seamDelegate?.centralSeam(self, didFailToConnect: wrapper(for: peripheral), error: error as NSError?)
    }

    // Only the classic callback is implemented. iOS 17 added a variant carrying a timestamp and
    // an `isReconnecting` flag, and calls this one whenever that variant is absent — which is
    // what keeps the iOS 16 floor honest. The extra information is for AutoReconnect, which
    // belongs to the background milestone on the Planned list.
    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        seamDelegate?.centralSeam(self, didDisconnect: wrapper(for: peripheral), error: error as NSError?)
    }
}

// MARK: - CoreBluetooth's quirks, mapped once

extension AdapterState {
    /// Maps `CBManagerState`, which has no `Sendable` guarantees and one case the library
    /// treats as success.
    init(_ managerState: CBManagerState) {
        switch managerState {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .unavailable(.poweredOff)
        case .unauthorized: self = .unavailable(.unauthorized)
        case .unsupported: self = .unavailable(.unsupported)
        case .resetting: self = .unavailable(.resetting)
        case .unknown: self = .unavailable(.unknown)
        @unknown default: self = .unavailable(.unknown)
        }
    }
}

extension Int {
    /// Reads CoreBluetooth's RSSI number, rejecting its "no reading" sentinel.
    ///
    /// CoreBluetooth reports `127` when it has no signal-strength reading. Passed through, that
    /// would surface as an absurdly strong signal — +127 dBm — so it becomes `nil` instead
    /// (PLAN.md §5, `Discovery.rssi`).
    init?(rssiReading reading: NSNumber) {
        let value = reading.intValue
        guard value != 127 else { return nil }
        self = value
    }
}
