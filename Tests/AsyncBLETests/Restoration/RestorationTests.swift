// State restoration: what happens when iOS relaunches the app and hands the links back.
//
// None of this proves restoration works — only that the library does the right thing when told
// it happened. The `willRestoreState` callback itself needs a real device, a real termination
// and a real peripheral walking back into range; that test is written down in the
// BackgroundModes article rather than here.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("Restoration: adopting the links iOS hands back")
struct RestorationTests {
    @Test("a restored live link comes back connected, and on the stream")
    func restoresAConnectedLink() async throws {
        let rig = CentralRig()
        rig.peripheral.linkState = .connected
        var restored = rig.central.restoredConnections.makeAsyncIterator()

        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }

        let connection = await restored.next()
        #expect(connection?.peripheralID == rig.peripheralID)
        #expect(rig.core?.state == .connected)
        #expect(await rig.central.activeConnections.count == 1)
    }

    @Test("a subscriber that arrives after the restoration still sees it")
    func replaysToALateSubscriber() async throws {
        // The whole reason this is a replaying stream: restoration is delivered before the app
        // has run a line of its own code, so every subscriber is a late one.
        let rig = CentralRig()
        rig.peripheral.linkState = .connected

        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }

        var restored = rig.central.restoredConnections.makeAsyncIterator()
        let connection = await restored.next()
        #expect(connection?.peripheralID == rig.peripheralID)
    }

    @Test("several restored links all arrive, in order")
    func restoresSeveralLinks() async throws {
        let rig = CentralRig()
        rig.peripheral.linkState = .connected
        let second = rig.addPeripheral()
        second.linkState = .connected

        rig.sync { rig.radio.emitWillRestore([rig.peripheral, second]) }

        var restored = rig.central.restoredConnections.makeAsyncIterator()
        let first = await restored.next()
        let next = await restored.next()
        #expect(first?.peripheralID == rig.peripheralID)
        #expect(next?.peripheralID == second.identifier)
        #expect(await rig.central.activeConnections.count == 2)
    }

    @Test("a restored pending connect becomes a reconnect wait, armed once")
    func restoresAPendingConnect() async throws {
        // The OS was still holding the connect when the app was terminated, and kept holding it.
        // `reconnecting` is what that already means in this library's vocabulary.
        let rig = CentralRig()
        rig.peripheral.linkState = .connecting
        var restored = rig.central.restoredConnections.makeAsyncIterator()

        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }

        _ = await restored.next()
        #expect(rig.core?.state == .reconnecting(arm: 1))
        #expect(rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1)
    }

    @Test("a restored pending connect under `.never` ends instead of waiting")
    func pendingConnectUnderNeverGivesUp() async throws {
        // `.never` says do not wait for a link that dropped. A pending connect the OS is holding
        // is that wait, so restoring one under this policy ends it rather than adopting it.
        let rig = CentralRig(configuration: Central.Configuration(reconnectPolicy: .never))
        rig.peripheral.linkState = .connecting
        var restored = rig.central.restoredConnections.makeAsyncIterator()

        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }

        _ = await restored.next()
        #expect(rig.core == nil)
        #expect(await rig.central.activeConnections.isEmpty)
    }

    @Test("a restored peripheral with nothing in flight is skipped")
    func skipsADisconnectedPeripheral() async throws {
        let rig = CentralRig()
        rig.peripheral.linkState = .disconnected

        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }

        #expect(await rig.central.activeConnections.isEmpty)
        #expect(rig.sync { rig.radio.calls }.isEmpty)
    }

    @Test("a restored scan is stopped: nothing is left to consume it")
    func stopsARestoredScan() async throws {
        // The `ScanSession` that asked for it died with the process, and `applyScanPlan()` will
        // not stop it either — its `activePlan` is nil. A scan with no consumer is a battery bug.
        let rig = CentralRig()
        rig.peripheral.linkState = .connected

        rig.sync { rig.radio.emitWillRestore([rig.peripheral], wasScanning: true) }

        #expect(rig.sync { rig.radio.calls }.contains(.stopScan))
    }

    @Test("a scan that was not running is not stopped")
    func doesNotStopAScanThatWasNotRunning() async throws {
        let rig = CentralRig()
        rig.peripheral.linkState = .connected

        rig.sync { rig.radio.emitWillRestore([rig.peripheral], wasScanning: false) }

        #expect(rig.sync { rig.radio.calls }.contains(.stopScan) == false)
    }

    @Test("restoring the same peripheral twice yields one connection")
    func restorationIsIdempotent() async throws {
        let rig = CentralRig()
        rig.peripheral.linkState = .connected
        var restored = rig.central.restoredConnections.makeAsyncIterator()

        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }
        let first = await restored.next()
        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }

        #expect(await rig.central.activeConnections.count == 1)
        #expect(rig.core?.state == .connected)
        // The second restoration published nothing, so the next element is whatever comes after
        // it — and there is nothing, which is what the identity check below stands in for.
        #expect(first?.peripheralID == rig.peripheralID)
    }

    @Test("connecting to a restored peripheral returns the restored connection")
    func connectFindsTheRestoredConnection() async throws {
        let rig = CentralRig()
        rig.peripheral.linkState = .connected
        var restored = rig.central.restoredConnections.makeAsyncIterator()
        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }
        let adopted = try #require(await restored.next())

        let connected = try await rig.central.connect(rig.peripheralID)

        #expect(connected === adopted)
        // Already up, so nothing was armed: the link is device-wide and this caller joined it.
        #expect(rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 0)
    }

    @Test("a restored link that drops reconnects like any other")
    func aRestoredLinkReconnects() async throws {
        // The point of adopting into the ordinary engine: nothing downstream knows or cares that
        // this connection arrived by restoration.
        let rig = CentralRig()
        rig.peripheral.linkState = .connected
        var restored = rig.central.restoredConnections.makeAsyncIterator()
        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }
        _ = await restored.next()

        rig.sync { rig.radio.emitDisconnect(rig.peripheral, error: cbFailure) }

        #expect(rig.core?.state == .reconnecting(arm: 1))
        #expect(rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1)
    }

    @Test("re-subscribing on a restored link reuses the notify flag iOS preserved")
    func resubscribeReusesTheLiveNotifyFlag() async throws {
        // The orphan-notify decision: the streams died with the process but the peripheral is
        // still notifying, so re-subscribing attaches to that rather than paying a round trip.
        let rig = CentralRig()
        rig.peripheral.linkState = .connected
        let characteristic = try #require(
            rig.peripheral.gatt
                .flatMap(\.all)
                .first { $0.uuid == TestUUID.measurement }
        )
        characteristic.isNotifying = true
        var restored = rig.central.restoredConnections.makeAsyncIterator()
        rig.sync { rig.radio.emitWillRestore([rig.peripheral]) }
        let connection = try #require(await restored.next())

        let stream = try await connection.notifications(for: TestUUID.measurement)

        let subscribed = FakePeripheral.Call.setNotify(true, characteristic: TestUUID.measurement)
        #expect(rig.sync { rig.peripheral.calls }.contains(subscribed) == false)
        withExtendedLifetime(stream) {}
    }

    @Test("no restore identifier means no restoration option on the manager")
    func withoutAnIdentifierNothingOptsIn() {
        // Passing the key at all is what makes iOS preserve state, so a central that did not ask
        // for restoration must not carry it.
        let without = LiveCentral.managerOptions(showPowerAlert: false, restoreIdentifier: nil)
        let with = LiveCentral.managerOptions(showPowerAlert: false, restoreIdentifier: "main")

        #expect(without[CBCentralManagerOptionRestoreIdentifierKey] == nil)
        #expect(with[CBCentralManagerOptionRestoreIdentifierKey] as? String == "main")
    }

    @Test("restoration that lands before the central is wired up is not dropped")
    func restorationBeforeTheHandlerIsAttached() async throws {
        // `willRestoreState` is CoreBluetooth's first callback and can beat `Central.init`.
        // Losing it there would lose every link the app was relaunched to service.
        let library = LibraryQueue(label: "test.restore.race")
        let radio = FakeCentral()
        let peripheral = FakePeripheral(gatt: ConnectionRig.defaultGATT())
        peripheral.responseMode = .immediate
        peripheral.linkState = .connected
        let bridge = CentralDelegateBridge(seam: radio, library: library)

        // Delivered while nothing is listening — the bridge exists, the central does not.
        library.sync { radio.emitWillRestore([peripheral]) }

        var seen: [UUID] = []
        library.sync { bridge.onRestoredPeripherals = { seen = $0.map(\.identifier) } }
        #expect(seen == [peripheral.identifier])
    }
}
