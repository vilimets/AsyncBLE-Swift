// A characteristic identifier that remembers what its bytes mean.

@preconcurrency import CoreBluetooth

/// A characteristic addressed by UUID, carrying the type of the value it holds.
///
/// Declaring one in your own namespace turns every use of that characteristic into a typed
/// call, and puts the UUID in exactly one place:
///
/// ```swift
/// enum HeartRate {
///     static let measurement = Characteristic<Measurement>("2A37")
///     static let controlPoint = Characteristic<Command>("2A39")
/// }
///
/// let beats = try await connection.read(HeartRate.measurement)
/// try await connection.write(.reset, to: HeartRate.controlPoint)
/// ```
///
/// `Value` is a phantom type — nothing about it is stored, and nothing is sent over the air
/// because of it. It selects the decoding, and it prevents writing a `Command` to a
/// characteristic that holds a `Measurement`.
///
/// The untyped API is unchanged and remains the lower layer: ``Connection/read(_:)->Data`` and its
/// siblings still take a bare ``CharacteristicID`` and deal in `Data`. `Characteristic<Data>`
/// is the same thing spelled typed, if you want one style throughout.
public struct Characteristic<Value>: Sendable, Equatable, Hashable {
    /// The characteristic's UUID.
    public let id: CharacteristicID

    /// Wraps an identifier you already have.
    public init(_ id: CharacteristicID) {
        self.id = id
    }

    /// Builds one from a UUID string — `"2A37"`, or a full 128-bit UUID.
    ///
    /// - Parameter uuidString: A 16-, 32- or 128-bit UUID string.
    ///
    /// > Important: This traps on a malformed string, because `CBUUID(string:)` does and this
    /// > library does not paper over Apple's semantics. It is meant for literals, where a bad
    /// > value is a programming error you want to hear about on the first run. Build the
    /// > ``CharacteristicID`` yourself when the string comes from input you do not control.
    public init(_ uuidString: String) {
        self.id = CharacteristicID(string: uuidString)
    }
}

// Equality and hashing are the UUID's: derived conformances are generated from stored property
// types, and `Value` is a phantom that stores nothing, so synthesis does not constrain it.
extension Characteristic: CustomStringConvertible {
    public var description: String { id.uuidString }
}
