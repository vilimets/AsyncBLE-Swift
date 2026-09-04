// Typed I/O, layered strictly over the untyped API (PLAN.md §7 Q24).
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
    /// - Returns: A stream of decoded values.
    /// - Throws: Everything ``notifications(for:bufferingPolicy:)->AsyncThrowingStream<Data,Error>`` throws.
    public func notifications<Value: CharacteristicDecodable>(
        for characteristic: Characteristic<Value>,
        bufferingPolicy: AsyncThrowingStream<Value, Error>.Continuation.BufferingPolicy =
            .bufferingNewest(256)
    ) async throws -> AsyncThrowingStream<Value, Error> {
        let raw = try await notifications(
            for: characteristic.id,
            bufferingPolicy: Self.dataPolicy(matching: bufferingPolicy)
        )

        return AsyncThrowingStream<Value, Error>(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task {
                do {
                    for try await data in raw {
                        continuation.yield(try Self.decode(data, for: characteristic))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    /// Restates a buffering policy for the underlying `Data` stream.
    ///
    /// `BufferingPolicy` is nested inside the stream's generic parameter, so the two streams'
    /// policies are unrelated types that happen to have identical cases.
    private static func dataPolicy<Value>(
        matching policy: AsyncThrowingStream<Value, Error>.Continuation.BufferingPolicy
    ) -> AsyncThrowingStream<Data, Error>.Continuation.BufferingPolicy {
        switch policy {
        case .unbounded: .unbounded
        case .bufferingOldest(let count): .bufferingOldest(count)
        case .bufferingNewest(let count): .bufferingNewest(count)
        @unknown default: .bufferingNewest(256)
        }
    }
}
