// Typed wrapper over CoreBluetooth's `[String: Any]` advertisement dictionary.
//
// Parsing lives here so no `Any` reaches the public API.

@preconcurrency import CoreBluetooth
import Foundation

/// The contents of a peripheral's advertising packet, parsed into typed properties.
///
/// CoreBluetooth reports advertisement data as `[String: Any]` keyed by `CBAdvertisementData*`
/// constants, with values that are variously `String`, `Data`, `NSNumber`, or `[CBUUID]`.
/// This type does that unwrapping once, so no `Any` reaches the public API.
///
/// Every property is optional or empty when the peripheral did not advertise it. A packet is
/// at most 31 bytes, so most peripherals advertise only a small subset.
public struct AdvertisementData: Sendable, Equatable {
    /// The local name from the advertising packet, if present.
    ///
    /// This can differ from `CBPeripheral.name`, which may come from a cached GAP name
    /// read over the connection. Prefer this value while scanning.
    public let localName: String?

    /// Manufacturer-specific data, if present.
    ///
    /// The first two bytes are the Bluetooth SIG company identifier, little-endian; the
    /// remainder is vendor-defined. The library does not split them — decoding is the
    /// caller's job, because the layout after the company identifier is not standardized.
    public let manufacturerData: Data?

    /// Per-service advertised data, keyed by service UUID.
    public let serviceData: [ServiceID: Data]

    /// Service UUIDs advertised in the packet.
    public let serviceUUIDs: [ServiceID]

    /// Service UUIDs that did not fit in the advertising packet and were placed in the
    /// overflow area.
    ///
    /// These are only visible to an iOS device scanning for those specific UUIDs, and only
    /// when the advertiser is also an Apple device.
    public let overflowServiceUUIDs: [ServiceID]

    /// Service UUIDs the peripheral is soliciting — services it wants a central to provide.
    public let solicitedServiceUUIDs: [ServiceID]

    /// The transmit power level in dBm, if advertised.
    ///
    /// Combined with ``Discovery/rssi`` this gives a rough path loss, which is a better
    /// distance proxy than RSSI alone. Few peripherals advertise it.
    public let txPowerLevel: Int?

    /// Whether the peripheral advertised itself as connectable, if it said either way.
    ///
    /// `nil` means the packet carried no connectable flag, which is not the same as `false`.
    public let isConnectable: Bool?

    /// Creates advertisement data from already-parsed values.
    ///
    /// The library builds these itself while scanning; this initializer exists so tests and
    /// SwiftUI previews can construct a ``Discovery`` without a radio.
    ///
    /// - Parameters:
    ///   - localName: The local name from the advertising packet.
    ///   - manufacturerData: Manufacturer-specific data, company identifier first.
    ///   - serviceData: Per-service advertised data, keyed by service UUID.
    ///   - serviceUUIDs: Service UUIDs advertised in the packet.
    ///   - overflowServiceUUIDs: Service UUIDs placed in the overflow area.
    ///   - solicitedServiceUUIDs: Service UUIDs the peripheral is soliciting.
    ///   - txPowerLevel: The transmit power level in dBm.
    ///   - isConnectable: Whether the peripheral advertised itself as connectable.
    public init(
        localName: String? = nil,
        manufacturerData: Data? = nil,
        serviceData: [ServiceID: Data] = [:],
        serviceUUIDs: [ServiceID] = [],
        overflowServiceUUIDs: [ServiceID] = [],
        solicitedServiceUUIDs: [ServiceID] = [],
        txPowerLevel: Int? = nil,
        isConnectable: Bool? = nil
    ) {
        self.localName = localName
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.serviceUUIDs = serviceUUIDs
        self.overflowServiceUUIDs = overflowServiceUUIDs
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
        self.txPowerLevel = txPowerLevel
        self.isConnectable = isConnectable
    }
}

extension AdvertisementData {
    /// Parses CoreBluetooth's advertisement dictionary.
    ///
    /// The single place in the library where `Any` is unwrapped. Unknown keys are ignored;
    /// values of an unexpected type are treated as absent rather than trapping, because the
    /// dictionary comes from a remote device and must not be trusted to be well-formed.
    init(rawAdvertisementData raw: [String: Any]) {
        self.init(
            localName: raw[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: raw[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceData: raw[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:],
            serviceUUIDs: raw[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [],
            overflowServiceUUIDs: raw[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [],
            solicitedServiceUUIDs: raw[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [],
            txPowerLevel: (raw[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (raw[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
    }
}
