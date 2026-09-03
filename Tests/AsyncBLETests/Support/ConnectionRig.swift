// A whole connection, wired to fakes: bridge, engine, actor, and a clock the test owns.
//
// Phase 2f gives `Central` the job of assembling this. Until then the rig does it, which is
// also what keeps these tests about the connection rather than about the registry.

@preconcurrency import CoreBluetooth
import Foundation

@testable import AsyncBLE

/// A connection under test, plus everything it was built from.
final class ConnectionRig: @unchecked Sendable {
    let library = LibraryQueue(label: "test.connection")
    let scheduler = TestScheduler()
    let central: FakeCentral
    let peripheral: FakePeripheral
    let bridge: CentralDelegateBridge
    let core: ConnectionCore
    let connection: Connection

    /// The log handler, when the rig was built with `recording:`. Assert on `.records`.
    let logRecorder: RecordingLogHandler?

    init(
        policy: ReconnectPolicy = .waitIndefinitely(),
        gatt: [FakeService]? = nil,
        responseMode: FakePeripheral.ResponseMode = .immediate,
        recording: Bool = false
    ) {
        let recorder = recording ? RecordingLogHandler() : nil
        logRecorder = recorder
        let log = recorder.map { LogFacility.recording($0) } ?? .disabled

        central = FakeCentral()
        peripheral = FakePeripheral(gatt: gatt ?? ConnectionRig.defaultGATT())
        peripheral.responseMode = responseMode
        central.knownPeripherals[peripheral.identifier] = peripheral
        bridge = CentralDelegateBridge(seam: central, library: library)
        core = ConnectionCore(
            peripheral: peripheral,
            bridge: bridge,
            library: library,
            scheduler: scheduler,
            policy: policy,
            log: log
        )
        connection = Connection(core: core)
        library.sync { bridge.register(core) }
    }

    /// The records the library has logged so far. Empty unless the rig was built with
    /// `recording: true`.
    var logRecords: [LogRecord] { logRecorder?.records ?? [] }

    /// A heart-rate service and a battery service, which is enough shape for any test here.
    static func defaultGATT() -> [FakeService] {
        [
            FakeService(uuid: TestUUID.heartRateService, characteristics: [
                FakeCharacteristic(uuid: TestUUID.measurement, value: Data([0x01])),
                FakeCharacteristic(uuid: TestUUID.controlPoint, properties: [.write, .writeWithoutResponse])
            ]),
            FakeService(uuid: TestUUID.batteryService, characteristics: [
                FakeCharacteristic(uuid: TestUUID.batteryLevel, value: Data([0x64]), properties: [.read])
            ])
        ]
    }

    /// Runs on the library queue, where the engine expects its callers.
    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        try library.sync(body)
    }

    // MARK: Driving the link

    /// Brings the link up the way `Central` will: ask, then have the radio report success.
    func connect(timeout: Duration? = .seconds(10)) {
        sync {
            core.requestConnect(timeout: timeout)
            central.emitConnect(peripheral)
        }
    }

    /// Drops the link, as a peripheral walking out of range would.
    func dropLink() {
        sync { central.emitDisconnect(peripheral, error: cbFailure) }
    }

    /// Brings a dropped link back.
    func relink() {
        sync { central.emitConnect(peripheral) }
    }

    /// Reports the adapter changing state.
    func setAdapter(_ state: AdapterState) {
        sync { central.emit(adapterState: state) }
    }

    /// Delivers whatever the peripheral has parked, on the library queue.
    func flush() {
        sync { peripheral.flush() }
    }

    /// The connection's state, read from the engine.
    var state: ConnectionState {
        sync { core.state }
    }

    /// The calls the library made to the peripheral.
    var peripheralCalls: [FakePeripheral.Call] {
        sync { peripheral.calls }
    }

    /// Pushes a notification from a characteristic, by UUID.
    func notify(_ data: Data, from uuid: CBUUID) {
        sync {
            guard let characteristic = peripheral.gatt
                .flatMap(\.all)
                .first(where: { $0.uuid == uuid })
            else { return }
            peripheral.emitNotification(data, for: characteristic)
        }
    }
}

/// The UUIDs the connection tests share.
enum TestUUID {
    static let heartRateService = CBUUID(string: "180D")
    static let measurement = CBUUID(string: "2A37")
    static let controlPoint = CBUUID(string: "2A39")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    static let absent = CBUUID(string: "2A00")
}

/// Spins until a condition holds, yielding between checks.
///
/// Tests drive an actor from outside its executor, so "has the operation reached the radio yet?"
/// is a question with a real answer and no synchronous way to ask it. Bounded, so a test that
/// will never pass fails rather than hangs.
@discardableResult
func waitUntil(_ condition: @escaping () -> Bool, attempts: Int = 500) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
