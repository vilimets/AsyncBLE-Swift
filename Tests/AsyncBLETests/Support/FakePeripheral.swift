// The peripheral side of the fakes: a scriptable GATT tree that answers discovery, reads,
// writes and subscriptions the way CoreBluetooth does — including the parts that make it
// awkward, which are the parts worth testing.
//
// Response timing is a first-class knob. CoreBluetooth never answers synchronously, so
// `.queued` is the default: a call records itself and parks its answer until the test flushes
// it. That is what lets a test hold two operations in flight at once and assert on the order
// they complete in, which is the whole point of the FIFO queue.

@preconcurrency import CoreBluetooth
import Foundation

@testable import AsyncBLE

/// `PeripheralSeam` with a scripted GATT tree instead of a radio.
final class FakePeripheral: PeripheralSeam, @unchecked Sendable {
    /// When the fake answers a call.
    enum ResponseMode {
        /// Park every answer until ``flush()``. The default, because CoreBluetooth is async and
        /// a test that only passes against a synchronous radio has proved nothing.
        case queued
        /// Answer inline, for tests where the callback timing is not what is under test.
        case immediate
    }

    /// Everything the library asked the peripheral to do, in order.
    enum Call: Equatable {
        case discoverServices([CBUUID]?)
        case discoverCharacteristics([CBUUID]?, service: CBUUID)
        case read(CBUUID)
        case write(Data, characteristic: CBUUID, mode: Connection.WriteMode)
        case setNotify(Bool, characteristic: CBUUID)
    }

    let identifier: UUID
    var name: String?
    weak var seamDelegate: PeripheralSeamDelegate?

    /// Where the link stands, as the radio would report it.
    ///
    /// Settable rather than derived from the emitted callbacks: restoration is handed a
    /// peripheral with no history behind it, and this is what a test uses to say "iOS gave this
    /// one back still connected".
    var linkState: PeripheralLinkState = .disconnected

    /// Whether the radio has room for a write-without-response. Set it `false` to park a write
    /// on flow control, then use ``reportReadyForWriteWithoutResponse()`` to let it go.
    var canSendWriteWithoutResponse = true

    /// The whole GATT tree, whether or not it has been discovered yet.
    ///
    /// Assigning replaces what a reconnect will find — which is how "the peripheral came back
    /// in a different firmware mode and the characteristic is gone" gets tested.
    var gatt: [FakeService] {
        didSet { discovered = [] }
    }

    var responseMode: ResponseMode = .queued

    /// An error to report instead of discovering services, for testing the failure path.
    var servicesDiscoveryError: NSError?

    private(set) var calls: [Call] = []
    private var discovered: [FakeService] = []
    private var pending: [() -> Void] = []

    /// The services discovery has revealed so far — empty until it runs, as CoreBluetooth's are.
    var services: [ServiceSeam] { discovered }

    /// No CoreBluetooth object behind a fake, so the escape hatch is unavailable here.
    let rawPeripheral: CBPeripheral? = nil

    init(identifier: UUID = UUID(), name: String? = "Fake", gatt: [FakeService] = []) {
        self.identifier = identifier
        self.name = name
        self.gatt = gatt
    }

    // MARK: PeripheralSeam

    func discoverServices(_ uuids: [CBUUID]?) {
        calls.append(.discoverServices(uuids))
        answer { [self] in
            guard servicesDiscoveryError == nil else {
                seamDelegate?.peripheralSeam(self, didDiscoverServices: servicesDiscoveryError)
                return
            }
            discovered = uuids.map { wanted in gatt.filter { wanted.contains($0.uuid) } } ?? gatt
            seamDelegate?.peripheralSeam(self, didDiscoverServices: nil)
        }
    }

    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: ServiceSeam) {
        calls.append(.discoverCharacteristics(uuids, service: service.uuid))
        guard let fake = service as? FakeService else { return }
        answer { [self] in
            if fake.discoveryError == nil {
                fake.revealCharacteristics(matching: uuids)
            }
            seamDelegate?.peripheralSeam(self, didDiscoverCharacteristicsFor: fake, error: fake.discoveryError)
        }
    }

    func readValue(for characteristic: CharacteristicSeam) {
        calls.append(.read(characteristic.uuid))
        guard let fake = characteristic as? FakeCharacteristic else { return }
        answer { [self] in
            fake.value = fake.storedValue
            seamDelegate?.peripheralSeam(self, didUpdateValueFor: fake, error: fake.readError)
        }
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicSeam, mode: Connection.WriteMode) {
        calls.append(.write(data, characteristic: characteristic.uuid, mode: mode))
        guard let fake = characteristic as? FakeCharacteristic else { return }
        fake.storedValue = data
        // Only a write-with-response is ever acknowledged; the other kind is fire-and-forget,
        // which is exactly why it needs flow control instead of a callback.
        guard mode == .withResponse else { return }
        answer { [self] in
            seamDelegate?.peripheralSeam(self, didWriteValueFor: fake, error: fake.writeError)
        }
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicSeam) {
        calls.append(.setNotify(enabled, characteristic: characteristic.uuid))
        guard let fake = characteristic as? FakeCharacteristic else { return }
        answer { [self] in
            fake.isNotifying = enabled && fake.notifyError == nil
            seamDelegate?.peripheralSeam(self, didUpdateNotificationStateFor: fake, error: fake.notifyError)
        }
    }

    func maximumWriteValueLength(for mode: Connection.WriteMode) -> Int {
        mode == .withResponse ? 512 : 182
    }

    // MARK: Synthetic callbacks

    /// Delivers every parked answer, including any parked while delivering.
    func flush() {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            next()
        }
    }

    /// Delivers exactly one parked answer, oldest first — for asserting completion order.
    func flushOne() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()()
    }

    /// Whether anything is still parked. A test that expects a call to be in flight can say so.
    var hasPendingResponses: Bool { !pending.isEmpty }

    /// Pushes a notification, as a subscribed characteristic would.
    func emitNotification(_ data: Data, for characteristic: FakeCharacteristic) {
        characteristic.value = data
        seamDelegate?.peripheralSeam(self, didUpdateValueFor: characteristic, error: nil)
    }

    /// Reports that the radio has room again, releasing a write parked on flow control.
    func reportReadyForWriteWithoutResponse() {
        canSendWriteWithoutResponse = true
        seamDelegate?.peripheralSeamIsReadyForWriteWithoutResponse(self)
    }

    /// Invalidates the discovered tree, as CoreBluetooth does on every disconnect.
    ///
    /// Called for you by ``FakeCentral/emitDisconnect(_:error:)``: a cache that survived a drop
    /// in a test would be hiding the bug the discovery cache exists to avoid.
    func linkDidDrop() {
        discovered = []
        pending.removeAll()
    }

    /// Forgets the call log.
    func clearCalls() {
        calls.removeAll()
    }

    private func answer(_ work: @escaping () -> Void) {
        switch responseMode {
        case .immediate: work()
        case .queued: pending.append(work)
        }
    }
}

/// `ServiceSeam` with a scripted characteristic list.
final class FakeService: ServiceSeam, @unchecked Sendable {
    let uuid: CBUUID

    /// Every characteristic this service has, discovered or not.
    let all: [FakeCharacteristic]

    /// An error to report instead of revealing them — one service in a tree failing to
    /// enumerate, which must not take the rest of the walk down with it.
    var discoveryError: NSError?

    private var revealed: [FakeCharacteristic] = []

    var characteristics: [CharacteristicSeam] { revealed }

    init(uuid: CBUUID, characteristics: [FakeCharacteristic]) {
        self.uuid = uuid
        all = characteristics
    }

    /// Convenience: a service holding one characteristic with default properties.
    convenience init(uuid: CBUUID, characteristic: CBUUID) {
        self.init(uuid: uuid, characteristics: [FakeCharacteristic(uuid: characteristic)])
    }

    fileprivate func revealCharacteristics(matching uuids: [CBUUID]?) {
        revealed = uuids.map { wanted in all.filter { wanted.contains($0.uuid) } } ?? all
    }
}

/// `CharacteristicSeam` whose answers and failures a test scripts up front.
final class FakeCharacteristic: CharacteristicSeam, @unchecked Sendable {
    let uuid: CBUUID
    var value: Data?
    var properties: CBCharacteristicProperties
    var isNotifying = false

    /// What a read returns. Writes update it, so "write a command, then read it back" works.
    var storedValue: Data?

    /// Failures to inject, each on the operation it names.
    var readError: NSError?
    var writeError: NSError?
    var notifyError: NSError?

    init(
        uuid: CBUUID,
        value: Data? = nil,
        properties: CBCharacteristicProperties = [.read, .write, .writeWithoutResponse, .notify]
    ) {
        self.uuid = uuid
        storedValue = value
        self.properties = properties
    }
}
