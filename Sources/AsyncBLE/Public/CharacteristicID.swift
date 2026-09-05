// The library's names for the one CoreBluetooth type that appears in its public API.
//
// `CBUUID` in a characteristic position is spelled `CharacteristicID`; in a service position,
// `ServiceID`. Same underlying type, two roles, so that no consumer has to import CoreBluetooth
// merely to name what it is addressing.

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
/// > Note: Service identifiers are spelled ``ServiceID``. It is the same underlying type in a
/// > different role, and naming a service after a characteristic would be worse than giving it
/// > its own name.
public typealias CharacteristicID = CBUUID

/// The identifier of a GATT service.
///
/// ``CharacteristicID``'s counterpart: the same `CBUUID`, named for the other role it plays.
/// Filtering a scan is the common case, and filtering is strongly preferred over an unfiltered
/// scan — so this is what keeps a real app from having to import CoreBluetooth.
///
/// ```swift
/// let heartRate = ServiceID(string: "180D")
/// for await device in try await central.scan(services: [heartRate]) { ... }
/// ```
public typealias ServiceID = CBUUID
