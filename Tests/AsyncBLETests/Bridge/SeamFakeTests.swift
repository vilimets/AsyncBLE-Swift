// The fakes are load-bearing: everything in 2c–2f is tested through them, so a fake that lies
// about CoreBluetooth would quietly invalidate the suite above it. These tests pin the
// behaviors that are easy to get wrong and expensive to get wrong.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("The CoreBluetooth fakes")
struct SeamFakeTests {
    private let heartRate = CBUUID(string: "180D")
    private let measurement = CBUUID(string: "2A37")
    private let battery = CBUUID(string: "180F")

    private func makePeripheral() -> FakePeripheral {
        FakePeripheral(gatt: [
            FakeService(uuid: heartRate, characteristic: measurement),
            FakeService(uuid: battery, characteristic: CBUUID(string: "2A19"))
        ])
    }

    /// Walks discovery to completion, as the discovery cache will in Phase 2d.
    private func discoverEverything(on peripheral: FakePeripheral) {
        peripheral.responseMode = .immediate
        peripheral.discoverServices(nil)
        for service in peripheral.services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    @Test("nothing is discovered until discovery runs")
    func gattStartsHidden() {
        let peripheral = makePeripheral()
        #expect(peripheral.services.isEmpty)
        #expect(!peripheral.gatt.isEmpty)
    }

    @Test("a queued answer stays parked until the test flushes it")
    func responsesAreAsyncByDefault() {
        // CoreBluetooth never answers inline. A fake that did would let production code that
        // assumes synchrony pass here and deadlock on a real radio.
        let peripheral = makePeripheral()
        let recorder = SeamRecorder()
        peripheral.seamDelegate = recorder

        peripheral.discoverServices(nil)
        #expect(recorder.events.isEmpty)
        #expect(peripheral.hasPendingResponses)

        peripheral.flush()
        #expect(recorder.events == [.discoveredServices(peripheral.identifier, nil)])
        #expect(peripheral.services.count == 2)
    }

    @Test("discovery honours the UUID filter it was given")
    func discoveryFilters() {
        let peripheral = makePeripheral()
        peripheral.responseMode = .immediate

        peripheral.discoverServices([heartRate])
        #expect(peripheral.services.map(\.uuid) == [heartRate])

        guard let service = peripheral.services.first else { return }
        peripheral.discoverCharacteristics([measurement], for: service)
        #expect(service.characteristics.map(\.uuid) == [measurement])
    }

    @Test("a write-without-response is never acknowledged")
    func fireAndForgetHasNoCallback() {
        // Which is why it needs flow control instead: there is no callback to wait on.
        let peripheral = makePeripheral()
        discoverEverything(on: peripheral)
        let recorder = SeamRecorder()
        peripheral.seamDelegate = recorder
        guard let characteristic = peripheral.services.first?.characteristics.first else {
            Issue.record("discovery revealed no characteristic")
            return
        }

        peripheral.writeValue(Data([0x01]), for: characteristic, mode: .withoutResponse)
        #expect(recorder.events.isEmpty)

        peripheral.writeValue(Data([0x02]), for: characteristic, mode: .withResponse)
        #expect(recorder.events == [.wroteValue(measurement, nil)])
    }

    @Test("a write is readable back, so command-then-read tests are possible")
    func writesAreReadableBack() {
        let peripheral = makePeripheral()
        discoverEverything(on: peripheral)
        let recorder = SeamRecorder()
        peripheral.seamDelegate = recorder
        guard let characteristic = peripheral.services.first?.characteristics.first else {
            Issue.record("discovery revealed no characteristic")
            return
        }

        peripheral.writeValue(Data([0xAB]), for: characteristic, mode: .withoutResponse)
        peripheral.readValue(for: characteristic)
        #expect(recorder.events.contains(.updatedValue(measurement, Data([0xAB]), nil)))
    }

    @Test("a disconnect invalidates everything discovery found")
    func disconnectInvalidatesTheTree() {
        // Apple invalidates every CBService and CBCharacteristic on disconnect. A fake that
        // kept them would hide the bug the discovery cache exists to avoid (PLAN.md §7 Q2).
        let central = FakeCentral()
        let peripheral = makePeripheral()
        discoverEverything(on: peripheral)
        #expect(peripheral.services.count == 2)

        central.emitDisconnect(peripheral)
        #expect(peripheral.services.isEmpty)
    }

    @Test("a peripheral can come back from a reconnect with a different GATT tree")
    func gattCanChangeAcrossAReconnect() {
        // The case behind PLAN.md §7 Q8: the characteristic a stream was subscribed to is
        // simply not there any more.
        let peripheral = makePeripheral()
        discoverEverything(on: peripheral)
        #expect(peripheral.services.count == 2)

        peripheral.gatt = [FakeService(uuid: battery, characteristic: CBUUID(string: "2A19"))]
        #expect(peripheral.services.isEmpty)

        discoverEverything(on: peripheral)
        #expect(peripheral.services.map(\.uuid) == [battery])
    }

    @Test("the central records what the library asked the radio to do")
    func centralLogsCalls() {
        let central = FakeCentral()
        let peripheral = makePeripheral()

        central.scanForPeripherals(services: [heartRate], allowDuplicates: true)
        central.connect(peripheral)
        central.connect(peripheral)
        central.cancelConnection(peripheral)
        central.stopScan()

        #expect(central.calls == [
            .scan(services: [heartRate], allowDuplicates: true),
            .connect(peripheral.identifier),
            .connect(peripheral.identifier),
            .cancelConnection(peripheral.identifier),
            .stopScan
        ])
        #expect(central.connectCount(for: peripheral.identifier) == 2)
    }

    @Test("adapter changes reach the delegate with the new state already readable")
    func adapterChangesAreReported() {
        let central = FakeCentral(adapterState: .unavailable(reason: .unknown))
        let recorder = SeamRecorder()
        central.seamDelegate = recorder

        central.emit(adapterState: .poweredOn)
        central.emit(adapterState: .unavailable(reason: .poweredOff))

        #expect(recorder.events == [.adapterState(.poweredOn), .adapterState(.unavailable(reason: .poweredOff))])
        #expect(central.adapterState == .unavailable(reason: .poweredOff))
    }

    @Test("a peripheral the system already knows can be retrieved without a scan")
    func retrieveKnownPeripheral() {
        // The path connectWhenInRange(_:) takes at launch (PLAN.md §7 Q17).
        let central = FakeCentral()
        let peripheral = makePeripheral()
        central.knownPeripherals[peripheral.identifier] = peripheral

        #expect(central.peripheral(withID: peripheral.identifier) === peripheral)
        #expect(central.peripheral(withID: UUID()) == nil)
    }

    @Test("flow control parks a write until the radio reports room")
    func flowControlIsScriptable() {
        let peripheral = makePeripheral()
        let recorder = SeamRecorder()
        peripheral.seamDelegate = recorder
        peripheral.canSendWriteWithoutResponse = false

        #expect(!peripheral.canSendWriteWithoutResponse)
        peripheral.reportReadyForWriteWithoutResponse()
        #expect(peripheral.canSendWriteWithoutResponse)
        #expect(recorder.events == [.readyForWriteWithoutResponse(peripheral.identifier)])
    }
}
