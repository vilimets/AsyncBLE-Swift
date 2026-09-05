// Notification streams: fan-out per characteristic, unsubscribe when the last one leaves, and
// the bookkeeping that carries a subscription across a reconnect (PLAN.md §7 Q2, Q8).

@preconcurrency import CoreBluetooth
import Foundation
import Testing

@testable import AsyncBLE

@Suite("The subscription registry")
struct SubscriptionRegistryTests {
    private let measurement = CBUUID(string: "2A37")
    private let batteryLevel = CBUUID(string: "2A19")

    private func makeRegistry() -> (registry: SubscriptionRegistry, library: LibraryQueue) {
        let library = LibraryQueue(label: "test.subscriptions")
        return (SubscriptionRegistry(library: library), library)
    }

    @Test("a subscriber receives what the characteristic notifies")
    func deliversValues() async {
        let (registry, _) = makeRegistry()
        let (_, stream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        var values = stream.makeAsyncIterator()

        registry.deliver(Data([0x01]), for: measurement)

        let value = try? await values.next()
        #expect(value == Data([0x01]))
    }

    @Test("two subscribers to one characteristic both get every value")
    func fansOut() async {
        // CoreBluetooth has one notify flag per characteristic, so a second subscriber has to
        // be a fan-out rather than a second subscription.
        let (registry, _) = makeRegistry()
        let (_, first) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        let (_, second) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        var firstValues = first.makeAsyncIterator()
        var secondValues = second.makeAsyncIterator()

        registry.deliver(Data([0xAA]), for: measurement)

        let fromFirst = try? await firstValues.next()
        let fromSecond = try? await secondValues.next()
        #expect(fromFirst == Data([0xAA]))
        #expect(fromSecond == Data([0xAA]))
        #expect(registry.count == 2)
    }

    @Test("a value for another characteristic goes to nobody")
    func deliveryIsPerCharacteristic() async {
        let (registry, _) = makeRegistry()
        let (_, stream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)

        registry.deliver(Data([0x01]), for: batteryLevel)

        #expect(registry.hasSubscribers(for: measurement))
        #expect(!registry.hasSubscribers(for: batteryLevel))
        withExtendedLifetime(stream) {}
    }

    @Test("the notify flag is turned off only when the last subscriber leaves")
    func lastSubscriberUnsubscribes() {
        let (registry, _) = makeRegistry()
        let unsubscribed = Recorder()
        registry.onLastSubscriberRemoved = { unsubscribed.append($0) }
        let (first, firstStream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        let (second, secondStream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)

        registry.remove(first)
        #expect(unsubscribed.values.isEmpty)

        registry.remove(second)
        #expect(unsubscribed.values == [measurement])
        #expect(!registry.hasSubscribers(for: measurement))
        withExtendedLifetime((firstStream, secondStream)) {}
    }

    @Test("dropping a stream unsubscribes it")
    func terminationUnsubscribes() async {
        // Documented on notifications(for:): ending iteration unsubscribes, with no ceremony.
        let (registry, library) = makeRegistry()
        var stream: AsyncThrowingStream<Data, Error>? = library.sync {
            registry.subscribe(to: measurement, bufferingPolicy: .unbounded).stream
        }
        #expect(registry.count == 1)

        stream = nil
        library.sync {}  // let the termination hop land

        #expect(library.sync { registry.count } == 0)
    }

    @Test("a subscription that cannot be restored throws")
    func failingASubscriptionThrows() async {
        // PLAN.md §7 Q8: the link came back without the characteristic. A stream that just
        // finished would be indistinguishable from a sensor that went quiet.
        let (registry, _) = makeRegistry()
        let (_, stream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        var values = stream.makeAsyncIterator()

        registry.fail(measurement, with: BluetoothError.characteristicNotFound(measurement))

        let thrown = await errorThrown { try await values.next() }
        #expect(thrown == .characteristicNotFound(measurement))
        #expect(!registry.hasSubscribers(for: measurement))
    }

    @Test("a user-initiated disconnect finishes streams rather than throwing")
    func userDisconnectFinishes() async {
        // The caller asked for this. An error here would be noise.
        let (registry, _) = makeRegistry()
        let (_, stream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        var values = stream.makeAsyncIterator()

        registry.endAll(reason: .userInitiated)

        let ended = try? await values.next()
        #expect(ended == nil)
    }

    @Test("any other ending throws the reason", arguments: [
        DisconnectReason.reconnectGaveUp,
        .linkLost,
        .bluetoothUnavailable(reason: .poweredOff)
    ])
    func otherEndingsThrow(reason: DisconnectReason) async {
        let (registry, _) = makeRegistry()
        let (_, stream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        var values = stream.makeAsyncIterator()

        registry.endAll(reason: reason)

        let thrown = await errorThrown { try await values.next() }
        #expect(thrown == .disconnected(reason))
    }

    @Test("a drop marks every live subscription for restore")
    func markForRestore() {
        let (registry, _) = makeRegistry()
        let (_, first) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        let (_, second) = registry.subscribe(to: batteryLevel, bufferingPolicy: .unbounded)

        registry.markForRestore()

        #expect(registry.pendingRestore == [measurement, batteryLevel])
        withExtendedLifetime((first, second)) {}
    }

    @Test("restoring one characteristic leaves the others still pending")
    func markRestored() {
        let (registry, _) = makeRegistry()
        let (_, first) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        let (_, second) = registry.subscribe(to: batteryLevel, bufferingPolicy: .unbounded)
        registry.markForRestore()

        registry.markRestored(measurement)

        #expect(registry.pendingRestore == [batteryLevel])
        withExtendedLifetime((first, second)) {}
    }

    @Test("a stream survives the outage and keeps yielding afterwards")
    func streamSurvivesAReconnect() async {
        // The promise the whole design rests on: a subscription is to a characteristic, not to
        // a link. The same stream, either side of a drop.
        let (registry, _) = makeRegistry()
        let (_, stream) = registry.subscribe(to: measurement, bufferingPolicy: .unbounded)
        var values = stream.makeAsyncIterator()
        registry.deliver(Data([0x01]), for: measurement)

        registry.markForRestore()
        registry.markRestored(measurement)
        registry.deliver(Data([0x02]), for: measurement)

        let before = try? await values.next()
        let after = try? await values.next()
        #expect(before == Data([0x01]))
        #expect(after == Data([0x02]))
    }
}

/// Collects the characteristics the registry reported as fully unsubscribed.
private final class Recorder: @unchecked Sendable {
    private(set) var values: [CBUUID] = []

    func append(_ uuid: CBUUID) {
        values.append(uuid)
    }
}
