// Internal protocols over CBCentralManager / CBPeripheral, so the bridge, discovery cache,
// write queue and reconnect path can be driven by fakes.
//
// Deliberately `internal`: this is not the public mock-injection abstraction, which stays on
// a later milestone. It exists so the risky 70% of the library has automated coverage without
// taking a dependency that would put CBM* typealiases through the production source.
//
// Shape notes:
//   - Only what the library actually calls. This is a seam, not a re-declaration of
//     CoreBluetooth: anything not needed is not here, and adding to it should hurt slightly.
//   - Errors are `NSError?`, matching `ConnectionEvent`. CoreBluetooth's errors are all
//     NSError, and `any Error` is neither Sendable nor Equatable.
//   - Everything is `Sendable` by queue confinement, not by construction: every conformer is
//     `@unchecked Sendable` and may only be touched on the library queue. The custom serial
//     executor in `LibraryQueue` is what makes that true rather than hoped-for.

@preconcurrency import CoreBluetooth
import Foundation

// MARK: - The managers

/// What this library needs from `CBCentralManager`.
protocol CentralSeam: AnyObject, Sendable {
    /// Who receives the manager's callbacks. Held weakly by conformers.
    var seamDelegate: CentralSeamDelegate? { get set }

    /// The adapter's availability, already mapped out of `CBManagerState`.
    var adapterState: AdapterState { get }

    /// Starts scanning. Calling it again replaces the previous scan, as CoreBluetooth does.
    func scanForPeripherals(services: [CBUUID]?, allowDuplicates: Bool)

    /// Stops scanning. Safe to call when no scan is running.
    func stopScan()

    /// Looks up a peripheral the system already knows about, by identifier.
    ///
    /// This is what makes `connectWhenInRange(_:)` work without a scan: a peripheral seen in
    /// an earlier session can be retrieved and connected directly.
    func peripheral(withID id: UUID) -> PeripheralSeam?

    /// Arms a connect request. CoreBluetooth keeps it pending until it succeeds or is
    /// cancelled — there is no timeout, which is the whole reason this library exists.
    func connect(_ peripheral: PeripheralSeam)

    /// Closes a link, or withdraws a pending connect. CoreBluetooth uses one call for both.
    func cancelConnection(_ peripheral: PeripheralSeam)

    /// The manager itself, for the escape hatch. `nil` behind a fake, which has none.
    var rawCentral: CBCentralManager? { get }
}

/// What this library needs from `CBPeripheral`.
protocol PeripheralSeam: AnyObject, Sendable {
    /// The peripheral's per-app identifier — not a MAC address, which iOS never exposes.
    var identifier: UUID { get }

    /// The peripheral's advertised or cached name.
    var name: String? { get }

    /// Whether the radio currently has a link to this peripheral.
    ///
    /// Read in exactly one place: state restoration, which is handed peripherals rather than
    /// events and has to tell a live link from a pending connect the OS is still holding. Every
    /// other path in the library learns its state from the callbacks instead, which is why this
    /// is not a general-purpose accessor.
    var linkState: PeripheralLinkState { get }

    /// Who receives this peripheral's callbacks. Held weakly by conformers.
    var seamDelegate: PeripheralSeamDelegate? { get set }

    /// Whether a write-without-response can be handed to the radio right now.
    ///
    /// The flow control behind `WriteMode.withoutResponse`: when this is `false`, a write is
    /// dropped on the floor rather than queued, so the library waits for
    /// ``PeripheralSeamDelegate/peripheralSeamIsReadyForWriteWithoutResponse(_:)`` instead.
    var canSendWriteWithoutResponse: Bool { get }

    /// The services discovered so far. Empty until discovery has run.
    var services: [ServiceSeam] { get }

    /// Starts service discovery. Answers arrive on the delegate.
    func discoverServices(_ uuids: [CBUUID]?)

    /// Starts characteristic discovery within one service.
    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: ServiceSeam)

    /// Starts a read. The value arrives on the delegate, not as a return value.
    func readValue(for characteristic: CharacteristicSeam)

    /// Starts a write. Only ``Connection/WriteMode/withResponse`` produces a callback.
    func writeValue(_ data: Data, for characteristic: CharacteristicSeam, mode: Connection.WriteMode)

    /// Subscribes or unsubscribes. Confirmation arrives on the delegate.
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicSeam)

    /// The largest value that fits in one write of the given mode.
    func maximumWriteValueLength(for mode: Connection.WriteMode) -> Int

    /// The peripheral itself, for the escape hatch. `nil` behind a fake, which has none.
    var rawPeripheral: CBPeripheral? { get }
}

/// Where a peripheral's link stands, as `CBPeripheralState` without the `disconnecting` case.
///
/// CoreBluetooth's `disconnecting` is folded into ``disconnected``: it means a cancel is in
/// flight, and for the one question this enum answers — is there a link to adopt? — the answer
/// is the same.
enum PeripheralLinkState: Sendable, Equatable {
    /// The link is up.
    case connected

    /// A connect request is armed and the OS is holding it.
    case connecting

    /// No link and no request.
    case disconnected
}

/// What this library needs from `CBService`.
protocol ServiceSeam: AnyObject, Sendable {
    /// The service's UUID.
    var uuid: CBUUID { get }

    /// The characteristics discovered so far. Empty until discovery has run.
    var characteristics: [CharacteristicSeam] { get }
}

/// What this library needs from `CBCharacteristic`.
protocol CharacteristicSeam: AnyObject, Sendable {
    /// The characteristic's UUID.
    var uuid: CBUUID { get }

    /// The most recently read or notified value.
    ///
    /// CoreBluetooth delivers values by mutating the characteristic and then calling the
    /// delegate, rather than passing the bytes — so a read is "await the callback, then take
    /// this".
    var value: Data? { get }

    /// What the characteristic supports. Checked before subscribing or writing, so an
    /// unsupported operation fails as ``BluetoothError/operationNotSupported`` rather than
    /// hanging on a callback that will never come.
    var properties: CBCharacteristicProperties { get }

    /// Whether a subscription is currently active.
    var isNotifying: Bool { get }
}

// MARK: - The callbacks

/// The central manager's callbacks, in the library's own vocabulary.
protocol CentralSeamDelegate: AnyObject, Sendable {
    /// The adapter's availability changed. Read it from ``CentralSeam/adapterState``.
    func centralSeamDidUpdateAdapterState(_ seam: CentralSeam)

    /// A peripheral advertised.
    ///
    /// - Parameter rssi: Signal strength in dBm, or `nil` when CoreBluetooth reported its
    ///   `127` sentinel meaning "no reading".
    func centralSeam(
        _ seam: CentralSeam,
        didDiscover peripheral: PeripheralSeam,
        advertisement: AdvertisementData,
        rssi: Int?
    )

    /// A link came up.
    func centralSeam(_ seam: CentralSeam, didConnect peripheral: PeripheralSeam)

    /// A connect attempt failed outright.
    func centralSeam(_ seam: CentralSeam, didFailToConnect peripheral: PeripheralSeam, error: NSError?)

    /// A link ended — whether the peripheral walked away or the library asked for it.
    func centralSeam(_ seam: CentralSeam, didDisconnect peripheral: PeripheralSeam, error: NSError?)

    /// iOS relaunched the app and is handing back what this central was doing when it was
    /// terminated.
    ///
    /// Arrives before any other callback, including the adapter's first state — so a conformer
    /// that is not wired up yet has to buffer rather than drop.
    ///
    /// - Parameters:
    ///   - peripherals: The peripherals restored. Each carries its own ``PeripheralSeam/linkState``:
    ///     a live link, or a pending connect the OS kept holding.
    ///   - wasScanning: Whether a scan was running when the app was terminated. The library has
    ///     no session behind a restored scan, so it stops it.
    func centralSeam(_ seam: CentralSeam, willRestore peripherals: [PeripheralSeam], wasScanning: Bool)
}

/// The peripheral's callbacks, in the library's own vocabulary.
protocol PeripheralSeamDelegate: AnyObject, Sendable {
    /// Service discovery finished, successfully or not.
    func peripheralSeam(_ seam: PeripheralSeam, didDiscoverServices error: NSError?)

    /// Characteristic discovery finished for one service.
    func peripheralSeam(_ seam: PeripheralSeam, didDiscoverCharacteristicsFor service: ServiceSeam, error: NSError?)

    /// A read completed, or a notification arrived — CoreBluetooth uses one callback for both.
    func peripheralSeam(_ seam: PeripheralSeam, didUpdateValueFor characteristic: CharacteristicSeam, error: NSError?)

    /// A write-with-response completed.
    func peripheralSeam(_ seam: PeripheralSeam, didWriteValueFor characteristic: CharacteristicSeam, error: NSError?)

    /// A subscription was established or torn down.
    func peripheralSeam(
        _ seam: PeripheralSeam,
        didUpdateNotificationStateFor characteristic: CharacteristicSeam,
        error: NSError?
    )

    /// The radio has room for another write-without-response.
    func peripheralSeamIsReadyForWriteWithoutResponse(_ seam: PeripheralSeam)
}
