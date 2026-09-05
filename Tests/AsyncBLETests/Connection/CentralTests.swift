// The central: waiting for the adapter, one connection per peripheral, and the cancellation
// rules that go with them.

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

/// A central over the fakes, with a clock the test owns.
final class CentralRig: @unchecked Sendable {
    let library = LibraryQueue(label: "test.central")
    let scheduler = TestScheduler()
    let radio: FakeCentral
    let peripheral: FakePeripheral
    let central: Central

    /// The log handler, when the rig was built with `recording: true`.
    let logRecorder: RecordingLogHandler?

    init(
        configuration: Central.Configuration = Central.Configuration(),
        adapterState: AdapterState = .poweredOn,
        recording: Bool = false
    ) {
        let recorder = recording ? RecordingLogHandler() : nil
        logRecorder = recorder
        let log = recorder.map { LogFacility.recording($0) } ?? .disabled

        radio = FakeCentral(adapterState: adapterState)
        peripheral = FakePeripheral(gatt: ConnectionRig.defaultGATT())
        peripheral.responseMode = .immediate
        radio.knownPeripherals[peripheral.identifier] = peripheral
        central = Central(
            configuration: configuration, seam: radio, library: library, scheduler: scheduler, logFacility: log
        )
    }

    /// The records the library has logged so far.
    var logRecords: [LogRecord] { logRecorder?.records ?? [] }

    var peripheralID: UUID { peripheral.identifier }

    /// Registers a second peripheral the central can also connect to.
    @discardableResult
    func addPeripheral() -> FakePeripheral {
        let extra = FakePeripheral(gatt: ConnectionRig.defaultGATT())
        extra.responseMode = .immediate
        sync { radio.knownPeripherals[extra.identifier] = extra }
        return extra
    }

    /// Connects to one specific peripheral and waits for it to land.
    func connect(to target: FakePeripheral) async throws -> Connection {
        let task = Task { try await central.connect(target.identifier) }
        await waitUntil {
            self.sync { self.central.registry.connection(for: target.identifier)?.core.state } == .connecting
        }
        sync { radio.emitConnect(target) }
        return try await task.value
    }

    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        try library.sync(body)
    }

    /// The engine behind the connection this central is holding, if any.
    var core: ConnectionCore? {
        sync { central.registry.connection(for: peripheralID)?.core }
    }

    /// Waits for an attempt to actually be in flight, then reports the link as up.
    ///
    /// Keyed on the connection's state rather than on the radio's call log: a test that connects
    /// twice would otherwise see the *first* attempt's call and answer before the second was
    /// even armed.
    func completeConnect() async {
        await waitUntil { self.core?.state == .connecting }
        sync { radio.emitConnect(peripheral) }
    }
}

@Suite("Central: the adapter")
struct CentralAdapterTests {
    @Test("scanning waits for the adapter's first definitive state")
    func scanWaitsForTheAdapter() async throws {
        // A freshly created central reports `unknown` for a few milliseconds,
        // and failing during that window would make every app's first call a coin toss.
        let rig = CentralRig(adapterState: .unavailable(reason: .unknown))
        let scan = Task { try await rig.central.scan() }

        await waitUntil { rig.sync { rig.radio.calls.isEmpty } == false || true }
        rig.sync { rig.radio.emit(adapterState: .poweredOn) }

        let stream = try await scan.value
        #expect(rig.sync { rig.radio.calls } == [.scan(services: nil, allowDuplicates: false)])
        withExtendedLifetime(stream) {}
    }

    @Test("scanning with the adapter off throws, and says which off")
    func scanThrowsWhenUnavailable() async {
        let rig = CentralRig(adapterState: .unavailable(reason: .poweredOff))

        let thrown = await errorThrown { try await rig.central.scan() }

        #expect(thrown == .bluetoothUnavailable(reason: .poweredOff))
        #expect(rig.sync { rig.radio.calls }.isEmpty)
    }

    @Test("connecting with the adapter off throws before anything is armed")
    func connectThrowsWhenUnavailable() async {
        let rig = CentralRig(adapterState: .unavailable(reason: .unauthorized))

        let thrown = await errorThrown { try await rig.central.connect(rig.peripheralID) }

        #expect(thrown == .bluetoothUnavailable(reason: .unauthorized))
        #expect(rig.sync { rig.radio.calls }.isEmpty)
    }

    @Test("the adapter stream is readable straight from the central")
    func adapterStatesStream() async {
        let rig = CentralRig(adapterState: .unavailable(reason: .unknown))
        var states = rig.central.adapterStates.makeAsyncIterator()

        let first = await states.next()
        rig.sync { rig.radio.emit(adapterState: .poweredOn) }
        let second = await states.next()

        #expect(first == .unavailable(reason: .unknown))
        #expect(second == .poweredOn)
    }
}

@Suite("Central: connecting")
struct CentralConnectTests {
    @Test("a connect returns once the link is up")
    func connectSucceeds() async throws {
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID) }

        await rig.completeConnect()

        let connection = try await task.value
        #expect(connection.peripheralID == rig.peripheralID)
        #expect(await connection.state == .connected)
    }

    @Test("a peripheral CoreBluetooth has never heard of cannot be connected to")
    func unknownPeripheral() async {
        let rig = CentralRig()

        let thrown = await errorThrown { try await rig.central.connect(UUID()) }

        #expect(thrown == .connectionFailed)
    }

    @Test("two callers coalesce onto one attempt and get the same connection")
    func connectsCoalesce() async throws {
        // A link is device-wide, so there is one attempt and one object.
        let rig = CentralRig()
        let first = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1 }
        let second = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.core?.hasConnectWaiters == true && rig.sync { rig.central.registry.count } == 1 }

        rig.sync { rig.radio.emitConnect(rig.peripheral) }

        let firstConnection = try await first.value
        let secondConnection = try await second.value
        #expect(firstConnection === secondConnection)
        #expect(rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1)
    }

    @Test("connecting to an already-connected peripheral returns the live connection")
    func connectWhenAlreadyConnected() async throws {
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await rig.completeConnect()
        let connection = try await task.value
        rig.sync { rig.radio.clearCalls() }

        let again = try await rig.central.connect(rig.peripheralID)

        #expect(again === connection)
        #expect(rig.sync { rig.radio.calls }.isEmpty)
    }

    @Test("an attempt that runs out of time throws and withdraws the request")
    func connectTimesOut() async {
        // The headline fix. CoreBluetooth would have stayed pending forever.
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID, timeout: .seconds(5)) }
        await waitUntil { rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1 }

        rig.sync { rig.scheduler.advance(by: .seconds(5)) }

        #expect(await errorThrown { try await task.value } == .connectTimeout)
        #expect(rig.sync { rig.radio.calls }.contains(.cancelConnection(rig.peripheralID)))
    }

    @Test("connectWhenInRange has no deadline to run out")
    func pendingConnectHasNoDeadline() async {
        let rig = CentralRig()
        let task = Task { try await rig.central.connectWhenInRange(rig.peripheralID) }
        await waitUntil { rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1 }

        rig.sync { rig.scheduler.advance(by: .seconds(3600)) }
        #expect(rig.core?.state == .connecting)

        rig.sync { rig.radio.emitConnect(rig.peripheral) }
        let connection = try? await task.value
        #expect(connection != nil)
    }

    @Test("a failed attempt reports what CoreBluetooth said")
    func connectFails() async {
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1 }

        rig.sync { rig.radio.emitFailToConnect(rig.peripheral) }

        #expect(await errorThrown { try await task.value } == .connectionFailed)
    }
}

@Suite("Central: cancellation and lifetime")
struct CentralLifetimeTests {
    @Test("one caller cancelling leaves the attempt running for the other")
    func oneCancellationDoesNotEndTheAttempt() async throws {
        // This refcounts the attempt, which is safe precisely because an
        // in-flight attempt has no device-wide effect until it succeeds.
        let rig = CentralRig()
        let staying = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.sync { rig.radio.connectCount(for: rig.peripheralID) } == 1 }
        let leaving = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.core?.hasConnectWaiters == true }

        leaving.cancel()
        _ = await leaving.result
        #expect(rig.sync { rig.radio.calls }.contains(.cancelConnection(rig.peripheralID)) == false)

        rig.sync { rig.radio.emitConnect(rig.peripheral) }
        let connection = try await staying.value
        #expect(await connection.state == .connected)
    }

    @Test("the last caller cancelling withdraws the attempt")
    func lastCancellationWithdrawsTheAttempt() async {
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.core?.hasConnectWaiters == true }
        // Held explicitly: reaching terminal releases it from the registry, which is the other
        // half of what this test is checking.
        let core = rig.core

        task.cancel()
        _ = await task.result
        await waitUntil { rig.sync { rig.radio.calls }.contains(.cancelConnection(rig.peripheralID)) }

        #expect(rig.sync { rig.radio.calls }.contains(.cancelConnection(rig.peripheralID)))
        #expect(core?.state == .disconnected(reason: .userInitiated))
        #expect(rig.sync { rig.central.registry.count } == 0)
    }

    @Test("a link that lands after the last caller left is closed immediately")
    func orphanedLinkIsClosed() async {
        // The race in Q10: the attempt was withdrawn and CoreBluetooth landed it anyway. Nobody
        // holds it, and by Q9 nobody ever would.
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await waitUntil { rig.core?.hasConnectWaiters == true }
        task.cancel()
        _ = await task.result
        await waitUntil { rig.sync { rig.central.registry.count } == 0 }
        rig.sync { rig.radio.clearCalls() }

        rig.sync { rig.radio.emitConnect(rig.peripheral) }

        #expect(rig.sync { rig.radio.calls } == [.cancelConnection(rig.peripheralID)])
    }

    @Test("the central holds a connection until it ends, then lets it go")
    func registryReleasesTerminalConnections() async throws {
        // Dropping the last app reference does not close a link; reaching
        // terminal `disconnected` is what releases it.
        let rig = CentralRig()
        let task = Task { try await rig.central.connect(rig.peripheralID) }
        await rig.completeConnect()
        let connection = try await task.value
        #expect(rig.sync { rig.central.registry.count } == 1)

        await connection.disconnect()

        #expect(rig.sync { rig.central.registry.count } == 0)
    }

    @Test("the inventory lists what the radio is actually holding")
    func activeConnectionsListsLinks() async throws {
        // The cost of links living until explicitly closed is that a link nobody closes stays
        // open. This is how an app finds one.
        let rig = CentralRig()
        let second = rig.addPeripheral()
        #expect(await rig.central.activeConnections.isEmpty)

        let first = try await rig.connect(to: rig.peripheral)
        let other = try await rig.connect(to: second)

        let listed = await rig.central.activeConnections
        #expect(listed.count == 2)
        #expect(Set(listed.map(\.peripheralID)) == [first.peripheralID, other.peripheralID])
    }

    @Test("the inventory is stable across calls")
    func activeConnectionsIsStable() async throws {
        let rig = CentralRig()
        rig.addPeripheral()
        _ = try await rig.connect(to: rig.peripheral)

        let firstRead = await rig.central.activeConnections.map(\.peripheralID)
        let secondRead = await rig.central.activeConnections.map(\.peripheralID)
        #expect(firstRead == secondRead)
    }

    @Test("a connection that has ended drops off the inventory")
    func endedConnectionsAreNotListed() async throws {
        let rig = CentralRig()
        let connection = try await rig.connect(to: rig.peripheral)

        await connection.disconnect()

        #expect(await rig.central.activeConnections.isEmpty)
    }

    @Test("disconnectAll closes every link it is holding")
    func disconnectAllClosesEverything() async throws {
        let rig = CentralRig()
        let second = rig.addPeripheral()
        let first = try await rig.connect(to: rig.peripheral)
        let other = try await rig.connect(to: second)

        await rig.central.disconnectAll()

        #expect(await first.state == .disconnected(reason: .userInitiated))
        #expect(await other.state == .disconnected(reason: .userInitiated))
        #expect(await rig.central.activeConnections.isEmpty)
        #expect(rig.sync { rig.radio.calls }.contains(.cancelConnection(first.peripheralID)))
        #expect(rig.sync { rig.radio.calls }.contains(.cancelConnection(other.peripheralID)))
    }

    @Test("disconnectAll with nothing to close is harmless")
    func disconnectAllOnAnEmptyCentral() async {
        let rig = CentralRig()

        await rig.central.disconnectAll()

        #expect(await rig.central.activeConnections.isEmpty)
    }

    @Test("a connection still waiting for its link is inventoried too")
    func pendingConnectionsAreListed() async throws {
        // It holds a pending CoreBluetooth request, so it is exactly the kind of thing an audit
        // is looking for.
        let rig = CentralRig()
        let task = Task { try await rig.central.connectWhenInRange(rig.peripheralID) }
        await waitUntil { rig.core?.state == .connecting }

        #expect(await rig.central.activeConnections.count == 1)

        task.cancel()
        _ = await task.result
    }

    @Test("a connection made again after one ended is a new one")
    func reconnectingAfterTerminalMakesANewConnection() async throws {
        let rig = CentralRig()
        let first = Task { try await rig.central.connect(rig.peripheralID) }
        await rig.completeConnect()
        let original = try await first.value
        await original.disconnect()

        let second = Task { try await rig.central.connect(rig.peripheralID) }
        await rig.completeConnect()
        let replacement = try await second.value

        #expect(original !== replacement)
        #expect(await replacement.state == .connected)
    }
}
