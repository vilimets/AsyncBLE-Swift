// Notifications, and what a reconnect does to them.
//
// This is the claim the library is judged on made concrete: a subscription is to a
// characteristic, not to a link (PLAN.md §7 Q2). The same stream, either side of an outage, with
// the discovery walk and the resubscribe happening underneath a caller who only sees a gap in
// the values.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("Connection: notifications")
struct ConnectionNotificationTests {
    @Test("subscribing turns the characteristic on and delivers its values")
    func subscribeAndReceive() async throws {
        let rig = ConnectionRig()
        rig.connect()

        let stream = try await rig.connection.notifications(for: TestUUID.measurement)
        var values = stream.makeAsyncIterator()
        rig.notify(Data([0x5A]), from: TestUUID.measurement)

        let value = try await values.next()
        #expect(value == Data([0x5A]))
        #expect(rig.peripheralCalls.contains(.setNotify(true, characteristic: TestUUID.measurement)))
    }

    @Test("a second subscriber joins without touching the radio again")
    func secondSubscriberJoins() async throws {
        // CoreBluetooth has one notify flag per characteristic, not one per interested caller.
        let rig = ConnectionRig()
        rig.connect()
        let first = try await rig.connection.notifications(for: TestUUID.measurement)

        let second = try await rig.connection.notifications(for: TestUUID.measurement)

        let subscribes = rig.peripheralCalls.filter { $0 == .setNotify(true, characteristic: TestUUID.measurement) }
        #expect(subscribes.count == 1)
        withExtendedLifetime((first, second)) {}
    }

    @Test("the flag goes off when the last subscriber leaves")
    func lastSubscriberUnsubscribes() async throws {
        let rig = ConnectionRig()
        rig.connect()
        var stream: AsyncThrowingStream<Data, Error>? = try await rig.connection
            .notifications(for: TestUUID.measurement)
        #expect(stream != nil)

        stream = nil
        await waitUntil {
            rig.peripheralCalls.contains(.setNotify(false, characteristic: TestUUID.measurement))
        }

        #expect(rig.peripheralCalls.contains(.setNotify(false, characteristic: TestUUID.measurement)))
    }

    @Test("subscribing to a characteristic that neither notifies nor indicates fails")
    func notifyNotSupported() async {
        let rig = ConnectionRig()
        rig.connect()

        let thrown = await errorThrown { try await rig.connection.notifications(for: TestUUID.batteryLevel) }

        #expect(thrown == .operationNotSupported)
        #expect(!rig.peripheralCalls.contains(.setNotify(true, characteristic: TestUUID.batteryLevel)))
    }

    @Test("a subscription the peripheral rejects leaves nothing registered behind it")
    func failedSubscribeIsCleanedUp() async {
        let rig = ConnectionRig()
        rig.connect()
        rig.sync {
            rig.peripheral.gatt.flatMap(\.all)
                .first { $0.uuid == TestUUID.measurement }?
                .notifyError = cbFailure
        }

        let thrown = await errorThrown { try await rig.connection.notifications(for: TestUUID.measurement) }

        // operationFailed, not connectionFailed: the peripheral refused the subscribe, and the
        // link is still up.
        #expect(thrown == .operationFailed)
        #expect(rig.sync { rig.core.subscriptions.count } == 0)
    }
}

@Suite("Connection: across a reconnect")
struct ConnectionReconnectTests {
    @Test("a subscription is re-established when the link comes back")
    func subscriptionsAreRestored() async throws {
        let rig = ConnectionRig()
        rig.connect()
        let stream = try await rig.connection.notifications(for: TestUUID.measurement)
        var values = stream.makeAsyncIterator()
        rig.notify(Data([0x01]), from: TestUUID.measurement)
        rig.sync { rig.peripheral.clearCalls() }

        rig.dropLink()
        #expect(rig.state == .reconnecting(attempt: 1))
        rig.relink()
        await waitUntil {
            rig.peripheralCalls.contains(.setNotify(true, characteristic: TestUUID.measurement))
        }

        // The cache was flushed and re-walked: CoreBluetooth invalidated every object in it.
        #expect(rig.peripheralCalls.contains(.discoverServices(nil)))
        #expect(rig.peripheralCalls.contains(.setNotify(true, characteristic: TestUUID.measurement)))
        #expect(rig.sync { rig.core.pendingRestore.isEmpty })

        // And the same stream keeps yielding.
        rig.notify(Data([0x02]), from: TestUUID.measurement)
        let before = try await values.next()
        let after = try await values.next()
        #expect(before == Data([0x01]))
        #expect(after == Data([0x02]))
        #expect(rig.state == .connected)
    }

    @Test("a characteristic that does not come back fails its own stream and nothing else")
    func missingCharacteristicAfterReconnect() async throws {
        // PLAN.md §7 Q8: the stream throws rather than finishing, because a stream that stops
        // is indistinguishable from a quiet sensor. The connection stays up.
        let rig = ConnectionRig()
        rig.connect()
        let stream = try await rig.connection.notifications(for: TestUUID.measurement)
        var values = stream.makeAsyncIterator()

        rig.dropLink()
        rig.sync {
            rig.peripheral.gatt = [
                FakeService(uuid: TestUUID.batteryService, characteristic: TestUUID.batteryLevel)
            ]
        }
        rig.relink()

        let thrown = await errorThrown { try await values.next() }
        #expect(thrown == .characteristicNotFound(TestUUID.measurement))
        #expect(rig.state == .connected)
    }

    @Test("the discovery cache is rebuilt rather than reused")
    func cacheIsRebuilt() async throws {
        let rig = ConnectionRig()
        rig.connect()
        _ = try await rig.connection.read(TestUUID.measurement)
        rig.sync { rig.peripheral.clearCalls() }

        rig.dropLink()
        rig.relink()
        _ = try await rig.connection.read(TestUUID.measurement)

        #expect(rig.peripheralCalls.contains(.discoverServices(nil)))
    }

    @Test("the radio is re-armed on the drop, and the wait is observable")
    func dropArmsAPendingConnect() async {
        let rig = ConnectionRig()
        rig.connect()
        rig.sync { rig.central.clearCalls() }

        rig.dropLink()

        #expect(rig.state == .reconnecting(attempt: 1))
        #expect(rig.sync { rig.central.calls } == [.connect(rig.peripheral.identifier)])
    }

    @Test("a bounded policy gives up when its deadline expires")
    func boundedPolicyGivesUp() async throws {
        // Wall-clock and unpaused, per PLAN.md §7 Q20 — here, a clock the test owns outright.
        let rig = ConnectionRig(policy: .giveUp(after: .seconds(120)))
        rig.connect()
        let stream = try await rig.connection.notifications(for: TestUUID.measurement)
        var values = stream.makeAsyncIterator()
        rig.dropLink()

        rig.sync { rig.scheduler.advance(by: .seconds(120)) }

        #expect(rig.state == .disconnected(reason: .reconnectGaveUp))
        let thrown = await errorThrown { try await values.next() }
        #expect(thrown == .disconnected(.reconnectGaveUp))
    }

    @Test("the deadline keeps burning while Bluetooth is off")
    func deadlineIgnoresThePowerSwitch() async {
        // The reversal recorded in §7 Q20: a trip through Control Center can end a bounded wait.
        let rig = ConnectionRig(policy: .giveUp(after: .seconds(120)))
        rig.connect()
        rig.dropLink()

        rig.setAdapter(.unavailable(.poweredOff))
        rig.sync { rig.scheduler.advance(by: .seconds(60)) }
        #expect(rig.state == .reconnecting(attempt: 1))

        rig.sync { rig.scheduler.advance(by: .seconds(60)) }
        #expect(rig.state == .disconnected(reason: .reconnectGaveUp))
    }

    @Test("the adapter coming back re-arms the pending connect")
    func adapterReturnReArms() async {
        let rig = ConnectionRig()
        rig.connect()
        rig.dropLink()
        rig.setAdapter(.unavailable(.poweredOff))
        rig.sync { rig.central.clearCalls() }

        rig.setAdapter(.poweredOn)

        #expect(rig.sync { rig.central.calls } == [.connect(rig.peripheral.identifier)])
        #expect(rig.state == .reconnecting(attempt: 1))
    }
}

@Suite("Connection: ending")
struct ConnectionTerminationTests {
    @Test("disconnect finishes the notification streams rather than throwing")
    func disconnectFinishesStreams() async throws {
        // The caller asked for this; an error would be noise.
        let rig = ConnectionRig()
        rig.connect()
        let stream = try await rig.connection.notifications(for: TestUUID.measurement)
        var values = stream.makeAsyncIterator()

        await rig.connection.disconnect()

        let ended = try await values.next()
        #expect(ended == nil)
        #expect(rig.state == .disconnected(reason: .userInitiated))
    }

    @Test("disconnect closes the link and consults no policy")
    func disconnectCancelsTheLink() async {
        let rig = ConnectionRig(policy: .waitIndefinitely())
        rig.connect()
        rig.sync { rig.central.clearCalls() }

        await rig.connection.disconnect()

        #expect(rig.sync { rig.central.calls } == [.cancelConnection(rig.peripheral.identifier)])
        #expect(rig.state == .disconnected(reason: .userInitiated))
    }

    @Test("the late callback after our own cancel changes nothing")
    func lateDisconnectCallbackIsIgnored() async {
        let rig = ConnectionRig()
        rig.connect()
        await rig.connection.disconnect()

        rig.dropLink()  // CoreBluetooth reporting the disconnect we asked for

        #expect(rig.state == .disconnected(reason: .userInitiated))
    }

    @Test("the state stream reports every transition and then ends")
    func stateStreamFollowsTheLink() async {
        let rig = ConnectionRig()
        var seen: [ConnectionState] = []
        let states = rig.connection.states

        rig.connect()
        rig.dropLink()
        rig.relink()
        await rig.connection.disconnect()

        for await state in states {
            seen.append(state)
        }

        #expect(seen == [
            .disconnected(reason: nil),
            .connecting,
            .connected,
            .reconnecting(attempt: 1),
            .connected,
            .disconnected(reason: .userInitiated)
        ])
    }

    @Test("a connection that has ended stops being routed to")
    func terminalConnectionIsUnregistered() async {
        // PLAN.md §7 Q9: the registry holds a connection until it reaches terminal
        // `disconnected`, then lets it go.
        let rig = ConnectionRig()
        rig.connect()
        #expect(rig.sync { rig.bridge.isRegistered(peripheralID: rig.peripheral.identifier) })

        await rig.connection.disconnect()

        #expect(rig.sync { !rig.bridge.isRegistered(peripheralID: rig.peripheral.identifier) })
    }
}
