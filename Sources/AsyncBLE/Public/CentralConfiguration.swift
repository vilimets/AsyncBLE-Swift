// Tunables passed to `Central` at init: connect timeout, reconnect policy, power alert,
// state-restoration identifier.

import Foundation

extension Central {
    /// Tunables for a ``Central``, fixed at initialization.
    public struct Configuration: Sendable, Equatable {
        /// How long a connect attempt may run before it fails with
        /// ``BluetoothError/connectTimeout``.
        ///
        /// CoreBluetooth has no native connect timeout: `connect(_:options:)` stays pending
        /// indefinitely against a peripheral that is off or out of range. This library imposes
        /// one, which is the whole reason the setting exists.
        ///
        /// Applies to ``Central/connect(_:timeout:)-(UUID,_)`` only. Reconnection after a drop, and
        /// ``Central/connectWhenInRange(_:)``, both deliberately rely on the OS keeping the
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

        /// The identifier iOS files this central's state under, for restoration after the app
        /// is terminated in the background.
        ///
        /// `nil` — the default — opts out: the central is an ordinary foreground one, and iOS
        /// keeps nothing about it. A non-`nil` identifier opts in, and the links this central
        /// holds are handed back on relaunch through ``Central/restoredConnections``.
        ///
        /// Two requirements, and the setting does nothing without both:
        ///
        /// - `bluetooth-central` must be in the app's `UIBackgroundModes`. Without it iOS
        ///   never relaunches the app, so there is nothing to restore into.
        /// - The identifier must be **stable across launches** and unique within the app. It is
        ///   the key iOS files the state under; a fresh UUID each launch restores nothing.
        ///
        /// Creating a second central with the same identifier is a CoreBluetooth programming
        /// error, so give each one its own.
        ///
        /// See <doc:BackgroundModes>.
        public var restoreIdentifier: String?

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - connectTimeout: How long a connect attempt may run.
        ///   - reconnectPolicy: How long to keep waiting after a link drops.
        ///   - showPowerAlert: Whether the system may show its "Turn On Bluetooth" alert.
        ///   - restoreIdentifier: A stable identifier to file this central's state under, or
        ///     `nil` to opt out of state restoration.
        public init(
            connectTimeout: Duration = .seconds(10),
            reconnectPolicy: ReconnectPolicy = .waitIndefinitely(),
            showPowerAlert: Bool = false,
            restoreIdentifier: String? = nil
        ) {
            self.connectTimeout = connectTimeout
            self.reconnectPolicy = reconnectPolicy
            self.showPowerAlert = showPowerAlert
            self.restoreIdentifier = restoreIdentifier
        }
    }
}
