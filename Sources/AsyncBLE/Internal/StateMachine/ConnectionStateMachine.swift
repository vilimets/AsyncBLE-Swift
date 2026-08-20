// Pure transition function: (state, event) -> (state, [effect]).
//
// Invariant: this file imports Foundation and nothing else. It must not know CoreBluetooth
// exists — that is what makes the whole transition table testable without hardware.

import Foundation

/// The single source of truth for a connection's state (PLAN.md §4).
///
/// Pure: it owns a `ConnectionState`, takes a ``ConnectionEvent``, and returns the
/// ``ConnectionEffect``s somebody else should perform. No clock, no radio, no I/O — which is
/// what lets every row of the transition table be a two-line test.
///
/// The reconnect policy is fixed for the machine's lifetime, because it is fixed for the
/// central's (``Central/Configuration``). It is consulted at exactly one place: deciding
/// whether a link the library did not close is worth waiting for.
struct ConnectionStateMachine {
    /// The result of feeding one event in: where the machine landed, and what to do about it.
    struct Transition: Sendable, Equatable {
        /// The state after the event.
        var state: ConnectionState
        /// The side effects to perform, in order.
        var effects: [ConnectionEffect]
    }

    /// The current state. Starts at `.disconnected(reason: nil)` — no link has ended yet.
    private(set) var state: ConnectionState = .disconnected(reason: nil)

    /// How long this connection waits for a dropped link.
    let policy: ReconnectPolicy

    /// Creates a machine in `.disconnected(reason: nil)`.
    ///
    /// - Parameter policy: The reconnect policy from the owning central's configuration.
    init(policy: ReconnectPolicy) {
        self.policy = policy
    }

    /// Feeds one event in and advances the state.
    ///
    /// - Parameter event: What happened.
    /// - Returns: The effects to perform, in order.
    @discardableResult
    mutating func handle(_ event: ConnectionEvent) -> [ConnectionEffect] {
        let transition = Self.transition(from: state, on: event, policy: policy)
        state = transition.state
        return transition.effects
    }

    /// The transition table itself, as a free function of its inputs.
    ///
    /// Exposed separately from ``handle(_:)`` so a test can assert on a single row without
    /// building up to it, and so it is visibly a function of nothing but its arguments.
    ///
    /// - Parameters:
    ///   - state: The state to transition from.
    ///   - event: What happened.
    ///   - policy: The reconnect policy in force.
    /// - Returns: The resulting state and the effects to perform.
    static func transition(
        from state: ConnectionState,
        on event: ConnectionEvent,
        policy: ReconnectPolicy
    ) -> Transition {
        switch state {
        case .disconnected(let reason):
            return fromDisconnected(reason, on: event)
        case .connecting:
            return fromConnecting(on: event)
        case .connected:
            return fromConnected(on: event, policy: policy)
        case .reconnecting(let attempt):
            return fromReconnecting(attempt: attempt, on: event, policy: policy)
        }
    }
}

// MARK: - Rows

extension ConnectionStateMachine {
    /// `disconnected` is terminal for everything except a fresh connect request.
    ///
    /// A connection that has reached `disconnected` is finished: the owning central releases
    /// it (PLAN.md §7 Q9) and any late CoreBluetooth callback — the `didDisconnect` that
    /// arrives after the `cancelPeripheralConnection` we asked for, most often — lands here
    /// and is dropped rather than resurrecting a dead machine.
    private static func fromDisconnected(
        _ reason: DisconnectReason?,
        on event: ConnectionEvent
    ) -> Transition {
        guard case .connectRequested(let timeout) = event else {
            return Transition(state: .disconnected(reason: reason), effects: [])
        }
        var effects: [ConnectionEffect] = [.armConnect]
        if let timeout {
            effects.append(.startConnectTimeout(timeout))
        }
        return Transition(state: .connecting, effects: effects)
    }

    /// A bounded attempt is in flight. Nothing here consults the reconnect policy: the policy
    /// governs links that dropped, not links that never came up.
    private static func fromConnecting(on event: ConnectionEvent) -> Transition {
        switch event {
        case .didConnect:
            return Transition(state: .connected, effects: [.cancelConnectTimeout, .invalidateDiscoveryCache])

        case .connectTimedOut:
            // The timer has fired, so there is nothing left to cancel but the radio request.
            return terminate(.connectTimeout, cancelling: [])

        case .didFailToConnect:
            // PLAN.md §4 lists no effect for this row; the armed timeout still has to go, or it
            // fires into a machine that has already moved on.
            return terminate(.connectFailed, cancelling: [.cancelConnectTimeout])

        case .didDisconnect(_, userInitiated: false):
            // CoreBluetooth occasionally reports a failed attempt this way instead.
            return terminate(.connectFailed, cancelling: [.cancelConnectTimeout])

        case .didDisconnect(_, userInitiated: true), .disconnectRequested:
            return terminate(.userInitiated, cancelling: [.cancelConnectTimeout])

        case .adapterChanged(.unavailable(let reason)):
            // Not in the §4 table. An attempt cannot survive the radio going away, and the
            // caller is awaiting an answer — so this fails rather than becoming a wait.
            return terminate(.bluetoothUnavailable(reason), cancelling: [.cancelConnectTimeout])

        case .connectRequested, .adapterChanged(.poweredOn), .reArmTimerFired, .giveUpDeadlineReached:
            // A second connect coalesces onto this attempt (PLAN.md §7 Q7.1); each caller's own
            // deadline is the central's business, not the machine's (§7 Q10). The rest are
            // stale timers from a previous state.
            return Transition(state: .connecting, effects: [])
        }
    }
}

extension ConnectionStateMachine {
    /// The link is up. The only interesting question here is *who* ended it.
    private static func fromConnected(on event: ConnectionEvent, policy: ReconnectPolicy) -> Transition {
        switch event {
        case .didDisconnect(_, userInitiated: true), .disconnectRequested:
            return terminate(.userInitiated, cancelling: [])

        case .didDisconnect(_, userInitiated: false):
            // A link the library did not close: the one case the policy governs.
            return dropped(reason: .linkLost, armImmediately: true, policy: policy)

        case .adapterChanged(.unavailable(let reason)):
            // The radio, not the peripheral, went away — so the same wait applies, but there is
            // nothing to arm until it comes back. Apple invalidates every peripheral object at
            // this point and does not reliably report a disconnect, hence handling it here.
            return dropped(reason: .bluetoothUnavailable(reason), armImmediately: false, policy: policy)

        case .connectRequested, .didConnect, .didFailToConnect, .connectTimedOut,
             .reArmTimerFired, .giveUpDeadlineReached, .adapterChanged(.poweredOn):
            // A connect request finds the link already up and returns it. The rest are late
            // duplicates or stale timers.
            return Transition(state: .connected, effects: [])
        }
    }

    /// The link dropped through no act of the library's. The policy decides what that means.
    ///
    /// - Parameters:
    ///   - reason: Why the link ended — reported to queued I/O either way.
    ///   - armImmediately: Whether a pending connect can be issued now. `false` when the
    ///     adapter is the thing that went away; the arm waits for `poweredOn` instead.
    ///   - policy: The reconnect policy in force.
    private static func dropped(
        reason: DisconnectReason,
        armImmediately: Bool,
        policy: ReconnectPolicy
    ) -> Transition {
        guard policy.persistence != .never else {
            return terminate(reason, cancelling: [])
        }
        // Queued I/O is failed before anything is re-armed: a write composed against the old
        // link must never land on the new one (PLAN.md §4, edge cases).
        var effects: [ConnectionEffect] = [
            .endPendingOperations(reason: reason),
            .invalidateDiscoveryCache,
            .markSubscriptionsForRestore
        ]
        if case .until(let deadline) = policy.persistence {
            effects.append(.startGiveUpDeadline(deadline))
        }
        if armImmediately {
            effects.append(.armConnect)
            if let interval = policy.reArmInterval {
                effects.append(.startReArmTimer(interval))
            }
        }
        return Transition(state: .reconnecting(attempt: 1), effects: effects)
    }
}

extension ConnectionStateMachine {
    /// Waiting for a dropped link. `attempt` counts arms of the pending connect, not retries:
    /// with no re-arm cadence it honestly reads `1` for the whole outage, because there
    /// genuinely is one request in flight and the OS is holding it (PLAN.md §7 Q16).
    private static func fromReconnecting(
        attempt: Int,
        on event: ConnectionEvent,
        policy: ReconnectPolicy
    ) -> Transition {
        switch event {
        case .didConnect:
            return Transition(
                state: .connected,
                effects: [
                    .cancelGiveUpDeadline, .cancelReArmTimer,
                    .invalidateDiscoveryCache, .restoreSubscriptions
                ]
            )

        case .didFailToConnect:
            // The OS gave the pending request back; re-issue it and count the arm.
            return Transition(state: .reconnecting(attempt: attempt + 1), effects: [.armConnect])

        case .reArmTimerFired:
            guard let interval = policy.reArmInterval else {
                return Transition(state: .reconnecting(attempt: attempt), effects: [])
            }
            return Transition(
                state: .reconnecting(attempt: attempt + 1),
                effects: [.cancelConnect, .armConnect, .startReArmTimer(interval)]
            )

        case .giveUpDeadlineReached:
            return terminate(.reconnectGaveUp, cancelling: [.cancelReArmTimer])

        case .adapterChanged(.unavailable):
            // The pending connect is void while the radio is off and the deadline keeps
            // burning (PLAN.md §7 Q20) — but a re-arm against a dead radio is pure waste.
            return Transition(state: .reconnecting(attempt: attempt), effects: [.cancelReArmTimer])

        case .adapterChanged(.poweredOn):
            var effects: [ConnectionEffect] = [.armConnect]
            if let interval = policy.reArmInterval {
                effects.append(.startReArmTimer(interval))
            }
            return Transition(state: .reconnecting(attempt: attempt), effects: effects)

        case .didDisconnect(_, userInitiated: true), .disconnectRequested:
            return terminate(.userInitiated, cancelling: [.cancelGiveUpDeadline, .cancelReArmTimer])

        case .didDisconnect(_, userInitiated: false), .connectRequested, .connectTimedOut:
            // A late duplicate drop, or a connect request that has just found the wait it was
            // about to start. Both are already what this state is doing.
            return Transition(state: .reconnecting(attempt: attempt), effects: [])
        }
    }

    /// The end of a connection, in one shape.
    ///
    /// Every terminal transition tears down the same things in the same order, so the
    /// connection actor needs no per-reason cleanup logic — and nothing can be forgotten in one
    /// path and remembered in another.
    ///
    /// - Parameters:
    ///   - reason: Why the connection ended.
    ///   - timers: The timers live in the state being left, cancelled before anything else.
    private static func terminate(
        _ reason: DisconnectReason,
        cancelling timers: [ConnectionEffect]
    ) -> Transition {
        Transition(
            state: .disconnected(reason: reason),
            effects: timers + [
                .cancelConnect,
                .endPendingOperations(reason: reason),
                .endSubscriptions(reason: reason),
                .invalidateDiscoveryCache
            ]
        )
    }
}
