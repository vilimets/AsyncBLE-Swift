// The edge cases that are about a *sequence* rather than a single row: a wait
// that survives a power cycle, an attempt counter that stays honest, a disconnect that leaves
// nothing running behind it.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("State machine: sequences")
struct StateMachineSequenceTests {
    @Test("the happy path: connect, use, drop, come back")
    func happyPath() {
        var run = MachineRun(policy: .waitIndefinitely())
        run.feed(.connectRequested(timeout: .seconds(10)))
        #expect(run.state == .connecting)
        run.feed(.didConnect)
        #expect(run.state == .connected)
        run.feed(.didDisconnect(cbFailure, userInitiated: false))
        #expect(run.state == .reconnecting(arm: 1))
        run.feed(.didConnect)
        #expect(run.state == .connected)
        // Coming back is a rebuild, not a resume: CoreBluetooth invalidated every cached
        // service and characteristic while the link was down.
        #expect(run.lastEffects.contains(.invalidateDiscoveryCache))
        #expect(run.lastEffects.contains(.restoreSubscriptions))
    }

    @Test("two connect calls produce one radio request")
    func connectWhileConnectingCoalesces() {
        var run = MachineRun()
        run.feed(
            .connectRequested(timeout: .seconds(10)),
            .connectRequested(timeout: .seconds(3)),
            .connectRequested(timeout: .seconds(30))
        )
        #expect(run.state == .connecting)
        #expect(run.allEffects.filter { $0 == .armConnect }.count == 1)
        #expect(run.allEffects.filter { $0 == .startConnectTimeout(.seconds(10)) }.count == 1)
        #expect(!run.allEffects.contains(.startConnectTimeout(.seconds(3))))
    }

    @Test("Bluetooth switched off mid-wait keeps the wait and the deadline")
    func powerCycleDuringWait() {
        var run = MachineRun.reconnecting(policy: .giveUp(after: .seconds(120), reArmEvery: .seconds(30)))
        #expect(run.state == .reconnecting(arm: 1))

        run.feed(.adapterChanged(.unavailable(reason: .poweredOff)))
        #expect(run.state == .reconnecting(arm: 1))
        #expect(run.lastEffects == [.cancelReArmTimer])

        run.feed(.adapterChanged(.poweredOn))
        #expect(run.state == .reconnecting(arm: 1))
        #expect(run.lastEffects == [.armConnect, .startReArmTimer(.seconds(30))])

        // Q20 in one assertion: nothing in a power cycle ever cancels the give-up deadline, so
        // a toggle through Control Center can genuinely end a bounded wait.
        #expect(!run.allEffects.contains(.cancelGiveUpDeadline))
        #expect(run.allEffects.filter { $0 == .startGiveUpDeadline(.seconds(120)) }.count == 1)
    }

    @Test("without a re-arm cadence the attempt counter honestly stays at 1")
    func attemptCounterStaysHonest() {
        // There is one request in flight and the OS is holding it. Counting
        // imaginary retries would be a lie told in a public API.
        var run = MachineRun.reconnecting(policy: .waitIndefinitely())
        run.feed(
            .adapterChanged(.unavailable(reason: .poweredOff)),
            .adapterChanged(.poweredOn),
            .adapterChanged(.unavailable(reason: .resetting)),
            .adapterChanged(.poweredOn)
        )
        #expect(run.state == .reconnecting(arm: 1))
    }

    @Test("a re-arm cadence is what makes the counter move")
    func cadenceMovesTheCounter() {
        var run = MachineRun.reconnecting(policy: .waitIndefinitely(reArmEvery: .seconds(30)))
        run.feed(.reArmTimerFired, .reArmTimerFired, .reArmTimerFired)
        #expect(run.state == .reconnecting(arm: 4))
    }

    @Test("a second outage starts counting from one again")
    func counterResetsOnReconnect() {
        var run = MachineRun.reconnecting(policy: .waitIndefinitely(reArmEvery: .seconds(30)))
        run.feed(.reArmTimerFired, .reArmTimerFired)
        #expect(run.state == .reconnecting(arm: 3))
        run.feed(.didConnect, .didDisconnect(cbFailure, userInitiated: false))
        #expect(run.state == .reconnecting(arm: 1))
    }

    @Test("disconnect() while waiting is the end of it, and stays the end of it")
    func disconnectWhileWaitingLeavesNoZombies() {
        var run = MachineRun.reconnecting(policy: .giveUp(after: .seconds(120), reArmEvery: .seconds(30)))
        run.feed(.disconnectRequested)
        #expect(run.state == .disconnected(reason: .userInitiated))
        #expect(run.lastEffects.contains(.cancelGiveUpDeadline))
        #expect(run.lastEffects.contains(.cancelReArmTimer))
        #expect(run.lastEffects.contains(.cancelConnect))

        // Timers that were already in flight, and the connect the OS lands anyway, all arrive
        // after the fact. None of them may restart anything.
        run.feed(.reArmTimerFired, .giveUpDeadlineReached, .didConnect)
        #expect(run.state == .disconnected(reason: .userInitiated))
        #expect(run.lastEffects.isEmpty)
    }

    @Test("a bounded wait that runs out ends in reconnectGaveUp")
    func boundedWaitGivesUp() {
        var run = MachineRun.connected(policy: .giveUp(after: .seconds(120)))
        run.feed(.didDisconnect(cbFailure, userInitiated: false))
        #expect(run.lastEffects.contains(.startGiveUpDeadline(.seconds(120))))
        run.feed(.giveUpDeadlineReached)
        #expect(run.state == .disconnected(reason: .reconnectGaveUp))
        #expect(run.lastEffects.contains(.endSubscriptions(reason: .reconnectGaveUp)))
    }

    @Test("connectWhenInRange pends without a deadline and lands like any other connect")
    func pendingConnectLands() {
        var run = MachineRun(policy: .waitIndefinitely())
        run.feed(.connectRequested(timeout: nil))
        #expect(run.state == .connecting)
        #expect(!run.allEffects.contains { if case .startConnectTimeout = $0 { true } else { false } })
        run.feed(.didConnect)
        #expect(run.state == .connected)
    }
}
