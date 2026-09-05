// Typed I/O, layered strictly over the untyped API.
//
// Every method here forwards to its `CharacteristicID` counterpart and then encodes or decodes.
// Nothing about the FIFO, discovery, reconnect or subscription-restore behaviour changes —
// which is the point: typed calls take their turn in the same queue as untyped ones, because
// they *are* untyped calls with a codec wrapped around them.

import Foundation

extension Connection {
    /// Reads a characteristic and decodes it.
    ///
    /// ```swift
    /// let level = try await connection.read(Battery.level)   // UInt8
    /// ```
    ///
    /// - Parameter characteristic: The characteristic to read.
    /// - Returns: The decoded value.
    /// - Throws: Everything ``read(_:)->Data`` throws, plus
    ///   ``BluetoothError/decodingFailed(characteristic:underlying:)`` if the bytes arrived but
    ///   `Value` refused them.
    public func read<Value: CharacteristicDecodable>(
        _ characteristic: Characteristic<Value>
    ) async throws -> Value {
        let data = try await read(characteristic.id)
        return try Self.decode(data, for: characteristic)
    }

    /// Encodes a value and writes it.
    ///
    /// - Parameters:
    ///   - value: The value to write. Its encoding is the bytes that go on the wire.
    ///   - characteristic: The characteristic to write to.
    ///   - mode: Acknowledged by default; see ``WriteMode``.
    /// - Throws: Everything ``write(_:to:mode:)-(Data,_,_)`` throws. Encoding does not fail — a value that
    ///   cannot be represented is a type that should not have conformed.
    public func write<Value: CharacteristicEncodable>(
        _ value: Value,
        to characteristic: Characteristic<Value>,
        mode: WriteMode = .withResponse
    ) async throws {
        try await write(value.characteristicData, to: characteristic.id, mode: mode)
    }

    /// Subscribes to a characteristic and decodes every notification.
    ///
    /// The stream survives a reconnect exactly as the untyped one does. A value that fails to
    /// decode ends the stream with
    /// ``BluetoothError/decodingFailed(characteristic:underlying:)`` rather than being skipped:
    /// a peripheral sending bytes this type cannot read is a disagreement about the protocol,
    /// and dropping the packet would hide it.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to subscribe to.
    ///   - bufferingPolicy: How to behave when the consumer falls behind the peripheral.
    ///     Applied to the underlying `Data` stream, which is the only buffer between the
    ///     radio and you — decoding happens as you iterate, not ahead of you.
    /// - Returns: A stream of decoded values.
    /// - Throws: Everything ``notifications(for:bufferingPolicy:)->AsyncThrowingStream<Data,Error>`` throws.
    public func notifications<Value: CharacteristicDecodable>(
        for characteristic: Characteristic<Value>,
        bufferingPolicy: AsyncThrowingStream<Data, Error>.Continuation.BufferingPolicy =
            .bufferingNewest(256)
    ) async throws -> AsyncThrowingMapSequence<AsyncThrowingStream<Data, Error>, Value> {
        // `map` rather than a second stream fed by a pump task: the transform is 1:1, so a
        // second buffer would only mean the caller's bound was applied twice — and decoding
        // in the consumer's own context saves a hop off the library queue per packet.
        try await notifications(for: characteristic.id, bufferingPolicy: bufferingPolicy)
            .map { try Self.decode($0, for: characteristic) }
    }

    // MARK: - Shared

    private static func decode<Value: CharacteristicDecodable>(
        _ data: Data,
        for characteristic: Characteristic<Value>
    ) throws -> Value {
        do {
            return try Value(characteristicData: data)
        } catch {
            throw BluetoothError.decodingFailed(characteristic: characteristic.id, underlying: error)
        }
    }
}
