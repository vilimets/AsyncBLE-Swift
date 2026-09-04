// Typed characteristics: the handle, the built-in codecs, and where decoding failures land.
//
// The typed API is a thin layer over the untyped one, so these tests are about the codec and
// the error path — the queueing, discovery and reconnect behaviour is already covered against
// the untyped calls these forward to, and is deliberately not duplicated here.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("Typed characteristics")
struct TypedCharacteristicTests {
    private let batteryLevel = Characteristic<UInt8>(TestUUID.batteryLevel)
    private let rawMeasurement = Characteristic<Data>(TestUUID.measurement)

    // MARK: Reading

    @Test("a typed read decodes the bytes")
    func typedRead() async throws {
        let rig = ConnectionRig()
        rig.connect()

        let level = try await rig.connection.read(batteryLevel)

        #expect(level == 100)
    }

    @Test("Characteristic<Data> returns the bytes unchanged")
    func dataIsTheIdentityCodec() async throws {
        let rig = ConnectionRig()
        rig.connect()

        let bytes = try await rig.connection.read(rawMeasurement)

        #expect(bytes == Data([0x01]))
    }

    @Test("integers decode little-endian")
    func integersAreLittleEndian() async throws {
        // The Core Specification transmits multi-octet fields least-significant octet first,
        // so [0x2C, 0x01] is 300 and not 11265.
        let uuid = CBUUID(string: "2A1C")
        let rig = ConnectionRig(gatt: [
            FakeService(uuid: TestUUID.heartRateService, characteristics: [
                FakeCharacteristic(uuid: uuid, value: Data([0x2C, 0x01]), properties: [.read])
            ])
        ])
        rig.connect()

        let value = try await rig.connection.read(Characteristic<UInt16>(uuid))

        #expect(value == 300)
    }

    @Test("a string decodes as UTF-8")
    func stringsDecodeUTF8() async throws {
        let uuid = CBUUID(string: "2A00")
        let rig = ConnectionRig(gatt: [
            FakeService(uuid: TestUUID.heartRateService, characteristics: [
                FakeCharacteristic(uuid: uuid, value: Data("Sensor".utf8), properties: [.read])
            ])
        ])
        rig.connect()

        let name = try await rig.connection.read(Characteristic<String>(uuid))

        #expect(name == "Sensor")
    }

    // MARK: Decoding failures

    @Test("a width mismatch is decodingFailed, not a read failure")
    func widthMismatchIsDecodingFailed() async {
        // The battery level is one byte. Asking for two is a disagreement about the protocol,
        // and the distinction matters: the read itself succeeded.
        let rig = ConnectionRig()
        rig.connect()

        let thrown = await errorThrown {
            try await rig.connection.read(Characteristic<UInt16>(TestUUID.batteryLevel))
        }

        #expect(thrown == .decodingFailed(TestUUID.batteryLevel))
    }

    @Test("the underlying decoding error is carried, not swallowed")
    func underlyingErrorSurvives() async throws {
        let rig = ConnectionRig()
        rig.connect()

        var caught: Error?
        do {
            _ = try await rig.connection.read(Characteristic<UInt16>(TestUUID.batteryLevel))
        } catch {
            caught = error
        }

        guard case .decodingFailed(_, let underlying)? = caught as? BluetoothError else {
            Issue.record("expected decodingFailed, got \(String(describing: caught))")
            return
        }
        #expect(underlying as? CharacteristicDecodingError == .unexpectedLength(expected: 2, actual: 1))
    }

    @Test("invalid UTF-8 is rejected rather than replaced")
    func invalidUTF8IsRejected() async {
        let uuid = CBUUID(string: "2A00")
        let rig = ConnectionRig(gatt: [
            FakeService(uuid: TestUUID.heartRateService, characteristics: [
                FakeCharacteristic(uuid: uuid, value: Data([0xFF, 0xFE]), properties: [.read])
            ])
        ])
        rig.connect()

        let thrown = await errorThrown {
            try await rig.connection.read(Characteristic<String>(uuid))
        }

        #expect(thrown == .decodingFailed(uuid))
    }

    // MARK: Writing

    @Test("a typed write encodes little-endian and reaches the radio as bytes")
    func typedWriteEncodes() async throws {
        let rig = ConnectionRig()
        rig.connect()

        try await rig.connection.write(UInt16(300), to: Characteristic<UInt16>(TestUUID.controlPoint))

        #expect(rig.peripheralCalls.contains(
            .write(Data([0x2C, 0x01]), characteristic: TestUUID.controlPoint, mode: .withResponse)
        ))
    }

    @Test("a typed write honours the write mode")
    func typedWriteHonoursMode() async throws {
        let rig = ConnectionRig()
        rig.connect()

        try await rig.connection.write(
            UInt8(1),
            to: Characteristic<UInt8>(TestUUID.controlPoint),
            mode: .withoutResponse
        )

        #expect(rig.peripheralCalls.contains(
            .write(Data([0x01]), characteristic: TestUUID.controlPoint, mode: .withoutResponse)
        ))
    }

    // MARK: Notifications

    @Test("typed notifications decode every value")
    func typedNotificationsDecode() async throws {
        let rig = ConnectionRig()
        rig.connect()

        let stream = try await rig.connection.notifications(for: Characteristic<UInt8>(TestUUID.measurement))
        var values = stream.makeAsyncIterator()
        rig.notify(Data([0x5A]), from: TestUUID.measurement)

        let value = try await values.next()

        #expect(value == 0x5A)
    }

    @Test("a value that cannot be decoded ends the stream instead of being skipped")
    func undecodableNotificationEndsTheStream() async throws {
        // Dropping the packet would hide a protocol disagreement behind a stream that simply
        // goes quiet, which is the hardest kind of bug to see from the outside.
        let rig = ConnectionRig()
        rig.connect()

        let stream = try await rig.connection.notifications(for: Characteristic<UInt16>(TestUUID.measurement))
        var values = stream.makeAsyncIterator()
        rig.notify(Data([0x5A]), from: TestUUID.measurement)

        var thrown: ErrorKind?
        do {
            _ = try await values.next()
        } catch {
            thrown = error.kind
        }

        #expect(thrown == .decodingFailed(TestUUID.measurement))
    }

    // MARK: The handle

    @Test("handles are equal when their identifiers are")
    func handleEquality() {
        let one = Characteristic<UInt8>(TestUUID.batteryLevel)
        let two = Characteristic<UInt8>(CBUUID(string: "2A19"))

        #expect(one == two)
        #expect(Set([one, two]).count == 1)
    }

    @Test("a handle can be built from a UUID string")
    func handleFromString() {
        #expect(Characteristic<UInt8>("2A19").id == TestUUID.batteryLevel)
    }
}
