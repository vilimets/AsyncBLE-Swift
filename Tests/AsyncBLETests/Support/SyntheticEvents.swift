// Test helpers: event sequence builders, a fake clock, and the fakes behind the CoreBluetooth
// seam (PLAN.md §7 Q7) that emit synthetic delegate callbacks.
//
// No mocks of Apple classes — the state machine never sees CoreBluetooth (PLAN.md §2), and the
// bridge sees only our own protocols.

import Foundation

@testable import AsyncBLE

/// Drives a ``ConnectionStateMachine`` through a sequence of events, keeping the transcript.
///
/// Single-row tests call `ConnectionStateMachine.transition(from:on:policy:)` directly — it is
/// pure, so there is nothing to set up. This is for the cases where the *sequence* is the thing
/// under test: that a wait survives a power cycle, that two connects produce one arm.
struct MachineRun {
    private(set) var machine: ConnectionStateMachine

    /// Every state the machine has been in, starting with the one it was created in.
    private(set) var states: [ConnectionState]

    /// The effects of the most recent event, which is what a sequence test usually asserts on.
    private(set) var lastEffects: [ConnectionEffect] = []

    /// Every effect produced so far, flattened — for asserting that something happened once.
    private(set) var allEffects: [ConnectionEffect] = []

    init(policy: ReconnectPolicy = .waitIndefinitely()) {
        machine = ConnectionStateMachine(policy: policy)
        states = [machine.state]
    }

    /// The machine's current state.
    var state: ConnectionState { machine.state }

    /// Feeds events in order.
    @discardableResult
    mutating func feed(_ events: ConnectionEvent...) -> [ConnectionEffect] {
        for event in events {
            lastEffects = machine.handle(event)
            allEffects += lastEffects
            states.append(machine.state)
        }
        return lastEffects
    }

    /// A run already sitting on a live link, via the path a real connection takes to get there.
    static func connected(policy: ReconnectPolicy = .waitIndefinitely()) -> MachineRun {
        var run = MachineRun(policy: policy)
        run.feed(.connectRequested(timeout: .seconds(10)), .didConnect)
        return run
    }

    /// A run waiting out a link drop, via the path a real connection takes to get there.
    static func reconnecting(policy: ReconnectPolicy = .waitIndefinitely()) -> MachineRun {
        var run = MachineRun.connected(policy: policy)
        run.feed(.didDisconnect(nil, userInitiated: false))
        return run
    }
}

/// A stand-in for the errors CoreBluetooth reports, so a test can pass one without inventing a
/// domain each time. The machine never reads the payload; passing it everywhere proves that.
///
/// The domain is spelled out rather than imported: this file, like the machine it drives, has
/// no business knowing CoreBluetooth exists. Code 6 is `CBError.connectionTimeout`.
let cbFailure = NSError(domain: "CBErrorDomain", code: 6, userInfo: nil)

/// The effects every terminal transition ends with, whatever ended the connection.
///
/// Asserting against this rather than against a literal per test is the point: the machine
/// tears a connection down one way, so a path that forgot a step fails loudly.
func terminalEffects(_ reason: DisconnectReason) -> [ConnectionEffect] {
    [
        .cancelConnect,
        .endPendingOperations(reason: reason),
        .endSubscriptions(reason: reason),
        .invalidateDiscoveryCache
    ]
}
