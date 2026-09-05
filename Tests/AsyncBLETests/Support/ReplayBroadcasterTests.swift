// The replaying fan-out behind `Central.restoredConnections`.
//
// The difference from `Broadcaster` is the whole point: it replays everything, not the latest,
// because restoration is a list with no current value and every subscriber is a late one.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("ReplayBroadcaster")
struct ReplayBroadcasterTests {
    @Test("a subscriber sees everything sent before it arrived, in order")
    func replaysTheWholeBacklog() async {
        let broadcaster = ReplayBroadcaster<Int>()
        broadcaster.send(1)
        broadcaster.send(2)
        broadcaster.send(3)

        var iterator = broadcaster.stream().makeAsyncIterator()

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
    }

    @Test("a subscriber sees the backlog and then what comes next")
    func replaysThenContinues() async {
        let broadcaster = ReplayBroadcaster<Int>()
        broadcaster.send(1)
        var iterator = broadcaster.stream().makeAsyncIterator()

        #expect(await iterator.next() == 1)
        broadcaster.send(2)
        #expect(await iterator.next() == 2)
    }

    @Test("every subscriber gets its own copy")
    func fansOut() async {
        let broadcaster = ReplayBroadcaster<Int>()
        var first = broadcaster.stream().makeAsyncIterator()
        var second = broadcaster.stream().makeAsyncIterator()

        broadcaster.send(7)

        #expect(await first.next() == 7)
        #expect(await second.next() == 7)
    }

    @Test("an empty broadcaster hands out a stream that simply waits")
    func emptyBacklogYieldsNothingYet() async {
        let broadcaster = ReplayBroadcaster<Int>()
        var iterator = broadcaster.stream().makeAsyncIterator()

        broadcaster.send(1)

        #expect(await iterator.next() == 1)
        #expect(broadcaster.replay == [1])
    }

    @Test("dropping a stream unsubscribes it")
    func unsubscribesOnTermination() async {
        // A subscriber that went away and was not removed is a leak nothing else would notice.
        let broadcaster = ReplayBroadcaster<Int>()
        do {
            let stream = broadcaster.stream()
            #expect(broadcaster.subscriberCount == 1)
            withExtendedLifetime(stream) {}
        }

        await waitUntil { broadcaster.subscriberCount == 0 }
        #expect(broadcaster.subscriberCount == 0)
    }
}
