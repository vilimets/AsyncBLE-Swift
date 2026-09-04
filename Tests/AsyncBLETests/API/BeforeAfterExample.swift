// The Phase 1 definition of done: the public API, exercised at a real call site.
//
// Nothing here runs — every body in Public/ is still `fatalError` — but it all compiles, which
// is the point: the API is judged by how this file reads, before any of it is implemented.
//
// ─── Before: the same heart-rate monitor in plain CoreBluetooth ───────────────────────────
//
//   final class Monitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
//       private var central: CBCentralManager!
//       private var peripheral: CBPeripheral?
//
//       func start() { central = CBCentralManager(delegate: self, queue: nil) }
//
//       func centralManagerDidUpdateState(_ c: CBCentralManager) {
//           guard c.state == .poweredOn else { return }        // ...and if it never is?
//           c.scanForPeripherals(withServices: [heartRate])
//       }
//       func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, ...) {
//           peripheral = p                                     // retain it or it deallocates
//           p.delegate = self
//           c.stopScan()
//           c.connect(p)                                       // no timeout exists — hangs forever
//       }
//       func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
//           p.discoverServices([heartRate])                    // two more callbacks to go
//       }
//       func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
//           p.discoverCharacteristics([measurement], for: p.services!.first!)
//       }
//       func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, ...) {
//           p.setNotifyValue(true, for: s.characteristics!.first!)
//       }
//       func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, ...) {
//           handle(ch.value)                                   // finally
//       }
//       func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
//                           error: Error?) {
//           // Was this the user, or the link? Same callback either way. And every
//           // characteristic you discovered above is now invalid, so on the way back
//           // you get to run all four discovery callbacks again — assuming you kept
//           // enough state to know which ones you were subscribed to.
//           c.connect(p)
//       }
//   }
//
// Seven callbacks, one implicitly unwrapped optional, two force unwraps, and a resubscribe
// path most codebases never get right. The "after" is below.

@preconcurrency import CoreBluetooth
import Foundation

@testable import AsyncBLE

private let heartRateService = CBUUID(string: "180D")
private let measurement = CharacteristicID(string: "2A37")

/// After: the whole thing, top to bottom.
private func monitorHeartRate() async throws {
    let central = Central(
        configuration: Central.Configuration(
            connectTimeout: .seconds(5),
            reconnectPolicy: .waitIndefinitely()
        )
    )

    let discoveries = try await central.scan(services: [heartRateService])
    for await device in discoveries {
        let connection = try await central.connect(device)
        let samples = try await connection.notifications(for: measurement)
        for try await sample in samples {
            print("\(device.name ?? "sensor"): \(sample.count) bytes")
        }
        break
    }
}

/// The subscription above outlives a dropped link. This is all you write to watch it happen.
private func showLinkStatus(_ connection: Connection) async {
    for await state in connection.states {
        switch state {
        case .connected:
            print("connected")
        case .connecting:
            print("connecting…")
        case .reconnecting(let attempt):
            print("out of range — waiting (arm \(attempt))")
        case .disconnected(.userInitiated), .disconnected(nil):
            print("disconnected")
        case .disconnected(let reason):
            print("disconnected: \(String(describing: reason))")
        }
    }
}

/// Reconnecting to a saved device at launch: no scan, no polling, no timer.
private func resumeSavedDevice(_ peripheralID: UUID) async throws -> Connection {
    let central = Central(
        configuration: Central.Configuration(reconnectPolicy: .giveUp(after: .seconds(300)))
    )
    return try await central.connectWhenAvailable(peripheralID)
}

/// Handling an adapter that is off, and a device that never shows up.
private func connectToKnownDevice(_ peripheralID: UUID) async -> Connection? {
    let central = Central()
    do {
        return try await central.connect(peripheralID, timeout: .seconds(3))
    } catch BluetoothError.bluetoothUnavailable(.poweredOff) {
        print("Turn on Bluetooth to continue.")
    } catch BluetoothError.connectTimeout {
        print("Device did not respond. Is it awake and in range?")
    } catch {
        print("Connection failed: \(error)")
    }
    return nil
}

/// And knowing when it is worth trying again.
private func bluetoothBanner(_ central: Central) async {
    for await state in central.adapterStates {
        switch state {
        case .poweredOn:
            print("hide banner")
        case .unavailable(.poweredOff):
            print("Bluetooth is off")
        case .unavailable(let reason):
            print("Bluetooth unavailable: \(reason)")
        }
    }
}

/// Writes: acknowledged by default, fire-and-forget when throughput matters. Both land in the
/// order they were called, even from different tasks.
private func sendCommands(_ connection: Connection, to characteristic: CharacteristicID) async throws {
    try await connection.write(Data([0x01]), to: characteristic)

    for chunk in [Data([0x02]), Data([0x03])] {
        try await connection.write(chunk, to: characteristic, mode: .withoutResponse)
    }

    await connection.disconnect()
}

/// The escape hatch, for the parts of CoreBluetooth 0.1.0 does not wrap.
private func inspectMTU(_ connection: Connection) async -> Int {
    await connection.withRaw { peripheral, _ in
        peripheral.maximumWriteValueLength(for: .withoutResponse)
    }
}
