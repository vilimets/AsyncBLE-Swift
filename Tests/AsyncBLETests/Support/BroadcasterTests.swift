// The three promises `Central.adapterStates` and `Connection.states` make in their doc
// comments: an independent stream per caller, the current value first, and unsubscribing when
// iteration ends.

import Foundation
import Testing

@testable import AsyncBLE

@Suite("The stream broadcaster")
struct BroadcasterTests {
    @Test("a new subscriber gets the current value before anything else happens")
    func replaysCurrentValue() async {
        // Without this, an app that subscribes a moment after connecting would sit blank until
        // the next transition — which for a stable link may be never.
        let broadcaster = Broadcaster(1)
        var iterator = broadcaster.stream().makeAsyncIterator()

        let first = await iterator.next()
        #expect(first == 1)

        broadcaster.send(2)
        let second = await iterator.next()
        #expect(second == 2)
    }

    @Test("every subscriber gets every value")
    func fansOut() async {
        let broadcaster = Broadcaster("a")
        var first = broadcaster.stream().makeAsyncIterator()
        var second = broadcaster.stream().makeAsyncIterator()
        _ = await first.next()
        _ = await second.next()

        broadcaster.send("b")

        let fromFirst = await first.next()
        let fromSecond = await second.next()
        #expect(fromFirst == "b")
        #expect(fromSecond == "b")
    }

    @Test("a late subscriber sees the latest value, not the history")
    func lateSubscriberSeesLatest() async {
        let broadcaster = Broadcaster(0)
        broadcaster.send(1)
        broadcaster.send(2)

        var iterator = broadcaster.stream().makeAsyncIterator()
        let value = await iterator.next()
        #expect(value == 2)
        #expect(broadcaster.current == 2)
    }

    @Test("dropping a stream unsubscribes it")
    func terminationUnsubscribes() async {
        let broadcaster = Broadcaster(0)
        var stream: AsyncStream<Int>? = broadcaster.stream()
        var iterator = stream?.makeAsyncIterator()
        _ = await iterator?.next()
        #expect(broadcaster.subscriberCount == 1)

        iterator = nil
        stream = nil
        // Termination is delivered by AsyncStream's own teardown; give it a turn to land.
        await Task.yield()
        #expect(broadcaster.subscriberCount == 0)
    }

    @Test("finishing ends every live stream")
    func finishEndsStreams() async {
        let broadcaster = Broadcaster(0)
        var iterator = broadcaster.stream().makeAsyncIterator()
        _ = await iterator.next()

        broadcaster.finish()

        let afterFinish = await iterator.next()
        #expect(afterFinish == nil)
        #expect(broadcaster.hasFinished)
    }

    @Test("subscribing after the end yields the final value, then ends")
    func lateSubscriberAfterFinish() async {
        // A connection that has reached `disconnected` still owes a late observer the reason.
        let broadcaster = Broadcaster(7)
        broadcaster.finish()

        var iterator = broadcaster.stream().makeAsyncIterator()
        let value = await iterator.next()
        let end = await iterator.next()
        #expect(value == 7)
        #expect(end == nil)
    }

    @Test("a value sent after the end is ignored")
    func sendAfterFinishIsIgnored() {
        // Late CoreBluetooth callbacks are routine. None of them may reopen a closed stream.
        let broadcaster = Broadcaster(1)
        broadcaster.finish()
        broadcaster.send(2)
        #expect(broadcaster.current == 1)
    }

    @Test("finishing twice is harmless")
    func finishIsIdempotent() {
        let broadcaster = Broadcaster(1)
        broadcaster.finish()
        broadcaster.finish()
        #expect(broadcaster.hasFinished)
    }
}
