// Tunables passed to `Central` at init: connect timeout, reconnect policy, power alert.
//
// `restoreIdentifier` is deliberately absent in 0.1.0 — it ships with the background milestone
// (PLAN.md §3: no config knobs that do nothing).

import Foundation

extension Central {
    /// Tunables for a ``Central``, fixed at initialization.
    ///
    /// There is deliberately no `restoreIdentifier` here. State restoration needs background
    /// modes to mean anything, and this library does not ship a knob that does nothing
    /// (PLAN.md §3).
    public struct Configuration: Sendable, Equatable {
        /// How long a connect attempt may run before it fails with
        /// ``BluetoothError/connectTimeout``.
        ///
        /// CoreBluetooth has no native connect timeout: `connect(_:options:)` stays pending
        /// indefinitely against a peripheral that is off or out of range. This library imposes
        /// one, which is the whole reason the setting exists.
        ///
        /// Applies to ``Central/connect(_:timeout:)`` only. Reconnection after a drop, and
        /// ``Central/connectWhenAvailable(_:)``, both deliberately rely on the OS keeping the
        /// request pending instead.
        public var connectTimeout: Duration

        /// How long to keep waiting after a link drops.
        ///
        /// Defaults to ``ReconnectPolicy/waitIndefinitely(reArmEvery:)``, because the OS holds
        /// the pending connect at no cost and a bounded default would mostly serve to give up
        /// on devices that were about to come back.
        public var reconnectPolicy: ReconnectPolicy

        /// Whether the system may show its "Turn On Bluetooth" alert when the adapter is off.
        ///
        /// Defaults to `false`: most apps would rather observe ``Central/adapterStates`` and
        /// present their own UI than have the system interrupt at central-creation time.
        public var showPowerAlert: Bool

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - connectTimeout: How long a connect attempt may run.
        ///   - reconnectPolicy: How long to keep waiting after a link drops.
        ///   - showPowerAlert: Whether the system may show its "Turn On Bluetooth" alert.
        public init(
            connectTimeout: Duration = .seconds(10),
            reconnectPolicy: ReconnectPolicy = .waitIndefinitely(),
            showPowerAlert: Bool = false
        ) {
            self.connectTimeout = connectTimeout
            self.reconnectPolicy = reconnectPolicy
            self.showPowerAlert = showPowerAlert
        }
    }
}
