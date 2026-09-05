// One test per row of the transition table, plus the explicit edge cases:
//   - disconnect() while reconnecting cancels the timer (no zombie retry)
//   - connect() while already connecting
//   - Bluetooth powered off mid-connection
//
// Working agreement: a state machine change lands with its test in the same commit.
//
// This file covers the rows leaving `disconnected` and `connecting`; the ones leaving
// `connected` and `reconnecting` are in ReconnectTransitionTests, and the sequences are in
// StateMachineSequenceTests.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("State machine: leaving disconnected")
struct DisconnectedTransitionTests {
    @Test("connectRequested with a timeout arms the radio and the deadline")
    func boundedConnectArmsBoth() {
        let transition = ConnectionStateMachine.transition(
            from: .disconnected(reason: nil),
            on: .connectRequested(timeout: .seconds(5)),
            policy: .waitIndefinitely()
        )
        #expect(transition.state == .connecting)
        #expect(transition.effects == [.armConnect, .startConnectTimeout(.seconds(5))])
    }

    @Test("connectRequested without a timeout arms only the radio")
    func pendingConnectArmsNoDeadline() {
        // connectWhenInRange(_:): the OS holds the request, so there is no timer to run
        // against it.
        let transition = ConnectionStateMachine.transition(
            from: .disconnected(reason: nil),
            on: .connectRequested(timeout: nil),
            policy: .waitIndefinitely()
        )
        #expect(transition.state == .connecting)
        #expect(transition.effects == [.armConnect])
    }

    @Test("a connection that has reached disconnected stays there", arguments: [
        ConnectionEvent.didConnect,
        .didDisconnect(cbFailure, userInitiated: false),
        .didFailToConnect(cbFailure),
        .connectTimedOut,
        .disconnectRequested,
        .reArmTimerFired,
        .giveUpDeadlineReached,
        .adapterChanged(.poweredOn),
        .adapterChanged(.unavailable(reason: .poweredOff))
    ])
    func disconnectedIsTerminal(event: ConnectionEvent) {
        // The late didDisconnect that follows our own cancelPeripheralConnection lands here.
        // It must not resurrect a machine the central has already released.
        let transition = ConnectionStateMachine.transition(
            from: .disconnected(reason: .userInitiated),
            on: event,
            policy: .waitIndefinitely()
        )
        #expect(transition.state == .disconnected(reason: .userInitiated))
        #expect(transition.effects.isEmpty)
    }
}

@Suite("State machine: restoration")
struct RestorationTransitionTests {
    private func restoring(
        from state: ConnectionState,
        connected: Bool,
        policy: ReconnectPolicy = .waitIndefinitely()
    ) -> ConnectionStateMachine.Transition {
        ConnectionStateMachine.transition(from: state, on: .restored(connected: connected), policy: policy)
    }

    @Test("a restored live link lands connected, arming nothing")
    func restoredConnected() {
        // Nothing to arm and no deadline to cancel: the link is already up. The cache is
        // invalidated because it is empty, which is the same thing said once.
        let result = restoring(from: .disconnected(reason: nil), connected: true)
        #expect(result.state == .connected)
        #expect(result.effects == [.invalidateDiscoveryCache])
    }

    @Test("a restored pending connect becomes a reconnect wait")
    func restoredConnecting() {
        let result = restoring(from: .disconnected(reason: nil), connected: false)
        #expect(result.state == .reconnecting(arm: 1))
        #expect(result.effects == [
            .endPendingOperations(reason: .linkLost),
            .invalidateDiscoveryCache,
            .markSubscriptionsForRestore,
            .armConnect
        ])
    }

    @Test("a restored pending connect picks up a bounded policy's deadline")
    func restoredConnectingBounded() {
        let result = restoring(
            from: .disconnected(reason: nil),
            connected: false,
            policy: .giveUp(after: .seconds(30))
        )
        #expect(result.state == .reconnecting(arm: 1))
        #expect(result.effects == [
            .endPendingOperations(reason: .linkLost),
            .invalidateDiscoveryCache,
            .markSubscriptionsForRestore,
            .startGiveUpDeadline(.seconds(30)),
            .armConnect
        ])
    }

    @Test("a restored pending connect under `.never` ends rather than waits")
    func restoredConnectingUnderNever() {
        // `.never` means do not wait for a link that dropped, and a pending connect the OS is
        // holding *is* that wait.
        let result = restoring(from: .disconnected(reason: nil), connected: false, policy: .never)
        #expect(result.state == .disconnected(reason: .linkLost))
        #expect(result.effects == terminalEffects(.linkLost))
    }

    @Test("a machine that already ended stays ended", arguments: [true, false])
    func restoringATerminalMachineIsIgnored(connected: Bool) {
        let result = restoring(from: .disconnected(reason: .userInitiated), connected: connected)
        #expect(result.state == .disconnected(reason: .userInitiated))
        #expect(result.effects.isEmpty)
    }

    @Test("a machine already in flight ignores it", arguments: [
        ConnectionState.connecting,
        .connected,
        .reconnecting(arm: 2)
    ])
    func restoringAnActiveMachineIsIgnored(state: ConnectionState) {
        let result = restoring(from: state, connected: true)
        #expect(result.state == state)
        #expect(result.effects.isEmpty)
    }
}

@Suite("State machine: leaving connecting")
struct ConnectingTransitionTests {
    private func transition(on event: ConnectionEvent) -> ConnectionStateMachine.Transition {
        ConnectionStateMachine.transition(from: .connecting, on: event, policy: .waitIndefinitely())
    }

    @Test("didConnect cancels the deadline and starts with an empty cache")
    func connectSucceeds() {
        let result = transition(on: .didConnect)
        #expect(result.state == .connected)
        #expect(result.effects == [.cancelConnectTimeout, .invalidateDiscoveryCache])
    }

    @Test("connectTimedOut withdraws the pending request")
    func connectTimesOut() {
        // The headline fix: CoreBluetooth would have stayed pending forever.
        let result = transition(on: .connectTimedOut)
        #expect(result.state == .disconnected(reason: .connectTimeout))
        #expect(result.effects == terminalEffects(.connectTimeout))
    }

    @Test("didFailToConnect cancels the deadline it would otherwise outlive")
    func connectFails() {
        let result = transition(on: .didFailToConnect(cbFailure))
        #expect(result.state == .disconnected(reason: .connectionFailed))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.connectionFailed))
    }

    @Test("a disconnect reported during the attempt reads as a failed attempt")
    func disconnectDuringAttempt() {
        let result = transition(on: .didDisconnect(cbFailure, userInitiated: false))
        #expect(result.state == .disconnected(reason: .connectionFailed))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.connectionFailed))
    }

    @Test("disconnect() during the attempt withdraws it")
    func cancelledDuringAttempt() {
        let result = transition(on: .disconnectRequested)
        #expect(result.state == .disconnected(reason: .userInitiated))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.userInitiated))
    }

    @Test("the adapter going away fails the attempt rather than starting a wait")
    func adapterLostDuringAttempt() {
        // Not in the transition table. A caller is awaiting an answer, and the reconnect policy
        // governs links that dropped — not links that never came up.
        let result = transition(on: .adapterChanged(.unavailable(reason: .poweredOff)))
        #expect(result.state == .disconnected(reason: .bluetoothUnavailable(reason: .poweredOff)))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.bluetoothUnavailable(reason: .poweredOff)))
    }

    @Test("a second connect coalesces onto the attempt in flight")
    func secondConnectCoalesces() {
        // Note what is *not* here: no second armConnect, and no second
        // deadline — the caller's own deadline is the central's business.
        let result = transition(on: .connectRequested(timeout: .seconds(1)))
        #expect(result.state == .connecting)
        #expect(result.effects.isEmpty)
    }

    @Test("stale timers from an earlier state are ignored", arguments: [
        ConnectionEvent.reArmTimerFired,
        .giveUpDeadlineReached,
        .adapterChanged(.poweredOn)
    ])
    func staleTimersIgnored(event: ConnectionEvent) {
        let result = transition(on: event)
        #expect(result.state == .connecting)
        #expect(result.effects.isEmpty)
    }
}
