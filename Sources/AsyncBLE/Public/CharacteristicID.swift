// The library's name for the one CoreBluetooth type that appears in its public API.
// See PLAN.md §3 invariant 1 and §7 Q23.

@preconcurrency import CoreBluetooth

/// The identifier of a GATT characteristic.
///
/// This is `CBUUID` under a name that says what the library uses it for. It stays Apple's type
/// rather than a wrapper: `CBUUID` is what makes 16-bit shorthand and full 128-bit UUIDs
/// interchangeable, and re-implementing that equivalence would add friction without safety.
///
/// The alias exists so that addressing a characteristic does not oblige you to import
/// CoreBluetooth. The `Example/` app builds without importing it at all, which is the claim
/// this library makes about itself and therefore one worth being able to demonstrate.
///
/// ```swift
/// let measurement = CharacteristicID(string: "2A37")
/// let data = try await connection.read(measurement)
/// ```
///
/// > Note: Service identifiers are spelled `CBUUID`, not `CharacteristicID` — ``ScanOptions``
/// > and ``AdvertisementData`` hold the same underlying type in a different role, and naming
/// > those after characteristics would be worse than naming them after Apple's type.
public typealias CharacteristicID = CBUUID
