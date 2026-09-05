// The policy as a value: .never / .indefinitely / .until(deadline), and the optional re-arm
// cadence. No curve to assert any more — the OS holds the pending connect.
//
// The engine's behavior is what needs covering: deadline expiry lands in .reconnectGaveUp, the
// deadline keeps running while the adapter is off, re-arms increment the attempt
// counter, and disconnect() cancels both timers.
//
// There is no ReconnectEngine type. With the OS doing the retrying there is no retry loop to
// own, so what would have been the engine is three timers in the connection's effect
// application — and this is where they are tested.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("Reconnect policy values")
struct ReconnectPolicyValueTests {
    @Test("the factories say what they mean")
    func factories() {
        #expect(ReconnectPolicy.never.persistence == .never)
        #expect(ReconnectPolicy.never.reArmInterval == nil)
        #expect(ReconnectPolicy.waitIndefinitely().persistence == .indefinitely)
        #expect(ReconnectPolicy.giveUp(after: .seconds(120)).persistence == .until(.seconds(120)))
    }

    @Test("the re-arm cadence is opt-in on both factories")
    func cadenceIsOptIn() {
        // Left nil, the OS holds the pending connect, which is both cheaper and more reliable.
        #expect(ReconnectPolicy.waitIndefinitely().reArmInterval == nil)
        #expect(ReconnectPolicy.giveUp(after: .seconds(60)).reArmInterval == nil)
        #expect(ReconnectPolicy.waitIndefinitely(reArmEvery: .seconds(30)).reArmInterval == .seconds(30))
        #expect(ReconnectPolicy.giveUp(after: .seconds(60), reArmEvery: .seconds(30)).reArmInterval == .seconds(30))
    }

    @Test("policies compare by value, so a test needs no clock and no mock")
    func equatable() {
        // The point of dropping the closures from the policy.
        #expect(ReconnectPolicy.waitIndefinitely() == .waitIndefinitely())
        #expect(ReconnectPolicy.giveUp(after: .seconds(60)) != .giveUp(after: .seconds(61)))
        #expect(ReconnectPolicy.waitIndefinitely() != .waitIndefinitely(reArmEvery: .seconds(30)))
        #expect(ReconnectPolicy.never != .waitIndefinitely())
    }

    @Test("the default configuration waits indefinitely")
    func defaultPolicy() {
        // The old default gave up after ~31 seconds, which is useless for a
        // wearable. Waiting costs nothing, because the OS is doing the waiting.
        #expect(Central.Configuration().reconnectPolicy == .waitIndefinitely())
    }
}

@Suite("Reconnect behavior")
struct ReconnectBehaviorTests {
    @Test("a connect attempt that runs out of time is withdrawn")
    func connectTimeout() async {
        // CoreBluetooth has no native connect timeout — a request stays pending forever. This
        // is the headline fix, and this is it firing.
        let rig = ConnectionRig()
        rig.sync { rig.core.requestConnect(timeout: .seconds(10)) }
        #expect(rig.state == .connecting)

        rig.sync { rig.scheduler.advance(by: .seconds(10)) }

        #expect(rig.state == .disconnected(reason: .connectTimeout))
        #expect(rig.sync { rig.central.calls }.contains(.cancelConnection(rig.peripheral.identifier)))
    }

    @Test("a pending connect has no deadline to run out")
    func pendingConnectNeverTimesOut() async {
        // connectWhenInRange(_:): nobody is awaiting it, so it waits.
        let rig = ConnectionRig()
        rig.sync { rig.core.requestConnect(timeout: nil) }

        rig.sync { rig.scheduler.advance(by: .seconds(3600)) }

        #expect(rig.state == .connecting)
        #expect(rig.sync { rig.scheduler.pendingCount } == 0)
    }

    @Test("without a cadence, one arm covers the whole outage")
    func noCadenceMeansOneArm() async {
        // There is one request in flight and the OS is holding it. The attempt
        // number says `1` because that is the truth.
        let rig = ConnectionRig(policy: .waitIndefinitely())
        rig.connect()
        rig.dropLink()
        rig.sync { rig.central.clearCalls() }

        rig.sync { rig.scheduler.advance(by: .seconds(600)) }

        #expect(rig.state == .reconnecting(arm: 1))
        #expect(rig.sync { rig.central.calls }.isEmpty)
    }

    @Test("a cadence cancels and re-issues the pending connect, counting each arm")
    func cadenceReArms() async {
        // The workaround for a CoreBluetooth connection that gets wedged and never fulfils a
        // pending connect; cancelling and re-issuing sometimes shakes one loose.
        let rig = ConnectionRig(policy: .waitIndefinitely(reArmEvery: .seconds(30)))
        rig.connect()
        rig.dropLink()
        rig.sync { rig.central.clearCalls() }

        rig.sync { rig.scheduler.advance(by: .seconds(90)) }

        #expect(rig.state == .reconnecting(arm: 4))
        #expect(rig.sync { rig.central.calls } == [
            .cancelConnection(rig.peripheral.identifier), .connect(rig.peripheral.identifier),
            .cancelConnection(rig.peripheral.identifier), .connect(rig.peripheral.identifier),
            .cancelConnection(rig.peripheral.identifier), .connect(rig.peripheral.identifier)
        ])
    }

    @Test("no cadence fires against a dead radio")
    func cadencePausesWhileTheAdapterIsOff() async {
        // The two-axis policy: the deadline still burns, but re-arming a
        // connect against a switched-off adapter is pure waste.
        let rig = ConnectionRig(policy: .waitIndefinitely(reArmEvery: .seconds(30)))
        rig.connect()
        rig.dropLink()
        rig.setAdapter(.unavailable(reason: .poweredOff))
        rig.sync { rig.central.clearCalls() }

        rig.sync { rig.scheduler.advance(by: .seconds(90)) }

        #expect(rig.sync { rig.central.calls }.isEmpty)
        #expect(rig.state == .reconnecting(arm: 1))
    }

    @Test("ReconnectPolicy.never ends the connection on the first drop")
    func noPolicyDoesNotWait() async {
        let rig = ConnectionRig(policy: .never)
        rig.connect()

        rig.dropLink()

        #expect(rig.state == .disconnected(reason: .linkLost))
        #expect(rig.sync { rig.scheduler.pendingCount } == 0)
    }

    @Test("disconnect during a wait leaves no timers running")
    func disconnectLeavesNoZombies() async {
        // Edge case. A give-up deadline that outlived its connection would fire
        // into nothing; a re-arm timer would talk to a radio nobody is listening to.
        let rig = ConnectionRig(policy: .giveUp(after: .seconds(120), reArmEvery: .seconds(30)))
        rig.connect()
        rig.dropLink()
        #expect(rig.sync { rig.scheduler.pendingCount } == 2)

        await rig.connection.disconnect()

        #expect(rig.sync { rig.scheduler.pendingCount } == 0)
        #expect(rig.state == .disconnected(reason: .userInitiated))
    }

    @Test("a link that comes back cancels the deadline it beat")
    func reconnectCancelsTheDeadline() async {
        let rig = ConnectionRig(policy: .giveUp(after: .seconds(120)))
        rig.connect()
        rig.dropLink()
        #expect(rig.sync { rig.scheduler.pendingCount } == 1)

        rig.relink()

        #expect(rig.state == .connected)
        #expect(rig.sync { rig.scheduler.pendingCount } == 0)
    }

    @Test("a second outage starts its own deadline")
    func deadlineIsPerOutage() async {
        let rig = ConnectionRig(policy: .giveUp(after: .seconds(120)))
        rig.connect()
        rig.dropLink()
        rig.sync { rig.scheduler.advance(by: .seconds(119)) }
        rig.relink()

        rig.dropLink()
        rig.sync { rig.scheduler.advance(by: .seconds(119)) }

        // The first outage's 119 seconds do not count against the second's budget.
        #expect(rig.state == .reconnecting(arm: 1))
        rig.sync { rig.scheduler.advance(by: .seconds(1)) }
        #expect(rig.state == .disconnected(reason: .reconnectGaveUp))
    }
}
