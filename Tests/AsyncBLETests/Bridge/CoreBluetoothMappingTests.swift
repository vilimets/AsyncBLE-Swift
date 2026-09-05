// The CoreBluetooth quirks the live wrappers exist to absorb, tested without a radio.
//
// These are the only parts of `LiveCentral` / `LivePeripheral` that can be tested at all — the
// rest is one-line forwarding to a CBCentralManager that cannot be constructed in a unit test,
// which is exactly why the seam exists for everything above it.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("Mapping CoreBluetooth's adapter state")
struct AdapterStateMappingTests {
    @Test("every CBManagerState maps, and only poweredOn is success", arguments: [
        (CBManagerState.poweredOn, AdapterState.poweredOn),
        (.poweredOff, .unavailable(reason: .poweredOff)),
        (.unauthorized, .unavailable(reason: .unauthorized)),
        (.unsupported, .unavailable(reason: .unsupported)),
        (.resetting, .unavailable(reason: .resetting)),
        (.unknown, .unavailable(reason: .unknown))
    ])
    func mapsEveryState(managerState: CBManagerState, expected: AdapterState) {
        #expect(AdapterState(managerState) == expected)
    }
}

@Suite("Mapping CoreBluetooth's RSSI reading")
struct RSSIMappingTests {
    @Test("127 is CoreBluetooth's 'no reading' sentinel, not a signal strength")
    func sentinelBecomesNil() {
        // Passed through it would read as +127 dBm, which is not a number any radio produces.
        #expect(Int(rssiReading: 127) == nil)
    }

    @Test("real readings survive", arguments: [-30, -55, -99, 0])
    func readingsPassThrough(reading: Int) {
        #expect(Int(rssiReading: NSNumber(value: reading)) == reading)
    }
}

@Suite("Parsing the advertisement dictionary")
struct AdvertisementDataParsingTests {
    private let heartRate = CBUUID(string: "180D")

    @Test("a full packet is unwrapped into typed properties")
    func fullPacket() {
        let advertisement = AdvertisementData(rawAdvertisementData: [
            CBAdvertisementDataLocalNameKey: "Sensor",
            CBAdvertisementDataManufacturerDataKey: Data([0x4C, 0x00, 0x01]),
            CBAdvertisementDataServiceDataKey: [heartRate: Data([0x2A])],
            CBAdvertisementDataServiceUUIDsKey: [heartRate],
            CBAdvertisementDataOverflowServiceUUIDsKey: [CBUUID(string: "180F")],
            CBAdvertisementDataSolicitedServiceUUIDsKey: [CBUUID(string: "1812")],
            CBAdvertisementDataTxPowerLevelKey: NSNumber(value: -12),
            CBAdvertisementDataIsConnectable: NSNumber(value: true)
        ])

        #expect(advertisement.localName == "Sensor")
        #expect(advertisement.manufacturerData == Data([0x4C, 0x00, 0x01]))
        #expect(advertisement.serviceData == [heartRate: Data([0x2A])])
        #expect(advertisement.serviceUUIDs == [heartRate])
        #expect(advertisement.overflowServiceUUIDs == [CBUUID(string: "180F")])
        #expect(advertisement.solicitedServiceUUIDs == [CBUUID(string: "1812")])
        #expect(advertisement.txPowerLevel == -12)
        #expect(advertisement.isConnectable == true)
    }

    @Test("an empty packet is all absent, never a crash")
    func emptyPacket() {
        let advertisement = AdvertisementData(rawAdvertisementData: [:])
        #expect(advertisement == AdvertisementData())
        // Absent is not false: a packet that carried no connectable flag said nothing about it.
        #expect(advertisement.isConnectable == nil)
    }

    @Test("values of the wrong type are treated as absent")
    func malformedPacket() {
        // The dictionary describes a remote device's advertising packet. Trusting it to be
        // well-formed would put a force-cast on the one code path an attacker controls.
        let advertisement = AdvertisementData(rawAdvertisementData: [
            CBAdvertisementDataLocalNameKey: 42,
            CBAdvertisementDataServiceUUIDsKey: "not an array",
            CBAdvertisementDataTxPowerLevelKey: "loud",
            CBAdvertisementDataIsConnectable: Data()
        ])

        #expect(advertisement.localName == nil)
        #expect(advertisement.serviceUUIDs.isEmpty)
        #expect(advertisement.txPowerLevel == nil)
        #expect(advertisement.isConnectable == nil)
    }

    @Test("unknown keys are ignored")
    func unknownKeys() {
        let advertisement = AdvertisementData(rawAdvertisementData: [
            "SomeFutureKey": "value",
            CBAdvertisementDataLocalNameKey: "Sensor"
        ])
        #expect(advertisement.localName == "Sensor")
    }
}
