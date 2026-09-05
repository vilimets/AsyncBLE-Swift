// Comparing thrown errors in tests.
//
// `BluetoothError` is deliberately not `Equatable` in the public API: it carries
// `connectionFailed(underlying: Error?)`, and `Error` has no equality. Rather than weaken the
// public type for the tests' convenience, the tests flatten an error into something comparable
// and assert on that.

@preconcurrency import CoreBluetooth
import Foundation

@testable import AsyncBLE

/// A `BluetoothError` with its underlying error dropped, so it can be compared.
enum ErrorKind: Equatable {
    case bluetoothUnavailable(reason: UnavailableReason)
    case connectTimeout
    case connectionFailed
    case disconnected(DisconnectReason)
    case characteristicNotFound(CBUUID)
    case operationNotSupported
    case operationFailed
    case decodingFailed(CBUUID)
    case cancelled
    /// Anything that is not a `BluetoothError`, identified by its type.
    case other(String)

    init(_ error: Error) {
        switch error {
        case let error as BluetoothError:
            self = ErrorKind(error)
        case is CancellationError:
            self = .cancelled
        default:
            self = .other(String(describing: type(of: error)))
        }
    }

    init(_ error: BluetoothError) {
        switch error {
        case .bluetoothUnavailable(reason: let reason): self = .bluetoothUnavailable(reason: reason)
        case .connectTimeout: self = .connectTimeout
        case .connectionFailed: self = .connectionFailed
        case .disconnected(let reason): self = .disconnected(reason)
        case .characteristicNotFound(let uuid): self = .characteristicNotFound(uuid)
        case .operationNotSupported: self = .operationNotSupported
        case .operationFailed: self = .operationFailed
        case .decodingFailed(let uuid, _): self = .decodingFailed(uuid)
        }
    }
}

extension Error {
    /// This error, flattened for comparison.
    var kind: ErrorKind { ErrorKind(self) }
}

/// Runs an async expression and returns the error it threw, if any.
///
/// `#expect(throws:)` needs an `Equatable` error, which is exactly what the public API does not
/// provide — so tests catch the error and compare its ``ErrorKind``.
func errorThrown(by body: () async throws -> some Any) async -> ErrorKind? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error.kind
    }
}
