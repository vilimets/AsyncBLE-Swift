// The real `CBPeripheral`, `CBService` and `CBCharacteristic`, behind their seams.
//
// Same confinement contract as `LiveCentral`: library queue only, which is where CoreBluetooth
// delivers every callback and where the actors' executor runs.

@preconcurrency import CoreBluetooth
import Foundation

/// `PeripheralSeam` over a real `CBPeripheral`.
final class LivePeripheral: NSObject, PeripheralSeam, @unchecked Sendable {
    /// The wrapped peripheral. `LiveCentral` needs it to connect and cancel, and the escape
    /// hatch hands it to the caller (PLAN.md §7 Q6).
    let peripheral: CBPeripheral

    weak var seamDelegate: PeripheralSeamDelegate?

    private var serviceWrappers: [ObjectIdentifier: LiveService] = [:]
    private var characteristicWrappers: [ObjectIdentifier: LiveCharacteristic] = [:]

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }
    var services: [ServiceSeam] { (peripheral.services ?? []).map(wrapper(for:)) }
    var rawPeripheral: CBPeripheral? { peripheral }

    /// Wraps a peripheral and takes over its delegate.
    ///
    /// The library owns the delegate for the peripheral's whole life; that is the mechanism
    /// behind the documented limit on the escape hatch, where a callback-based CoreBluetooth
    /// call would deliver its result here and be dropped (PLAN.md §7 Q13).
    init(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    func discoverServices(_ uuids: [CBUUID]?) {
        // A discovery walk starts from nothing: CoreBluetooth replaces its service and
        // characteristic objects, so wrappers cached against the old ones are dead weight and
        // would keep stale identities alive across a reconnect.
        serviceWrappers.removeAll()
        characteristicWrappers.removeAll()
        peripheral.discoverServices(uuids)
    }

    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: ServiceSeam) {
        guard let live = service as? LiveService else { return }
        peripheral.discoverCharacteristics(uuids, for: live.service)
    }

    func readValue(for characteristic: CharacteristicSeam) {
        guard let live = characteristic as? LiveCharacteristic else { return }
        peripheral.readValue(for: live.characteristic)
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicSeam, mode: Connection.WriteMode) {
        guard let live = characteristic as? LiveCharacteristic else { return }
        peripheral.writeValue(data, for: live.characteristic, type: CBCharacteristicWriteType(mode))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicSeam) {
        guard let live = characteristic as? LiveCharacteristic else { return }
        peripheral.setNotifyValue(enabled, for: live.characteristic)
    }

    func maximumWriteValueLength(for mode: Connection.WriteMode) -> Int {
        peripheral.maximumWriteValueLength(for: CBCharacteristicWriteType(mode))
    }

    fileprivate func wrapper(for service: CBService) -> LiveService {
        let key = ObjectIdentifier(service)
        if let existing = serviceWrappers[key] { return existing }
        let wrapper = LiveService(service, peripheral: self)
        serviceWrappers[key] = wrapper
        return wrapper
    }

    fileprivate func wrapper(for characteristic: CBCharacteristic) -> LiveCharacteristic {
        let key = ObjectIdentifier(characteristic)
        if let existing = characteristicWrappers[key] { return existing }
        let wrapper = LiveCharacteristic(characteristic)
        characteristicWrappers[key] = wrapper
        return wrapper
    }
}

// MARK: - CBPeripheralDelegate

extension LivePeripheral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        seamDelegate?.peripheralSeam(self, didDiscoverServices: error as NSError?)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        seamDelegate?.peripheralSeam(
            self,
            didDiscoverCharacteristicsFor: wrapper(for: service),
            error: error as NSError?
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        seamDelegate?.peripheralSeam(
            self,
            didUpdateValueFor: wrapper(for: characteristic),
            error: error as NSError?
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        seamDelegate?.peripheralSeam(self, didWriteValueFor: wrapper(for: characteristic), error: error as NSError?)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        seamDelegate?.peripheralSeam(
            self,
            didUpdateNotificationStateFor: wrapper(for: characteristic),
            error: error as NSError?
        )
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        seamDelegate?.peripheralSeamIsReadyForWriteWithoutResponse(self)
    }
}

// MARK: - Services and characteristics

/// `ServiceSeam` over a real `CBService`.
final class LiveService: ServiceSeam, @unchecked Sendable {
    let service: CBService

    /// The owning peripheral, which holds the characteristic wrappers — so that two routes to
    /// the same characteristic produce the same object.
    private unowned let owner: LivePeripheral

    var uuid: CBUUID { service.uuid }
    var characteristics: [CharacteristicSeam] { (service.characteristics ?? []).map(owner.wrapper(for:)) }

    init(_ service: CBService, peripheral: LivePeripheral) {
        self.service = service
        owner = peripheral
    }
}

/// `CharacteristicSeam` over a real `CBCharacteristic`.
final class LiveCharacteristic: CharacteristicSeam, @unchecked Sendable {
    let characteristic: CBCharacteristic

    var uuid: CBUUID { characteristic.uuid }
    var value: Data? { characteristic.value }
    var properties: CBCharacteristicProperties { characteristic.properties }
    var isNotifying: Bool { characteristic.isNotifying }

    init(_ characteristic: CBCharacteristic) {
        self.characteristic = characteristic
    }
}

extension CBCharacteristicWriteType {
    /// The CoreBluetooth spelling of a ``Connection/WriteMode``.
    init(_ mode: Connection.WriteMode) {
        switch mode {
        case .withResponse: self = .withResponse
        case .withoutResponse: self = .withoutResponse
        }
    }
}
