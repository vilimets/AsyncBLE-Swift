// The per-connection FIFO that all reads and writes pass through.
//
// Actor isolation alone does not order anything: `write` suspends for discovery and for
// `canSendWriteWithoutResponse`, and reentrancy at those points lets concurrent callers
// interleave. This restores call order — which costs almost nothing, since ATT permits one
// outstanding request per connection anyway.
//
// On a drop, queued operations fail in order with `.disconnected` before any new I/O is taken.
//
// Every method here is synchronous and queue-confined, which is the whole trick: a caller takes
// its place in line *before* its first suspension point, so the order callers arrive in is the
// order they execute in. An async `enqueue` would hop first and be reordered by the hop — the
// exact bug this type exists to prevent. The awaiting is done by the `Connection` actor, whose
// executor is this same queue.
//
// (Named IOQueue rather than an OperationQueue, because shadowing
// Foundation's OperationQueue inside the module would be a trap for a later reader.)

import Foundation

/// A serial FIFO for a connection's reads and writes.
final class IOQueue: @unchecked Sendable {
    /// How a waiting caller is let go: with its turn, or with the reason it will never get one.
    ///
    /// A closure rather than a `CheckedContinuation`, so that the queue's ordering rules can be
    /// tested directly instead of only through an actor. The `Connection` actor passes one that
    /// resumes its continuation.
    typealias Resume = @Sendable (Result<Void, Error>) -> Void

    /// One caller's place in line.
    ///
    /// A class so that identity, rather than an index, survives other tickets being removed.
    final class Ticket: @unchecked Sendable {
        fileprivate var resume: Resume?
        fileprivate var isCancelled = false

        fileprivate init() {}
    }

    private var line: [Ticket] = []

    /// Takes a place in line. Synchronous, and that is the point.
    ///
    /// - Returns: The ticket to wait on and, eventually, to hand back to ``complete(_:)``.
    func enqueue() -> Ticket {
        let ticket = Ticket()
        line.append(ticket)
        return ticket
    }

    /// Attaches the caller's resumption to its ticket, letting it straight through if it is
    /// already at the head of the line.
    func attach(_ resume: @escaping Resume, to ticket: Ticket) {
        if ticket.isCancelled {
            resume(.failure(CancellationError()))
            return
        }
        guard line.first !== ticket else {
            resume(.success(()))
            return
        }
        ticket.resume = resume
    }

    /// Gives up a place in line, whether the operation ran or not.
    ///
    /// Safe to call for a ticket that never reached the head — a caller whose task was
    /// cancelled while queued, or whose operation failed before starting.
    func complete(_ ticket: Ticket) {
        guard let index = line.firstIndex(where: { $0 === ticket }) else { return }
        line.remove(at: index)
        startHeadIfNeeded()
    }

    /// Abandons a queued operation without running it, because its caller went away.
    func cancel(_ ticket: Ticket) {
        ticket.isCancelled = true
        guard let resume = ticket.resume else {
            // Not yet waiting, or already running. `complete` will tidy up either way.
            return
        }
        ticket.resume = nil
        resume(.failure(CancellationError()))
    }

    /// Fails everything in line, in line order, and tells the caller what is running.
    ///
    /// The order matters: queued writes must fail *before* a reconnect is
    /// armed, so a command composed against the old link cannot land on the new one.
    ///
    /// - Parameter error: What each waiting caller is resumed with.
    /// - Returns: The ticket at the head of the line, if an operation was in flight. Its caller
    ///   is already past the queue and has to be failed wherever it is now suspended.
    @discardableResult
    func failAll(with error: Error) -> Ticket? {
        let abandoned = line
        line.removeAll()
        var running: Ticket?

        for (index, ticket) in abandoned.enumerated() {
            ticket.isCancelled = true
            if let resume = ticket.resume {
                ticket.resume = nil
                resume(.failure(error))
            } else if index == 0 {
                // Nothing to resume, and at the head: it was let through and is running.
                running = ticket
            }
        }
        return running
    }

    /// How many callers are queued, including the one running. For tests and assertions.
    var depth: Int { line.count }

    /// Whether any caller is waiting or running.
    var isEmpty: Bool { line.isEmpty }

    private func startHeadIfNeeded() {
        guard let head = line.first, let resume = head.resume else { return }
        head.resume = nil
        resume(.success(()))
    }
}
