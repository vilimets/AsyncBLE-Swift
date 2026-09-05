// The central-side bridge: adapter broadcast, scanning on one radio for several callers, and
// routing a peripheral's callbacks to the connection that owns it.
//
// Everything here runs through `library.sync` because the bridge asserts it is on the library
// queue — the same hop the `Central` actor's executor makes for real callers.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("The central delegate bridge")
struct CentralDelegateBridgeTests {
    private let heartRate = CBUUID(string: "180D")
    private let battery = CBUUID(string: "180F")

    /// A bridge, the fake radio under it, and the queue both are confined to.
    private struct Rig {
        let bridge: CentralDelegateBridge
        let central: FakeCentral
        let library: LibraryQueue
    }

    private func makeBridge(adapterState: AdapterState = .poweredOn) -> Rig {
        let central = FakeCentral(adapterState: adapterState)
        let library = LibraryQueue(label: "test.bridge")
        let bridge = library.sync { CentralDelegateBridge(seam: central, library: library) }
        return Rig(bridge: bridge, central: central, library: library)
    }

    // MARK: Adapter state

    @Test("the bridge starts holding whatever the adapter already said")
    func adapterStateStartsCurrent() {
        let rig = makeBridge(adapterState: .unavailable(reason: .unknown))
        #expect(rig.bridge.adapterStates.current == .unavailable(reason: .unknown))
    }

    @Test("adapter changes are broadcast")
    func adapterChangesBroadcast() async {
        let rig = makeBridge(adapterState: .unavailable(reason: .unknown))
        var iterator = rig.bridge.adapterStates.stream().makeAsyncIterator()
        let initial = await iterator.next()

        rig.central.emit(adapterState: .poweredOn)
        let next = await iterator.next()

        #expect(initial == .unavailable(reason: .unknown))
        #expect(next == .poweredOn)
    }

    // MARK: Scanning

    @Test("starting a scan tells the radio what this caller asked for")
    func scanIssuesTheFilter() {
        let rig = makeBridge()
        let stream = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }

        #expect(rig.central.calls == [.scan(services: [heartRate], allowDuplicates: false)])
        withExtendedLifetime(stream) {}
    }

    @Test("two callers scan on one radio, for the union of what they asked for")
    func unionFilter() {
        // CoreBluetooth has one scan and the last call replaces the filter, so a second caller
        // asking for a different service must widen the radio rather than displace the first.
        let rig = makeBridge()
        let first = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }
        let second = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [battery], allowDuplicates: true)) }

        let union = [battery, heartRate].sorted { $0.uuidString < $1.uuidString }
        #expect(rig.central.calls.count == 2)
        #expect(rig.central.calls.last == .scan(services: union, allowDuplicates: true))
        withExtendedLifetime((first, second)) {}
    }

    @Test("an unfiltered caller makes the radio scan for everything")
    func unfilteredWins() {
        let rig = makeBridge()
        let first = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }
        let second = rig.library.sync { rig.bridge.startScan(ScanOptions()) }

        #expect(rig.central.calls.last == .scan(services: nil, allowDuplicates: false))
        withExtendedLifetime((first, second)) {}
    }

    @Test("a second identical scan does not disturb the first")
    func identicalPlanIsNotReissued() {
        // Re-issuing the same scan restarts CoreBluetooth's duplicate filtering, which would
        // make one caller's stream repeat itself because another caller happened to subscribe.
        let rig = makeBridge()
        let first = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }
        let second = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }

        #expect(rig.central.calls == [.scan(services: [heartRate], allowDuplicates: false)])
        #expect(rig.bridge.activeScanCount == 2)
        withExtendedLifetime((first, second)) {}
    }

    @Test("a discovery reaches only the callers that asked for it")
    func discoveryIsFilteredPerSession() async {
        let rig = makeBridge()
        let heartRateStream = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }
        let batteryStream = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [battery])) }
        var heartRateValues = heartRateStream.makeAsyncIterator()

        let peripheral = FakePeripheral(name: "Strap")
        rig.central.emitDiscovery(
            of: peripheral,
            advertisement: AdvertisementData(localName: "Strap", serviceUUIDs: [heartRate]),
            rssi: -60
        )

        let discovery = await heartRateValues.next()
        #expect(discovery?.peripheralID == peripheral.identifier)
        #expect(discovery?.name == "Strap")
        #expect(discovery?.rssi == -60)
        // The battery session saw the same packet arrive at the radio and correctly ignored it.
        #expect(rig.bridge.activeScanCount == 2)
        withExtendedLifetime(batteryStream) {}
    }

    @Test("a UUID in the overflow area still counts as advertised")
    func overflowUUIDsMatch() async {
        let rig = makeBridge()
        let stream = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }
        var values = stream.makeAsyncIterator()

        rig.central.emitDiscovery(
            of: FakePeripheral(),
            advertisement: AdvertisementData(overflowServiceUUIDs: [heartRate])
        )

        let discovery = await values.next()
        #expect(discovery != nil)
    }

    @Test("the advertised name wins over the peripheral's cached one")
    func advertisedNameWins() async {
        // CBPeripheral.name can be a GAP name cached from an earlier connection, which is not
        // what this packet said.
        let rig = makeBridge()
        let stream = rig.library.sync { rig.bridge.startScan(ScanOptions()) }
        var values = stream.makeAsyncIterator()

        rig.central.emitDiscovery(
            of: FakePeripheral(name: "Cached"),
            advertisement: AdvertisementData(localName: "Advertised")
        )

        let discovery = await values.next()
        #expect(discovery?.name == "Advertised")
    }

    @Test("a caller that did not ask for duplicates sees each peripheral once")
    func duplicatesAreFilteredPerSession() async {
        // Even though the radio is reporting duplicates, because the other caller wanted them.
        let rig = makeBridge()
        let once = rig.library.sync { rig.bridge.startScan(ScanOptions()) }
        let repeatedly = rig.library.sync { rig.bridge.startScan(ScanOptions(allowDuplicates: true)) }
        var onceValues = once.makeAsyncIterator()
        var repeatedValues = repeatedly.makeAsyncIterator()

        let peripheral = FakePeripheral()
        rig.central.emitDiscovery(of: peripheral, rssi: -50)
        rig.central.emitDiscovery(of: peripheral, rssi: -70)

        let first = await onceValues.next()
        let repeatedFirst = await repeatedValues.next()
        let repeatedSecond = await repeatedValues.next()

        #expect(first?.rssi == -50)
        #expect(repeatedFirst?.rssi == -50)
        #expect(repeatedSecond?.rssi == -70)
    }

    @Test("the last scan ending stops the radio")
    func lastScanStopsTheRadio() {
        // A scan that outlives its consumer is a battery bug, so ending iteration has to reach
        // stopScan() without the caller doing anything.
        let rig = makeBridge()
        var stream: AsyncStream<Discovery>? = rig.library.sync { rig.bridge.startScan(ScanOptions()) }
        #expect(rig.bridge.activeScanCount == 1)

        stream = nil
        rig.library.sync {}  // let the termination hop land

        #expect(rig.library.sync { rig.bridge.activeScanCount } == 0)
        #expect(rig.central.calls.last == .stopScan)
    }

    @Test("one caller leaving narrows the radio's filter to what is left")
    func remainingSessionNarrowsTheFilter() {
        let rig = makeBridge()
        let kept = rig.library.sync { rig.bridge.startScan(ScanOptions(services: [heartRate])) }
        var leaving: AsyncStream<Discovery>? = rig.library.sync { rig.bridge.startScan(ScanOptions()) }
        #expect(rig.central.calls.last == .scan(services: nil, allowDuplicates: false))

        leaving = nil
        rig.library.sync {}

        #expect(rig.central.calls.last == .scan(services: [heartRate], allowDuplicates: false))
        #expect(rig.library.sync { rig.bridge.activeScanCount } == 1)
        withExtendedLifetime(kept) {}
    }

    @Test("the adapter going away finishes every scan")
    func adapterLossFinishesScans() async {
        // Documented on Central.scan(_:): an adapter that becomes unavailable during a scan
        // finishes the stream, rather than leaving it silently empty forever.
        let rig = makeBridge()
        let stream = rig.library.sync { rig.bridge.startScan(ScanOptions()) }
        var values = stream.makeAsyncIterator()

        rig.central.emit(adapterState: .unavailable(reason: .poweredOff))
        let ended = await values.next()

        #expect(ended == nil)
        #expect(rig.library.sync { rig.bridge.activeScanCount } == 0)
    }

    // MARK: Routing

    @Test("a peripheral's callbacks reach the connection registered for it")
    func routesToTheRightSink() {
        let rig = makeBridge()
        let peripheral = FakePeripheral()
        let other = FakePeripheral()
        let sink = FakeSink(peripheralID: peripheral.identifier)
        let otherSink = FakeSink(peripheralID: other.identifier)
        rig.library.sync {
            rig.bridge.register(sink)
            rig.bridge.register(otherSink)
        }

        rig.central.emitConnect(peripheral)
        rig.central.emitDisconnect(peripheral, error: cbFailure)
        rig.central.emitFailToConnect(other)

        #expect(sink.events == [.connected, .disconnected(cbFailure)])
        #expect(otherSink.events == [.failedToConnect(cbFailure)])
    }

    @Test("every connection hears about the adapter")
    func adapterChangesReachEverySink() {
        // A pending connect is void while the radio is off, and worth re-arming when it comes
        // back — so this is not optional for any of them.
        let rig = makeBridge()
        let first = FakeSink(peripheralID: UUID())
        let second = FakeSink(peripheralID: UUID())
        rig.library.sync {
            rig.bridge.register(first)
            rig.bridge.register(second)
        }

        rig.central.emit(adapterState: .unavailable(reason: .poweredOff))

        #expect(first.events == [.adapterChanged(.unavailable(reason: .poweredOff))])
        #expect(second.events == [.adapterChanged(.unavailable(reason: .poweredOff))])
    }

    @Test("unregistering stops the routing")
    func unregisterStopsRouting() {
        let rig = makeBridge()
        let peripheral = FakePeripheral()
        let sink = FakeSink(peripheralID: peripheral.identifier)
        rig.library.sync { rig.bridge.register(sink) }
        rig.library.sync { rig.bridge.unregister(peripheralID: peripheral.identifier) }

        rig.central.emitConnect(peripheral)

        #expect(sink.events.isEmpty)
        #expect(!rig.bridge.isRegistered(peripheralID: peripheral.identifier))
    }

    @Test("a link that lands with nobody waiting is closed immediately")
    func orphanedLinkIsClosed() {
        // PLAN.md §7 Q10: the last caller cancelled, the attempt was withdrawn, and the link
        // landed anyway. Nothing holds it, and by Q9 nothing ever would close it.
        let rig = makeBridge()
        let peripheral = FakePeripheral()

        rig.central.emitConnect(peripheral)

        #expect(rig.central.calls == [.cancelConnection(peripheral.identifier)])
    }
}
