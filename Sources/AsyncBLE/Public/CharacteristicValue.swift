// Decoding and encoding for typed characteristics (PLAN.md §7 Q24).
//
// Two protocols rather than one: plenty of characteristics travel in a single direction — a
// measurement is only ever read, a control point only ever written — and requiring the unused
// half would mean writing a meaningless implementation to satisfy the compiler.

import Foundation

/// A value that can be decoded from the bytes a characteristic carries.
///
/// Conform your own types to read them directly:
///
/// ```swift
/// struct HeartRate: CharacteristicDecodable {
///     let beatsPerMinute: Int
///
///     init(characteristicData data: Data) throws {
///         guard let flags = data.first else {
///             throw CharacteristicDecodingError.unexpectedLength(expected: 2, actual: data.count)
///         }
///         // Bit 0 of the flags byte says whether the value is 8- or 16-bit.
///         beatsPerMinute = flags & 0x01 == 0 ? Int(data[1]) : Int(UInt16(data[1]) | UInt16(data[2]) << 8)
///     }
/// }
/// ```
///
/// Throwing from the initializer surfaces at the call site as
/// ``BluetoothError/decodingFailed(characteristic:underlying:)``, with the error you threw
/// carried as the underlying cause.
public protocol CharacteristicDecodable: Sendable {
    /// Decodes the value from the bytes the peripheral reported.
    ///
    /// - Parameter characteristicData: The characteristic's current bytes.
    /// - Throws: Anything. The library wraps it rather than interpreting it.
    init(characteristicData: Data) throws
}

/// A value that can be encoded into the bytes a characteristic expects.
public protocol CharacteristicEncodable: Sendable {
    /// The bytes to write.
    var characteristicData: Data { get }
}

/// A value that travels in both directions.
///
/// Most application types want this; the halves exist separately for characteristics that are
/// only ever read or only ever written.
public typealias CharacteristicValue = CharacteristicDecodable & CharacteristicEncodable

/// What the built-in conformances throw.
///
/// Your own types are free to throw anything;
/// ``BluetoothError/decodingFailed(characteristic:underlying:)`` carries it either way.
public enum CharacteristicDecodingError: Error, Sendable, Equatable {
    /// The peripheral reported a different number of bytes than the type needs.
    case unexpectedLength(expected: Int, actual: Int)

    /// The bytes are not valid UTF-8.
    case invalidUTF8
}

// MARK: - Built-in conformances

extension Data: CharacteristicValue {
    /// The bytes, unchanged — the escape hatch from typed values back to raw ones.
    public init(characteristicData: Data) throws {
        self = characteristicData
    }

    public var characteristicData: Data { self }
}

extension String: CharacteristicValue {
    /// Decodes UTF-8, which is what the Bluetooth SIG's string characteristics use.
    public init(characteristicData: Data) throws {
        guard let decoded = String(data: characteristicData, encoding: .utf8) else {
            throw CharacteristicDecodingError.invalidUTF8
        }
        self = decoded
    }

    public var characteristicData: Data { Data(utf8) }
}

// Integers are little-endian: the Bluetooth Core Specification transmits multi-octet fields
// least-significant octet first, so a `UInt16` characteristic reading `[0x2C, 0x01]` is 300.
extension CharacteristicDecodable where Self: FixedWidthInteger {
    /// Decodes exactly `MemoryLayout<Self>.size` little-endian bytes.
    ///
    /// - Throws: ``CharacteristicDecodingError/unexpectedLength(expected:actual:)`` if the
    ///   peripheral reported a different width. A short read is a different value, not a
    ///   smaller one, so guessing would be worse than failing.
    public init(characteristicData: Data) throws {
        let width = MemoryLayout<Self>.size
        guard characteristicData.count == width else {
            throw CharacteristicDecodingError.unexpectedLength(
                expected: width,
                actual: characteristicData.count
            )
        }
        var value: Self = 0
        withUnsafeMutableBytes(of: &value) { raw in
            _ = characteristicData.copyBytes(to: raw.bindMemory(to: UInt8.self))
        }
        self = Self(littleEndian: value)
    }
}

extension CharacteristicEncodable where Self: FixedWidthInteger {
    /// The value as little-endian bytes.
    public var characteristicData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}

extension UInt8: CharacteristicValue {}
extension UInt16: CharacteristicValue {}
extension UInt32: CharacteristicValue {}
extension UInt64: CharacteristicValue {}
extension Int8: CharacteristicValue {}
extension Int16: CharacteristicValue {}
extension Int32: CharacteristicValue {}
extension Int64: CharacteristicValue {}
