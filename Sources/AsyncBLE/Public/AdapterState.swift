// The observable form of adapter availability (PLAN.md §7, Q5/Q12).
//
// Composes over UnavailableReason rather than restating its cases, so the two cannot drift.

/// Whether the Bluetooth adapter can currently be used.
///
/// The library tracks this internally to know when a pending reconnect can be re-armed, so it
/// costs nothing to publish. Observe it through ``Central/adapterStates`` — without it, an app
/// whose ``Central/scan(_:)`` threw ``BluetoothError/bluetoothUnavailable(reason:)`` would have
/// no way to learn that Bluetooth came back, and would end up creating a second
/// `CBCentralManager` purely to render a "Bluetooth is off" banner.
public enum AdapterState: Sendable, Equatable {
    /// The adapter is on and usable. Scanning and connecting will work.
    case poweredOn

    /// The adapter cannot be used, for the given reason.
    ///
    /// - Parameter reason: Which unusable state the adapter is in. The same value that
    ///   ``BluetoothError/bluetoothUnavailable(reason:)`` would carry.
    case unavailable(UnavailableReason)
}
