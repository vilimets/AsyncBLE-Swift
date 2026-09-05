// Characteristic I/O and the discovery walk, as seen through the log.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("I/O and discovery logging")
struct IOLoggingTests {
    @Test("a successful read logs its issue and its result")
    func readHappyPath() async throws {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        _ = try await rig.connection.read(TestUUID.batteryLevel)

        let recorder = rig.logRecorder!
        #expect(recorder.contains(level: .info, category: .io, messageContains: "read \(TestUUID.batteryLevel)"))
        #expect(recorder.contains(level: .debug, category: .io, messageContains: "→ 1B"))
    }

    @Test("a successful write logs its issue and its acknowledgement")
    func writeHappyPath() async throws {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        try await rig.connection.write(Data([0x01]), to: TestUUID.measurement)

        let recorder = rig.logRecorder!
        #expect(recorder.contains(level: .info, category: .io, messageContains: "with response"))
        #expect(recorder.contains(level: .debug, category: .io, messageContains: "acknowledged"))
    }

    @Test("a subscription logs its issue and its confirmation")
    func subscribeHappyPath() async throws {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        _ = try await rig.connection.notifications(for: TestUUID.measurement)

        let recorder = rig.logRecorder!
        #expect(recorder.contains(level: .info, category: .io, messageContains: "subscribe \(TestUUID.measurement)"))
        #expect(recorder.contains(level: .debug, category: .io, messageContains: "confirmed"))
    }

    @Test("a read the peripheral refuses logs at error")
    func readRefused() async {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        rig.sync {
            rig.peripheral.gatt.flatMap(\.all)
                .first { $0.uuid == TestUUID.batteryLevel }?
                .readError = cbFailure
        }

        _ = await errorThrown { try await rig.connection.read(TestUUID.batteryLevel) }

        #expect(rig.logRecorder!.contains(level: .error, category: .io, messageContains: "failed"))
    }

    @Test("an operation the characteristic does not support logs at error before the radio")
    func operationNotSupported() async {
        let rig = ConnectionRig(recording: true)
        rig.connect()

        _ = await errorThrown {
            try await rig.connection.write(Data([0x01]), to: TestUUID.batteryLevel)
        }

        #expect(rig.logRecorder!.contains(level: .error, category: .io, messageContains: "rejected"))
    }

    @Test("a missing characteristic logs in the discovery category")
    func characteristicNotFound() async {
        let rig = ConnectionRig(recording: true)
        rig.connect()

        _ = await errorThrown { try await rig.connection.read(TestUUID.absent) }

        #expect(rig.logRecorder!.contains(level: .info, category: .gatt, messageContains: "not found"))
    }

    @Test("the discovery walk is logged from start to finish")
    func discoveryWalk() async throws {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        _ = try await rig.connection.read(TestUUID.batteryLevel)

        let recorder = rig.logRecorder!
        #expect(recorder.contains(level: .info, category: .gatt, messageContains: "walking discovery"))
        #expect(recorder.contains(level: .info, category: .gatt, messageContains: "discovery complete"))
    }

    @Test("the discovery cache flush on a reconnect is logged")
    func cacheFlushOnReconnect() async throws {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        _ = try await rig.connection.read(TestUUID.batteryLevel)
        rig.dropLink()

        #expect(rig.logRecorder!.contains(level: .notice, category: .gatt, messageContains: "flushed"))
    }
}
