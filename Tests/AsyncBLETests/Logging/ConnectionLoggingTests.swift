// Logging is an observer of the state machine, not a change to it. These drive a connection
// through the transitions that matter and assert the library said what happened.

import Testing

@testable import AsyncBLE

@Suite("Connection logging")
struct ConnectionLoggingTests {
    @Test("the connect handshake is logged")
    func connectHandshake() {
        let rig = ConnectionRig(recording: true)
        rig.connect()

        let connection = rig.logRecorder!.records(in: .connection)
        #expect(connection.contains { $0.message.contains("--connectRequested") })
        #expect(connection.contains { $0.message.contains("--> connected") })
    }

    @Test("a link drop is logged at notice as a reconnect")
    func linkDrop() {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        rig.dropLink()

        #expect(rig.state == .reconnecting(attempt: 1))
        #expect(
            rig.logRecorder!.contains(level: .notice, category: .connection, messageContains: "reconnecting")
        )
    }

    @Test("a user disconnect is logged at notice as terminal")
    func userDisconnect() async {
        let rig = ConnectionRig(recording: true)
        rig.connect()
        await rig.connection.disconnect()

        #expect(
            rig.logRecorder!.contains(level: .notice, category: .connection, messageContains: "disconnected")
        )
    }

    @Test("the give-up deadline is logged when armed and when it fires")
    func giveUpDeadline() {
        let rig = ConnectionRig(policy: .giveUp(after: .seconds(120)), recording: true)
        rig.connect()
        rig.dropLink()

        #expect(
            rig.logRecorder!.contains(level: .notice, category: .reconnect, messageContains: "giving up after")
        )

        rig.sync { rig.scheduler.advance(by: .seconds(120)) }

        #expect(rig.state == .disconnected(reason: .reconnectGaveUp))
        #expect(
            rig.logRecorder!.contains(level: .notice, category: .reconnect, messageContains: "deadline reached")
        )
    }

    @Test("re-arming the pending connect is logged")
    func reArmCadence() {
        let rig = ConnectionRig(
            policy: .waitIndefinitely(reArmEvery: .seconds(30)),
            recording: true
        )
        rig.connect()
        rig.dropLink()
        rig.sync { rig.scheduler.advance(by: .seconds(30)) }

        #expect(
            rig.logRecorder!.contains(level: .info, category: .reconnect, messageContains: "re-arming")
        )
    }

    @Test("a failed subscription restore is logged at error")
    func failedRestore() async throws {
        let rig = ConnectionRig(recording: true)
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
        _ = await errorThrown { try await values.next() }

        #expect(
            rig.logRecorder!.contains(
                level: .error, category: .reconnect, messageContains: "subscription restore failed"
            )
        )
    }

    @Test("in-flight I/O failed by a drop is logged")
    func inFlightIOFailure() async {
        let rig = ConnectionRig(responseMode: .queued, recording: true)
        rig.connect()

        let read = Task { try await rig.connection.read(TestUUID.measurement) }
        await waitUntil { rig.sync { rig.peripheral.hasPendingResponses } }
        rig.dropLink()
        _ = try? await read.value

        #expect(
            rig.logRecorder!.contains(level: .info, category: .io, messageContains: "failing in-flight I/O")
        )
    }

    @Test("transition records carry the peripheral identifier as metadata")
    func metadata() {
        let rig = ConnectionRig(recording: true)
        rig.connect()

        let id = rig.peripheral.identifier.uuidString
        let transitions = rig.logRecorder!.records(in: .connection).filter { $0.message.contains("-->") }
        #expect(!transitions.isEmpty)
        #expect(transitions.allSatisfy { $0.metadata["peripheral"] == id })
    }
}
