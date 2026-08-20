// The other half of the fakes: something to receive the seam's callbacks and write them down.
//
// Phase 2c replaces this with the real delegate bridge. Until then it is what proves the fakes
// emit what the seam promises — and afterwards it stays useful for asserting on the raw
// callback stream without going through the state machine.

@preconcurrency import CoreBluetooth
import Foundation

@testable import AsyncBLE

/// Every callback the seam can deliver, as a comparable value.
enum SeamEvent: Equatable {
    case adapterState(AdapterState)
    case discovered(UUID, AdvertisementData, rssi: Int?)
    case connected(UUID)
    case failedToConnect(UUID, NSError?)
    case disconnected(UUID, NSError?)
    case discoveredServices(UUID, NSError?)
    case discoveredCharacteristics(CBUUID, NSError?)
    case updatedValue(CBUUID, Data?, NSError?)
    case wroteValue(CBUUID, NSError?)
    case updatedNotificationState(CBUUID, isNotifying: Bool, NSError?)
    case readyForWriteWithoutResponse(UUID)
}

/// Records everything both seam delegates deliver, in order.
final class SeamRecorder: CentralSeamDelegate, PeripheralSeamDelegate, @unchecked Sendable {
    private(set) var events: [SeamEvent] = []

    /// Forgets the log, so a test can assert on what happened after some point.
    func clear() {
        events.removeAll()
    }

    // MARK: CentralSeamDelegate

    func centralSeamDidUpdateAdapterState(_ seam: CentralSeam) {
        events.append(.adapterState(seam.adapterState))
    }

    func centralSeam(
        _ seam: CentralSeam,
        didDiscover peripheral: PeripheralSeam,
        advertisement: AdvertisementData,
        rssi: Int?
    ) {
        events.append(.discovered(peripheral.identifier, advertisement, rssi: rssi))
    }

    func centralSeam(_ seam: CentralSeam, didConnect peripheral: PeripheralSeam) {
        events.append(.connected(peripheral.identifier))
    }

    func centralSeam(_ seam: CentralSeam, didFailToConnect peripheral: PeripheralSeam, error: NSError?) {
        events.append(.failedToConnect(peripheral.identifier, error))
    }

    func centralSeam(_ seam: CentralSeam, didDisconnect peripheral: PeripheralSeam, error: NSError?) {
        events.append(.disconnected(peripheral.identifier, error))
    }

    // MARK: PeripheralSeamDelegate

    func peripheralSeam(_ seam: PeripheralSeam, didDiscoverServices error: NSError?) {
        events.append(.discoveredServices(seam.identifier, error))
    }

    func peripheralSeam(
        _ seam: PeripheralSeam,
        didDiscoverCharacteristicsFor service: ServiceSeam,
        error: NSError?
    ) {
        events.append(.discoveredCharacteristics(service.uuid, error))
    }

    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateValueFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {
        events.append(.updatedValue(characteristic.uuid, characteristic.value, error))
    }

    func peripheralSeam(_ seam: PeripheralSeam, didWriteValueFor characteristic: CharacteristicSeam, error: NSError?) {
        events.append(.wroteValue(characteristic.uuid, error))
    }

    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateNotificationStateFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {
        events.append(
            .updatedNotificationState(characteristic.uuid, isNotifying: characteristic.isNotifying, error)
        )
    }

    func peripheralSeamIsReadyForWriteWithoutResponse(_ seam: PeripheralSeam) {
        events.append(.readyForWriteWithoutResponse(seam.identifier))
    }
}
