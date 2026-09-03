// Reads, writes and the rules around them: lazy discovery on first use, property checks before
// the radio is touched, flow control on write-without-response, and I/O that fails fast rather
// than queueing while the link is down.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("Connection: reads and writes")
struct ConnectionIOTests {
    @Test("a read discovers the characteristic on first use and returns its value")
    func readResolvesAndReturns() async throws {
        let rig = ConnectionRig()
        rig.connect()

        let value = try await rig.connection.read(TestUUID.measurement)

        #expect(value == Data([0x01]))
        #expect(rig.peripheralCalls.contains(.discoverServices(nil)))
        #expect(rig.peripheralCalls.contains(.read(TestUUID.measurement)))
    }

    @Test("a second read does not discover again")
    func discoveryIsCachedForTheLink() async throws {
        let rig = ConnectionRig()
        rig.connect()
        _ = try await rig.connection.read(TestUUID.measurement)

        _ = try await rig.connection.read(TestUUID.batteryLevel)

        #expect(rig.peripheralCalls.filter { $0 == .discoverServices(nil) }.count == 1)
    }

    @Test("a characteristic the peripheral does not have is characteristicNotFound")
    func missingCharacteristic() async {
        let rig = ConnectionRig()
        rig.connect()

        let thrown = await errorThrown { try await rig.connection.read(TestUUID.absent) }

        #expect(thrown == .characteristicNotFound(TestUUID.absent))
    }

    @Test("reading a characteristic that cannot be read never reaches the radio")
    func readNotSupported() async {
        // Failing on the properties rather than on a callback that never comes: the difference
        // between an error and a hang.
        let rig = ConnectionRig()
        rig.connect()

        let thrown = await errorThrown { try await rig.connection.read(TestUUID.controlPoint) }

        #expect(thrown == .operationNotSupported)
        #expect(!rig.peripheralCalls.contains(.read(TestUUID.controlPoint)))
    }

    @Test("a write with response returns once the peripheral acknowledges")
    func writeWithResponse() async throws {
        let rig = ConnectionRig()
        rig.connect()

        try await rig.connection.write(Data([0xAB]), to: TestUUID.controlPoint)

        #expect(rig.peripheralCalls.contains(
            .write(Data([0xAB]), characteristic: TestUUID.controlPoint, mode: .withResponse)
        ))
    }

    @Test("a read the peripheral refuses is an operation failure, not a connection failure")
    func readRefused() async throws {
        // The distinction the error taxonomy gained: an ATT error against a live link says the
        // operation failed, not that the connection did.
        let rig = ConnectionRig()
        rig.connect()
        rig.sync {
            rig.peripheral.gatt.flatMap(\.all)
                .first { $0.uuid == TestUUID.measurement }?
                .readError = cbFailure
        }

        let thrown = await errorThrown { try await rig.connection.read(TestUUID.measurement) }

        #expect(thrown == .operationFailed)
        #expect(rig.state == .connected)
    }

    @Test("a write the peripheral refuses reports the same way")
    func writeRefused() async throws {
        let rig = ConnectionRig()
        rig.connect()
        rig.sync {
            rig.peripheral.gatt.flatMap(\.all)
                .first { $0.uuid == TestUUID.controlPoint }?
                .writeError = cbFailure
        }

        let thrown = await errorThrown {
            try await rig.connection.write(Data([0x01]), to: TestUUID.controlPoint)
        }

        #expect(thrown == .operationFailed)
        #expect(rig.state == .connected)
    }

    @Test("discovery failing is an operation failure too")
    func discoveryFailureIsAnOperationFailure() async {
        let rig = ConnectionRig()
        rig.connect()
        rig.sync { rig.peripheral.servicesDiscoveryError = cbFailure }

        let thrown = await errorThrown { try await rig.connection.read(TestUUID.measurement) }

        #expect(thrown == .operationFailed)
    }

    @Test("a write to a read-only characteristic never reaches the radio")
    func writeNotSupported() async {
        let rig = ConnectionRig()
        rig.connect()

        let thrown = await errorThrown {
            try await rig.connection.write(Data([0x01]), to: TestUUID.batteryLevel)
        }

        #expect(thrown == .operationNotSupported)
    }

    @Test("a write without response waits for the radio to have room")
    func flowControl() async throws {
        // CoreBluetooth drops a write-without-response it has no room for, silently. Waiting is
        // the only thing between a tight write loop and data loss.
        let rig = ConnectionRig()
        rig.connect()
        _ = try await rig.connection.read(TestUUID.measurement)  // warm the discovery cache
        rig.sync { rig.peripheral.canSendWriteWithoutResponse = false }
        rig.sync { rig.peripheral.clearCalls() }

        let write = Task {
            try await rig.connection.write(Data([0x02]), to: TestUUID.controlPoint, mode: .withoutResponse)
        }

        // Parked: nothing has reached the radio.
        await waitUntil { rig.sync { rig.core.writeReadyWaiters.count == 1 } }
        #expect(rig.peripheralCalls.isEmpty)

        rig.sync { rig.peripheral.reportReadyForWriteWithoutResponse() }
        try await write.value

        #expect(rig.peripheralCalls == [
            .write(Data([0x02]), characteristic: TestUUID.controlPoint, mode: .withoutResponse)
        ])
    }

    @Test("only one operation is on the radio at a time")
    func operationsAreSerialized() async throws {
        // The FIFO's visible consequence. ATT allows one outstanding request per connection, so
        // this is the wire's own rule — the queue just makes the library keep it.
        let rig = ConnectionRig(responseMode: .queued)
        rig.connect()

        let first = Task { try await rig.connection.read(TestUUID.measurement) }
        await waitUntil { rig.sync { rig.peripheral.hasPendingResponses } }

        let second = Task { try await rig.connection.read(TestUUID.batteryLevel) }
        await waitUntil { rig.sync { rig.core.ioQueue.depth == 2 } }

        #expect(!rig.peripheralCalls.contains(.read(TestUUID.batteryLevel)))

        // Let discovery and the first read complete, then the second takes its turn.
        while rig.sync({ rig.peripheral.hasPendingResponses }) {
            rig.flush()
            await Task.yield()
        }
        _ = try await first.value
        await waitUntil { rig.sync { rig.peripheral.hasPendingResponses } }
        rig.flush()

        _ = try await second.value
        #expect(rig.peripheralCalls.contains(.read(TestUUID.batteryLevel)))
    }

    @Test("I/O fails fast while the connection is reconnecting")
    func ioFailsFastDuringAnOutage() async throws {
        // PLAN.md §7 Q2: a command composed against pre-drop state should not land on a device
        // that may have rebooted into a different one. So it fails rather than queueing.
        let rig = ConnectionRig()
        rig.connect()
        _ = try await rig.connection.read(TestUUID.measurement)
        rig.dropLink()
        #expect(rig.state == .reconnecting(attempt: 1))

        let read = await errorThrown { try await rig.connection.read(TestUUID.measurement) }
        let write = await errorThrown {
            try await rig.connection.write(Data([0x01]), to: TestUUID.controlPoint)
        }

        #expect(read == .disconnected(.linkLost))
        #expect(write == .disconnected(.linkLost))
    }

    @Test("I/O after a disconnect reports why the connection ended")
    func ioAfterDisconnect() async throws {
        let rig = ConnectionRig()
        rig.connect()
        await rig.connection.disconnect()

        let thrown = await errorThrown { try await rig.connection.read(TestUUID.measurement) }

        #expect(thrown == .disconnected(.userInitiated))
    }

    @Test("a link that drops mid-operation fails the caller waiting on it")
    func dropFailsTheOperationInFlight() async throws {
        // The caller is past the queue and suspended on a CoreBluetooth callback that is never
        // coming. Nothing else would ever resume it.
        let rig = ConnectionRig(responseMode: .queued)
        rig.connect()

        let read = Task { try await rig.connection.read(TestUUID.measurement) }
        await waitUntil { rig.sync { rig.peripheral.hasPendingResponses } }
        rig.dropLink()

        let thrown = await errorThrown { try await read.value }
        #expect(thrown == .disconnected(.linkLost))
    }

    @Test("callers queued behind a drop are failed too")
    func dropFailsTheQueue() async throws {
        let rig = ConnectionRig(responseMode: .queued)
        rig.connect()
        let first = Task { try await rig.connection.read(TestUUID.measurement) }
        await waitUntil { rig.sync { rig.peripheral.hasPendingResponses } }
        let second = Task { try await rig.connection.read(TestUUID.batteryLevel) }
        await waitUntil { rig.sync { rig.core.ioQueue.depth == 2 } }

        rig.dropLink()

        #expect(await errorThrown { try await first.value } == .disconnected(.linkLost))
        #expect(await errorThrown { try await second.value } == .disconnected(.linkLost))
        #expect(rig.sync { rig.core.ioQueue.isEmpty })
    }
}
