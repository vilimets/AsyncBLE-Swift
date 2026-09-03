// CBPeripheralDelegate → continuations for read/write/discovery and notification stream yields.
//
// The connection's engine is the peripheral's delegate. There is no separate bridge object
// because there would be nothing in it: every callback here either completes the one operation
// the FIFO allows to be in flight, or feeds the discovery cache, or fans a value out to the
// subscribers. Routing anywhere else would only add a hop.

@preconcurrency import CoreBluetooth
import Foundation

extension ConnectionCore: PeripheralSeamDelegate {
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

    /// A read completed — or a notification arrived. CoreBluetooth uses one callback for both.
    ///
    /// A pending read on that characteristic claims the value; otherwise it is a notification.
    /// Nothing distinguishes them at the API level, so a notification that lands while a read on
    /// the same characteristic is in flight will complete the read. That is CoreBluetooth's
    /// ambiguity rather than this library's, and the FIFO keeps the window to one operation.
    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateValueFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {
        if let pending = pendingRead, pending.uuid == characteristic.uuid {
            pendingRead = nil
            if let error {
                ioLog.error("read \(characteristic.uuid) failed: \(error)", ioMetadata(characteristic.uuid))
                pending.deliver(.failure(BluetoothError.operationFailed(underlying: error)))
            } else {
                // CoreBluetooth delivers a value by mutating the characteristic, not by passing
                // it. An empty read is legal, so an absent value reads as empty rather than nil.
                let value = characteristic.value ?? Data()
                ioLog.debug("read \(characteristic.uuid) → \(value.count)B", ioMetadata(characteristic.uuid))
                pending.deliver(.success(value))
            }
            return
        }

        guard error == nil, let value = characteristic.value else { return }
        subscriptions.deliver(value, for: characteristic.uuid)
    }

    func peripheralSeam(_ seam: PeripheralSeam, didWriteValueFor characteristic: CharacteristicSeam, error: NSError?) {
        guard let pending = pendingWrite, pending.uuid == characteristic.uuid else { return }
        pendingWrite = nil
        if let error {
            ioLog.error("write \(characteristic.uuid) failed: \(error)", ioMetadata(characteristic.uuid))
            pending.deliver(.failure(BluetoothError.operationFailed(underlying: error)))
        } else {
            ioLog.debug("write \(characteristic.uuid) acknowledged", ioMetadata(characteristic.uuid))
            pending.deliver(.success(()))
        }
    }

    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateNotificationStateFor characteristic: CharacteristicSeam,
        error: NSError?
    ) {
        guard let pending = pendingNotify, pending.uuid == characteristic.uuid else {
            // An unsubscribe the library issued for itself when the last subscriber left. Nobody
            // is waiting on it.
            return
        }
        pendingNotify = nil
        if let error {
            ioLog.error(
                "subscription \(characteristic.uuid) failed: \(error)", ioMetadata(characteristic.uuid)
            )
            pending.deliver(.failure(BluetoothError.operationFailed(underlying: error)))
        } else {
            ioLog.debug("subscription \(characteristic.uuid) confirmed", ioMetadata(characteristic.uuid))
            pending.deliver(.success(()))
        }
    }

    /// The radio has room for another write-without-response.
    ///
    /// Everyone parked on flow control is released at once; the FIFO means at most one of them
    /// can actually be mid-write, and the rest are still queued behind it.
    func peripheralSeamIsReadyForWriteWithoutResponse(_ seam: PeripheralSeam) {
        let parked = writeReadyWaiters
        writeReadyWaiters = []
        for waiter in parked {
            waiter(.success(()))
        }
    }
}
