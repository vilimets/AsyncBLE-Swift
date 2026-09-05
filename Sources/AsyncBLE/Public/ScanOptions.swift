// Scan parameters: service UUID filter and the allow-duplicates flag.

@preconcurrency import CoreBluetooth

/// How a scan behaves: what to look for, and how often to report it.
public struct ScanOptions: Sendable, Equatable {
    /// The service UUIDs a peripheral must advertise to be reported. Empty reports everything.
    ///
    /// Filtering is strongly preferred: an unfiltered scan is significantly more expensive on
    /// battery, and it does not work at all while the app is in the background. Empty is for
    /// development and for genuine "show me everything" tools.
    ///
    /// > Important: Empty means *everything*, not *nothing*. Filtering on a list that turned
    /// > out to be empty starts an unfiltered scan, so check before you scan if that would
    /// > surprise you.
    public var services: [ServiceID]

    /// Whether to report every advertising packet, or only the first one per peripheral.
    ///
    /// `false` (the default) yields one ``Discovery`` per peripheral, which is what a scan
    /// list wants. Set `true` to track RSSI or changing advertisement data as the peripheral
    /// keeps advertising — at a real cost in wakeups.
    public var allowDuplicates: Bool

    /// Creates scan options.
    ///
    /// - Parameters:
    ///   - services: Service UUIDs to filter on. Empty reports every peripheral.
    ///   - allowDuplicates: Whether to report repeated advertising packets.
    public init(services: [ServiceID] = [], allowDuplicates: Bool = false) {
        self.services = services
        self.allowDuplicates = allowDuplicates
    }
}
