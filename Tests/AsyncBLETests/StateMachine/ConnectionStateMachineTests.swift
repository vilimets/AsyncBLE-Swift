// One test per row of the transition table in PLAN.md §4, plus the explicit edge cases:
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
        // connectWhenAvailable(_:): the OS holds the request, so there is no timer to run
        // against it (PLAN.md §7 Q17).
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
        .adapterChanged(.unavailable(.poweredOff))
    ])
    func disconnectedIsTerminal(event: ConnectionEvent) {
        // The late didDisconnect that follows our own cancelPeripheralConnection lands here.
        // It must not resurrect a machine the central has already released (PLAN.md §7 Q9).
        let transition = ConnectionStateMachine.transition(
            from: .disconnected(reason: .userInitiated),
            on: event,
            policy: .waitIndefinitely()
        )
        #expect(transition.state == .disconnected(reason: .userInitiated))
        #expect(transition.effects.isEmpty)
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
        #expect(result.state == .disconnected(reason: .connectFailed))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.connectFailed))
    }

    @Test("a disconnect reported during the attempt reads as a failed attempt")
    func disconnectDuringAttempt() {
        let result = transition(on: .didDisconnect(cbFailure, userInitiated: false))
        #expect(result.state == .disconnected(reason: .connectFailed))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.connectFailed))
    }

    @Test("disconnect() during the attempt withdraws it")
    func cancelledDuringAttempt() {
        let result = transition(on: .disconnectRequested)
        #expect(result.state == .disconnected(reason: .userInitiated))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.userInitiated))
    }

    @Test("the adapter going away fails the attempt rather than starting a wait")
    func adapterLostDuringAttempt() {
        // Not in the §4 table. A caller is awaiting an answer, and the reconnect policy governs
        // links that dropped — not links that never came up.
        let result = transition(on: .adapterChanged(.unavailable(.poweredOff)))
        #expect(result.state == .disconnected(reason: .bluetoothUnavailable(.poweredOff)))
        #expect(result.effects == [.cancelConnectTimeout] + terminalEffects(.bluetoothUnavailable(.poweredOff)))
    }

    @Test("a second connect coalesces onto the attempt in flight")
    func secondConnectCoalesces() {
        // PLAN.md §7 Q7.1. Note what is *not* here: no second armConnect, and no second
        // deadline — the caller's own deadline is the central's business (§7 Q10).
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
