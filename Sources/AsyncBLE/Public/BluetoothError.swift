// The single public error type (PLAN.md §3).
//
// `CBUUID` is the one CoreBluetooth type allowed in the public API: a value type with no
// behavior, used as the characteristic identifier. Document that exception on the case.

@preconcurrency import CoreBluetooth

/// Why the Bluetooth adapter cannot be used.
///
/// Mirrors the unusable cases of `CBManagerState`. `poweredOn` has no representation here
/// because it is not a failure — see ``AdapterState`` for the observable form that includes it.
public enum UnavailableReason: Sendable, Equatable {
    /// Bluetooth is switched off. The user can fix this in Settings or Control Center.
    case poweredOff

    /// The app is not authorized to use Bluetooth.
    ///
    /// Either the user declined the permission prompt, or `NSBluetoothAlwaysUsageDescription`
    /// is missing from the app's `Info.plist` — in which case the prompt never appeared.
    case unauthorized

    /// This device has no Bluetooth Low Energy support.
    case unsupported

    /// The connection to the system Bluetooth service was momentarily lost.
    ///
    /// Transient: the adapter usually returns on its own, so this is a state to wait through
    /// rather than report to the user.
    case resetting

    /// The adapter state is not yet known.
    ///
    /// A freshly created central starts here and leaves within milliseconds. The library only
    /// surfaces this if it is asked to act before the adapter has reported in.
    case unknown
}

/// Every error this library throws.
///
/// One error type, so a single `catch` covers the API. Underlying CoreBluetooth errors are
/// carried rather than swallowed — inspect them when you need the vendor-specific detail.
public enum BluetoothError: Error, Sendable {
    /// The Bluetooth adapter is unusable.
    ///
    /// Observe ``Central/adapterStates`` to learn when it becomes usable again.
    case bluetoothUnavailable(reason: UnavailableReason)

    /// The connect attempt exceeded ``Central/Configuration/connectTimeout``.
    ///
    /// The pending CoreBluetooth connect request is cancelled before this is thrown, so no
    /// late connection can arrive afterwards. Only ``Central/connect(_:timeout:)-(UUID,_)`` throws this;
    /// ``Central/connectWhenAvailable(_:)`` has no deadline by design.
    case connectTimeout

    /// CoreBluetooth refused or failed the connect attempt.
    ///
    /// - Parameter underlying: The error CoreBluetooth reported, if it reported one.
    case connectionFailed(underlying: Error?)

    /// The operation could not complete because the link ended.
    ///
    /// Thrown from in-flight reads and writes when the connection drops under them, and from a
    /// notification stream whose subscription cannot be restored.
    case disconnected(reason: DisconnectReason)

    /// No characteristic with this UUID exists on the connected peripheral.
    ///
    /// Raised by lazy discovery: the library walked the peripheral's services and did not
    /// find it. A stale UUID, or a peripheral that came back from a reconnect in a different
    /// firmware mode, are the usual causes.
    ///
    /// `CBUUID` is the single CoreBluetooth type permitted in this library's public API
    /// (PLAN.md §3): it is an immutable value type with no behavior, and wrapping it would
    /// add friction without adding safety.
    case characteristicNotFound(CBUUID)

    /// The characteristic does not support the requested operation.
    ///
    /// For example subscribing to a characteristic whose properties include neither `notify`
    /// nor `indicate`, or writing to one that is read-only.
    ///
    /// Raised before the request reaches the radio, by checking the characteristic's declared
    /// properties. Contrast ``operationFailed(underlying:)``, which is the peripheral refusing
    /// something it advertised as supported.
    case operationNotSupported

    /// The peripheral refused an operation, or it failed on the wire.
    ///
    /// Thrown by ``Connection/read(_:)``, ``Connection/write(_:to:mode:)`` and
    /// ``Connection/notifications(for:bufferingPolicy:)`` when CoreBluetooth reports an error
    /// against a request the library had already issued — an ATT error such as insufficient
    /// authentication or an application-defined error code from the peripheral's own firmware.
    ///
    /// The link is still up: this says the operation failed, not that the connection did.
    ///
    /// - Parameter underlying: The error CoreBluetooth reported. For an ATT failure this is a
    ///   `CBATTError`, whose code carries the peripheral's reason.
    case operationFailed(underlying: Error?)
}
