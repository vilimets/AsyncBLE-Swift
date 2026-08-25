// One caller's scan, and the arithmetic for running several of them on one radio.
//
// CoreBluetooth has exactly one scan: calling `scanForPeripherals` again replaces the previous
// filter rather than adding to it. But `Central.scan(_:)` hands back an independent stream per
// call, and two screens scanning at once is ordinary — so the library scans for the union of
// what everyone asked for and gives each session only what it asked for.
//
// Queue-confined: created, delivered to and finished on the library queue.

@preconcurrency import CoreBluetooth
import Foundation

/// One `Central.scan(_:)` call: its filter, its stream, and what it has already reported.
final class ScanSession: @unchecked Sendable {
    /// Identifies the session in the bridge's table, and in its own termination handler.
    let id = UUID()

    /// What this caller asked for. Not what the radio was told, which is everyone's union.
    let options: ScanOptions

    private let continuation: AsyncStream<Discovery>.Continuation
    private var reported: Set<UUID> = []

    init(options: ScanOptions, continuation: AsyncStream<Discovery>.Continuation) {
        self.options = options
        self.continuation = continuation
    }

    /// Offers a discovery to this session, which takes it only if it asked for it.
    ///
    /// Two filters run, not one. The radio's filter is the union of every live session's, so a
    /// packet can arrive here because some *other* session wanted it; and duplicates can arrive
    /// because some other session wanted those. Both are filtered out again per session.
    func offer(_ discovery: Discovery) {
        guard matches(discovery.advertisementData) else { return }
        if !options.allowDuplicates {
            guard reported.insert(discovery.peripheralID).inserted else { return }
        }
        continuation.yield(discovery)
    }

    /// Ends this caller's stream.
    func finish() {
        continuation.finish()
    }

    private func matches(_ advertisement: AdvertisementData) -> Bool {
        guard let wanted = options.services, !wanted.isEmpty else { return true }
        // The overflow area counts: a UUID that did not fit in the packet is still advertised,
        // and CoreBluetooth's own filter matches on it, so ours has to as well.
        let advertised = Set(advertisement.serviceUUIDs).union(advertisement.overflowServiceUUIDs)
        return !advertised.isDisjoint(with: wanted)
    }
}

/// What to ask the radio for, given every session currently running.
struct ScanPlan: Equatable {
    /// The union of every session's filter — or `nil` if any session is unfiltered, because an
    /// unfiltered scan is a superset of every filtered one.
    let services: [CBUUID]?

    /// `true` if any session wants repeat packets. Sessions that do not want them de-duplicate
    /// their own stream instead, which costs nothing but the wakeups the other session asked for.
    let allowDuplicates: Bool

    /// Computes the plan for a set of sessions.
    ///
    /// Order is normalized so that an unchanged set of sessions produces an equal plan, which
    /// is what lets the bridge skip re-issuing a scan that would not change anything.
    init(sessions: some Collection<ScanSession>) {
        allowDuplicates = sessions.contains { $0.options.allowDuplicates }
        if sessions.contains(where: { ($0.options.services ?? []).isEmpty }) {
            services = nil
        } else {
            let union = sessions.reduce(into: Set<CBUUID>()) { $0.formUnion($1.options.services ?? []) }
            services = union.sorted { $0.uuidString < $1.uuidString }
        }
    }
}
