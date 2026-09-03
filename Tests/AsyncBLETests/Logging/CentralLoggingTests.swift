// Central-level events: the adapter, scanning, connect requests, and disconnectAll.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("Central logging")
struct CentralLoggingTests {
    @Test("an adapter state change is logged at notice")
    func adapterChange() {
        let rig = CentralRig(adapterState: .unavailable(.unknown), recording: true)
        rig.sync { rig.radio.emit(adapterState: .poweredOn) }

        #expect(
            rig.logRecorder!.contains(level: .notice, category: .central, messageContains: "adapter →")
        )
    }

    @Test("an unusable adapter is logged at error when it blocks a call")
    func unavailableAdapter() async {
        let rig = CentralRig(adapterState: .unavailable(.poweredOff), recording: true)

        _ = await errorThrown { _ = try await rig.central.connect(rig.peripheralID) }

        #expect(
            rig.logRecorder!.contains(
                level: .error, category: .central, messageContains: "bluetooth unavailable"
            )
        )
    }

    @Test("a connect request is logged")
    func connectRequest() async throws {
        let rig = CentralRig(recording: true)

        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await rig.completeConnect()
        _ = try await task.value

        #expect(
            rig.logRecorder!.contains(level: .info, category: .central, messageContains: "requested")
        )
    }

    @Test("connecting to an unknown identifier is logged at error")
    func unknownPeripheral() async {
        let rig = CentralRig(recording: true)

        _ = await errorThrown { _ = try await rig.central.connect(UUID()) }

        #expect(
            rig.logRecorder!.contains(
                level: .error, category: .central, messageContains: "no peripheral with this identifier"
            )
        )
    }

    @Test("disconnectAll is logged with a count")
    func disconnectAll() async throws {
        let rig = CentralRig(recording: true)
        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await rig.completeConnect()
        _ = try await task.value

        await rig.central.disconnectAll()

        #expect(
            rig.logRecorder!.contains(
                level: .notice, category: .central, messageContains: "disconnecting all 1"
            )
        )
    }

    @Test("scanning logs the request and the radio start")
    func scanning() async throws {
        let rig = CentralRig(recording: true)

        _ = try await rig.central.scan(services: [CBUUID(string: "180D")])

        let recorder = rig.logRecorder!
        #expect(recorder.contains(level: .notice, category: .central, messageContains: "scan requested"))
        #expect(recorder.contains(level: .notice, category: .central, messageContains: "radio scan started"))
    }
}
