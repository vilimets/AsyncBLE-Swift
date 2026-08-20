// A peripheral seen during a scan: identifier, name, RSSI, typed advertisement data.

import Foundation

/// A peripheral observed during a scan.
///
/// A discovery is a snapshot of one advertising packet, not a live object. Scanning with
/// ``ScanOptions/allowDuplicates`` produces a new value each time the peripheral advertises,
/// which is how you track RSSI over time.
///
/// Pass ``peripheralID`` — or the discovery itself — to ``BLECentral/connect(_:timeout:)``.
public struct Discovery: Sendable, Equatable, Identifiable {
    /// The peripheral's identifier, stable for this device across app launches.
    ///
    /// This is CoreBluetooth's per-device, per-app identifier, not the hardware MAC address,
    /// which iOS never exposes. Persist it to reconnect to a known peripheral later.
    public let peripheralID: UUID

    /// The peripheral's advertised or cached name, if it has one.
    public let name: String?

    /// Received signal strength in dBm, or `nil` when unavailable.
    ///
    /// Roughly -30 (touching) to -100 (at the edge of range). CoreBluetooth reports the
    /// sentinel value `127` when it has no reading; that is surfaced here as `nil` rather
    /// than as an absurd signal strength.
    public let rssi: Int?

    /// The parsed contents of the advertising packet.
    public let advertisementData: AdvertisementData

    /// The peripheral's identifier, for `Identifiable` conformance in SwiftUI lists.
    public var id: UUID { peripheralID }

    /// Creates a discovery.
    ///
    /// The library produces these while scanning; this initializer exists so tests and
    /// SwiftUI previews can build a scan list without a radio.
    ///
    /// - Parameters:
    ///   - peripheralID: The peripheral's identifier.
    ///   - name: The peripheral's name, if any.
    ///   - rssi: Received signal strength in dBm, or `nil` when unavailable.
    ///   - advertisementData: The parsed advertising packet.
    public init(
        peripheralID: UUID,
        name: String? = nil,
        rssi: Int? = nil,
        advertisementData: AdvertisementData = AdvertisementData()
    ) {
        self.peripheralID = peripheralID
        self.name = name
        self.rssi = rssi
        self.advertisementData = advertisementData
    }
}
