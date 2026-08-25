// The clock seam. The real one is three lines over DispatchQueue; what needs testing is the
// fake, because every reconnect test in the library is going to trust it.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("The test scheduler")
struct SchedulerTests {
    /// Somewhere for scheduled work to leave a mark.
    private final class Fired: @unchecked Sendable {
        private(set) var labels: [String] = []

        func mark(_ label: String) {
            labels.append(label)
        }
    }

    @Test("work does not run before its time")
    func notEarly() {
        let scheduler = TestScheduler()
        let fired = Fired()
        _ = scheduler.schedule(after: .seconds(10)) { fired.mark("timeout") }

        scheduler.advance(by: .seconds(9))

        #expect(fired.labels.isEmpty)
        #expect(scheduler.pendingDelays == [.seconds(1)])
    }

    @Test("work runs once its time comes")
    func runsWhenDue() {
        let scheduler = TestScheduler()
        let fired = Fired()
        _ = scheduler.schedule(after: .seconds(10)) { fired.mark("timeout") }

        scheduler.advance(by: .seconds(10))

        #expect(fired.labels == ["timeout"])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("work runs in due order, not scheduling order")
    func runsInDueOrder() {
        let scheduler = TestScheduler()
        let fired = Fired()
        _ = scheduler.schedule(after: .seconds(30)) { fired.mark("deadline") }
        _ = scheduler.schedule(after: .seconds(5)) { fired.mark("rearm") }

        scheduler.advance(by: .seconds(60))

        #expect(fired.labels == ["rearm", "deadline"])
    }

    @Test("cancelled work never runs")
    func cancellation() {
        // The property `disconnect()` depends on: no zombie timers (PLAN.md §4, edge cases).
        let scheduler = TestScheduler()
        let fired = Fired()
        let work = scheduler.schedule(after: .seconds(10)) { fired.mark("timeout") }

        work.cancel()
        scheduler.advance(by: .seconds(300))

        #expect(fired.labels.isEmpty)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("work scheduled while advancing still runs in the same advance")
    func reschedulingDuringAnAdvance() {
        // A re-arm cadence schedules its own next cycle, so one advance has to cover several.
        let scheduler = TestScheduler()
        let fired = Fired()
        func rearm(_ count: Int) {
            guard count < 3 else { return }
            _ = scheduler.schedule(after: .seconds(30)) {
                fired.mark("arm \(count + 2)")
                rearm(count + 1)
            }
        }
        rearm(0)

        scheduler.advance(by: .seconds(90))

        #expect(fired.labels == ["arm 2", "arm 3", "arm 4"])
    }

    @Test("the clock remembers where it got to")
    func clockAccumulates() {
        let scheduler = TestScheduler()
        let fired = Fired()
        _ = scheduler.schedule(after: .seconds(10)) { fired.mark("first") }

        scheduler.advance(by: .seconds(6))
        scheduler.advance(by: .seconds(6))

        #expect(fired.labels == ["first"])
        #expect(scheduler.now == .seconds(12))
    }
}
