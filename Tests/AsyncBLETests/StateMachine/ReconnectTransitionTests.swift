// The rows of PLAN.md §4 that leave `connected` and `reconnecting` — the reconnect mechanism
// itself, which is the one thing this library is judged on (PLAN.md §1).
//
// Every test here is a pure function call. There is no clock and no radio: the machine emits
// `startGiveUpDeadline` and receives `giveUpDeadlineReached`, so time never has to pass.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("State machine: a link drops")
struct LinkDropTransitionTests {
    private func drop(policy: ReconnectPolicy) -> ConnectionStateMachine.Transition {
        ConnectionStateMachine.transition(
            from: .connected,
            on: .didDisconnect(cbFailure, userInitiated: false),
            policy: policy
        )
    }

    @Test("an indefinite policy re-arms the pending connect and waits")
    func indefiniteWait() {
        let result = drop(policy: .waitIndefinitely())
        #expect(result.state == .reconnecting(arm: 1))
        #expect(result.effects == [
            .endPendingOperations(reason: .linkLost),
            .invalidateDiscoveryCache,
            .markSubscriptionsForRestore,
            .armConnect
        ])
    }

    @Test("queued I/O is failed before anything is re-armed")
    func queuedWritesFailFirst() {
        // PLAN.md §4, edge cases: a write composed against the old link must not land on the
        // new one. Ordering is the whole assertion.
        let effects = drop(policy: .waitIndefinitely()).effects
        let failed = effects.firstIndex(of: .endPendingOperations(reason: .linkLost))
        let armed = effects.firstIndex(of: .armConnect)
        #expect(failed != nil)
        #expect(armed != nil)
        #expect(failed! < armed!)
    }

    @Test("a bounded policy starts its give-up deadline")
    func boundedWait() {
        let result = drop(policy: .giveUp(after: .seconds(120)))
        #expect(result.state == .reconnecting(arm: 1))
        #expect(result.effects.contains(.startGiveUpDeadline(.seconds(120))))
    }

    @Test("a re-arm cadence starts alongside the first arm")
    func cadenceStarts() {
        let result = drop(policy: .waitIndefinitely(reArmEvery: .seconds(30)))
        #expect(result.effects == [
            .endPendingOperations(reason: .linkLost),
            .invalidateDiscoveryCache,
            .markSubscriptionsForRestore,
            .armConnect,
            .startReArmTimer(.seconds(30))
        ])
    }

    @Test("ReconnectPolicy.never ends the connection instead of waiting")
    func noPolicyEndsIt() {
        let result = drop(policy: .never)
        #expect(result.state == .disconnected(reason: .linkLost))
        #expect(result.effects == terminalEffects(.linkLost))
    }

    @Test("a user-initiated disconnect never consults the policy", arguments: [
        ReconnectPolicy.never,
        .waitIndefinitely(),
        .giveUp(after: .seconds(60))
    ])
    func userDisconnectNeverWaits(policy: ReconnectPolicy) {
        // The same CoreBluetooth callback as a link drop; only the flag differs (PLAN.md §2).
        let result = ConnectionStateMachine.transition(
            from: .connected,
            on: .didDisconnect(nil, userInitiated: true),
            policy: policy
        )
        #expect(result.state == .disconnected(reason: .userInitiated))
        #expect(result.effects == terminalEffects(.userInitiated))
    }

    @Test("the adapter going away is a drop with nothing to arm")
    func adapterLostWhileConnected() {
        let result = ConnectionStateMachine.transition(
            from: .connected,
            on: .adapterChanged(.unavailable(reason: .poweredOff)),
            policy: .giveUp(after: .seconds(60))
        )
        #expect(result.state == .reconnecting(arm: 1))
        #expect(result.effects == [
            .endPendingOperations(reason: .bluetoothUnavailable(reason: .poweredOff)),
            .invalidateDiscoveryCache,
            .markSubscriptionsForRestore,
            .startGiveUpDeadline(.seconds(60))
        ])
        // No armConnect: there is no radio to arm. The wait picks that up on poweredOn.
        #expect(!result.effects.contains(.armConnect))
    }

    @Test("with no policy, the adapter going away ends the connection")
    func adapterLostWithoutPolicy() {
        let result = ConnectionStateMachine.transition(
            from: .connected,
            on: .adapterChanged(.unavailable(reason: .unauthorized)),
            policy: .never
        )
        #expect(result.state == .disconnected(reason: .bluetoothUnavailable(reason: .unauthorized)))
        #expect(result.effects == terminalEffects(.bluetoothUnavailable(reason: .unauthorized)))
    }
}

@Suite("State machine: waiting for a link to come back")
struct ReconnectingTransitionTests {
    private func transition(
        attempt: Int = 1,
        on event: ConnectionEvent,
        policy: ReconnectPolicy = .waitIndefinitely()
    ) -> ConnectionStateMachine.Transition {
        ConnectionStateMachine.transition(from: .reconnecting(arm: attempt), on: event, policy: policy)
    }

    @Test("the link coming back cancels both timers and restores subscriptions")
    func reconnectLands() {
        let result = transition(attempt: 3, on: .didConnect)
        #expect(result.state == .connected)
        #expect(result.effects == [
            .cancelGiveUpDeadline,
            .cancelReArmTimer,
            .invalidateDiscoveryCache,
            .restoreSubscriptions
        ])
    }

    @Test("a reported failure re-arms and counts the arm")
    func failureCountsAnArm() {
        let result = transition(attempt: 1, on: .didFailToConnect(cbFailure))
        #expect(result.state == .reconnecting(arm: 2))
        #expect(result.effects == [.armConnect])
    }

    @Test("the re-arm cadence cancels and re-issues the pending connect")
    func cadenceReArms() {
        let result = transition(
            attempt: 1,
            on: .reArmTimerFired,
            policy: .waitIndefinitely(reArmEvery: .seconds(30))
        )
        #expect(result.state == .reconnecting(arm: 2))
        #expect(result.effects == [.cancelConnect, .armConnect, .startReArmTimer(.seconds(30))])
    }

    @Test("a cadence timer that fires under a policy without one is stale")
    func cadenceTimerWithoutCadence() {
        let result = transition(attempt: 1, on: .reArmTimerFired, policy: .waitIndefinitely())
        #expect(result.state == .reconnecting(arm: 1))
        #expect(result.effects.isEmpty)
    }

    @Test("the deadline expiring ends the connection and the subscriptions with it")
    func deadlineGivesUp() {
        // The one place reconnectGaveUp comes from. Subscriptions throw rather than finish
        // quietly (PLAN.md §7 Q8) — the machine reports the reason, the stream layer presents it.
        let result = transition(attempt: 4, on: .giveUpDeadlineReached, policy: .giveUp(after: .seconds(60)))
        #expect(result.state == .disconnected(reason: .reconnectGaveUp))
        #expect(result.effects == [.cancelReArmTimer] + terminalEffects(.reconnectGaveUp))
    }

    @Test("the adapter going away stops re-arming but never the deadline")
    func adapterOffKeepsBurningTheDeadline() {
        // PLAN.md §7 Q20, which deliberately reversed the first round's answer: the deadline is
        // wall-clock and a long enough power-off does end the wait.
        let result = transition(
            attempt: 2,
            on: .adapterChanged(.unavailable(reason: .poweredOff)),
            policy: .giveUp(after: .seconds(120), reArmEvery: .seconds(30))
        )
        #expect(result.state == .reconnecting(arm: 2))
        #expect(result.effects == [.cancelReArmTimer])
        #expect(!result.effects.contains(.cancelGiveUpDeadline))
    }

    @Test("the adapter coming back re-arms without counting an attempt")
    func adapterBackReArms() {
        let result = transition(
            attempt: 2,
            on: .adapterChanged(.poweredOn),
            policy: .waitIndefinitely(reArmEvery: .seconds(30))
        )
        #expect(result.state == .reconnecting(arm: 2))
        #expect(result.effects == [.armConnect, .startReArmTimer(.seconds(30))])
    }

    @Test("disconnect() while waiting leaves no zombie timers")
    func disconnectWhileWaiting() {
        // PLAN.md §4, edge cases. Both timers go, and so does the pending connect the OS is
        // still holding — otherwise it lands on a connection nobody is watching.
        let result = transition(
            attempt: 5,
            on: .disconnectRequested,
            policy: .giveUp(after: .seconds(120), reArmEvery: .seconds(30))
        )
        #expect(result.state == .disconnected(reason: .userInitiated))
        #expect(result.effects == [.cancelGiveUpDeadline, .cancelReArmTimer] + terminalEffects(.userInitiated))
    }

    @Test("a connect request during a wait joins the wait already in progress")
    func connectDuringWait() {
        let result = transition(attempt: 2, on: .connectRequested(timeout: .seconds(5)))
        #expect(result.state == .reconnecting(arm: 2))
        #expect(result.effects.isEmpty)
    }

    @Test("late duplicates of the drop change nothing", arguments: [
        ConnectionEvent.didDisconnect(cbFailure, userInitiated: false),
        .connectTimedOut
    ])
    func lateDuplicatesIgnored(event: ConnectionEvent) {
        let result = transition(attempt: 2, on: event)
        #expect(result.state == .reconnecting(arm: 2))
        #expect(result.effects.isEmpty)
    }
}
