// Deliberately no `import CoreBluetooth`: this file is the compile-time guard on the claim
// that a consumer never needs it. If someone puts a `CBUUID` back into a public signature,
// this file stops compiling.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("Package wiring")
struct PackageSmokeTests {
    @Test("Test target links AsyncBLE and swift-testing runs")
    func packageBuilds() {
        #expect(Bool(true))
    }

    @Test("Addressing services and characteristics needs no CoreBluetooth import")
    func addressingNeedsNoCoreBluetooth() {
        // Services — the filtered-scan path, which is the one the docs call "strongly preferred".
        let heartRate = ServiceID(string: "180D")
        let options = ScanOptions(services: [heartRate], allowDuplicates: true)
        #expect(options.services == [heartRate])

        // Characteristics, untyped and typed.
        let measurement = CharacteristicID(string: "2A37")
        let batteryLevel = Characteristic<UInt8>("2A19")
        #expect(measurement.uuidString == "2A37")
        #expect(batteryLevel.id.uuidString == "2A19")

        // Advertisement data reports services under the same name.
        let advertisement = AdvertisementData(serviceUUIDs: [heartRate])
        #expect(advertisement.serviceUUIDs == [heartRate])
    }

    @Test("An empty service filter is the one spelling of \"scan for everything\"")
    func emptyFilterMeansUnfiltered() {
        #expect(ScanOptions().services.isEmpty)
        #expect(ScanOptions(services: []) == ScanOptions())
    }
}
