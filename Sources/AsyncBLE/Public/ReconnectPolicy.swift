// How long to keep waiting for a dropped link, and whether to re-arm while waiting.
//
// Not a backoff curve: under PLAN.md §7 Q14 the OS does the retrying, so a policy answers
// "is this link still worth waiting for?" — a pure question, so the tests need no clock.

import Foundation

/// How long the library keeps waiting for a dropped link to come back.
///
/// CoreBluetooth already reconnects: a pending connect request stays armed and the OS fulfils
/// it whenever the peripheral reappears, scheduled by the radio rather than by an app timer.
/// So this type does not describe a retry curve. It answers the question the OS will never
/// answer for you — *when do we stop waiting?* — plus one optional workaround for when the OS
/// gets stuck.
///
/// The policy is consulted only for drops the library did not cause. Calling
/// ``Connection/disconnect()`` never waits, whatever the policy says.
public struct ReconnectPolicy: Sendable, Equatable {
    /// How long to keep a dropped link's pending connect armed.
    public enum Persistence: Sendable, Equatable {
        /// Do not wait at all: a dropped link goes straight to `disconnected`.
        case never

        /// Wait forever, which is what the OS does natively.
        case indefinitely

        /// Wait for a bounded time, then give up with ``DisconnectReason/reconnectGaveUp``.
        ///
        /// - Parameter duration: How long to wait, measured in wall-clock time from the drop.
        case until(Duration)
    }

    /// How long this policy keeps waiting.
    public let persistence: Persistence

    /// How often to cancel and re-arm the pending connect while waiting, if at all.
    ///
    /// `nil` — the default — leaves the OS to it, which is both cheaper and more reliable.
    /// Set an interval only if you are working around a CoreBluetooth connection that gets
    /// wedged and never fulfils a pending connect; cancelling and re-issuing sometimes shakes
    /// one loose. Each re-arm increments the attempt number in
    /// ``ConnectionState/reconnecting(attempt:)``.
    public let reArmInterval: Duration?

    private init(persistence: Persistence, reArmInterval: Duration?) {
        self.persistence = persistence
        self.reArmInterval = reArmInterval
    }

    /// Never wait: a dropped link ends the connection immediately.
    ///
    /// Use this when the app decides for itself when to reconnect — for example only while a
    /// particular screen is on-screen.
    public static let none = ReconnectPolicy(persistence: .never, reArmInterval: nil)

    /// Wait indefinitely for the peripheral to come back.
    ///
    /// The default, and the right answer for a device the user expects to stay paired with: a
    /// wearable out of range for twenty minutes is not a failed connection, it is a wearable
    /// out of range. Costs nothing while waiting, because the OS is doing the waiting.
    ///
    /// - Parameter reArmEvery: How often to cancel and re-issue the pending connect. Leave
    ///   `nil` unless working around a wedged connection.
    /// - Returns: A policy that never gives up.
    public static func waitIndefinitely(reArmEvery: Duration? = nil) -> ReconnectPolicy {
        ReconnectPolicy(persistence: .indefinitely, reArmInterval: reArmEvery)
    }

    /// Wait for a bounded time, then give up.
    ///
    /// The deadline is wall-clock time from the moment the link dropped, and it keeps running
    /// while Bluetooth is switched off (PLAN.md §7 Q20) — so a deadline shorter than a user's
    /// trip through Control Center will end the connection.
    ///
    /// - Parameters:
    ///   - deadline: How long to wait before giving up.
    ///   - reArmEvery: How often to cancel and re-issue the pending connect. Leave `nil`
    ///     unless working around a wedged connection.
    /// - Returns: A policy that gives up after `deadline`.
    public static func giveUp(after deadline: Duration, reArmEvery: Duration? = nil) -> ReconnectPolicy {
        ReconnectPolicy(persistence: .until(deadline), reArmInterval: reArmEvery)
    }
}
