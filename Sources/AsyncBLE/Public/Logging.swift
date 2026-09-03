// The public logging surface: what the library emits, at what level, and where it goes.
//
// The library logs to OSLog by default (``OSLogHandler``). A consumer who wants the output
// somewhere else — their own logging stack, a file, a test assertion — supplies a
// ``LogHandler``. Enable/disable and the level threshold are fixed at ``Central`` init
// (PLAN.md §7 Q22): there is no runtime setter, because OSLog is normally retuned from outside
// the process and a mutable knob would buy little.
//
// What is never logged: the bytes of a characteristic value. The library logs a length, not a
// payload. Identifiers (peripheral UUIDs, characteristic UUIDs) are logged in full — they are
// random per-app values, not cross-app trackable, and they are the only useful correlation key.

import Foundation
import os

/// How much detail the library emits.
///
/// The four levels map one-to-one onto `OSLogType`, so what you set here is what Console and the
/// `log` command-line tool filter on:
///
/// | ``LogLevel`` | `OSLogType` | Typical content |
/// |---|---|---|
/// | ``debug`` | `.debug` | Per-callback tracing, cache hits, effect dispatch |
/// | ``info`` | `.info` | Operation lifecycle: reads, writes, subscribes, the discovery walk |
/// | ``notice`` | `.default` | Connect, disconnect, reconnect arming, adapter changes, scans |
/// | ``error`` | `.error` | Thrown ``BluetoothError``s, failed GATT operations, restore failures |
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    /// The most detailed level: per-callback tracing and internal bookkeeping.
    case debug

    /// Operation lifecycle — each read, write, subscribe and discovery walk as it happens.
    case info

    /// The default level: link lifecycle, reconnection decisions, adapter state, scanning.
    case notice

    /// Failures only — errors thrown to the caller and operations the peripheral refused.
    case error

    /// Orders levels by verbosity, so `.debug < .error`.
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which part of the library a log record came from.
///
/// Each becomes an OSLog category under the handler's subsystem, so you can narrow Console to
/// just reconnection (`category == "reconnect"`) or just the raw CoreBluetooth callbacks
/// (`category == "bridge"`).
public enum LogCategory: String, Sendable, CaseIterable {
    /// Adapter state, scanning, connect requests, and the connection registry.
    case central

    /// The connection state machine: transitions and the effects they trigger.
    case connection

    /// Characteristic I/O — reads, writes, and notification subscriptions.
    case io

    /// The service and characteristic discovery walk, and the per-link cache.
    case discovery

    /// Reconnection: pending-connect arming, the give-up deadline, the re-arm cadence, and
    /// restoring subscriptions after a link returns.
    case reconnect

    /// The raw CoreBluetooth delegate callbacks, before the library interprets them. Verbose,
    /// and only emitted at ``LogLevel/debug``.
    case bridge
}

/// A single log entry, as handed to a ``LogHandler``.
///
/// The `message` is already rendered — the library has decided what belongs in it. `metadata`
/// carries the same identifiers as small key/value pairs for handlers that index on them.
public struct LogRecord: Sendable {
    /// The severity of the entry.
    public let level: LogLevel

    /// The part of the library it came from.
    public let category: LogCategory

    /// The human-readable message. Contains identifiers, never characteristic payload bytes.
    public let message: String

    /// Structured detail — for example `["peripheral": "<uuid>", "characteristic": "<uuid>"]`.
    /// Values are the same curated data as `message`, never payloads.
    public let metadata: [String: String]

    /// When the entry was created.
    public let timestamp: Date

    /// Creates a log record. The library builds these; a ``LogHandler`` only receives them.
    public init(
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

/// A sink for the library's log records.
///
/// Implement this to route logging into your own stack, or to assert on it in tests. The library
/// calls ``log(_:)`` on its internal serial queue; a handler that does real work should hop off
/// it. Only records at or above the configured ``Logging/minimumLevel`` are delivered.
public protocol LogHandler: Sendable {
    /// Handles one record. Called on the library's queue.
    func log(_ record: LogRecord)
}

/// The default ``LogHandler``: forwards to `os.Logger`, one logger per ``LogCategory``.
///
/// View the output in Console.app or with the `log` tool:
///
/// ```
/// log stream --predicate 'subsystem == "com.asyncble"' --level debug
/// ```
public struct OSLogHandler: LogHandler {
    private let loggers: [LogCategory: Logger]

    /// Creates a handler logging under `subsystem`.
    ///
    /// - Parameter subsystem: The OSLog subsystem, shown in Console and used in its predicates.
    ///   Defaults to `"com.asyncble"`.
    public init(subsystem: String = "com.asyncble") {
        loggers = Dictionary(
            uniqueKeysWithValues: LogCategory.allCases.map { category in
                (category, Logger(subsystem: subsystem, category: category.rawValue))
            }
        )
    }

    /// Forwards a record to the matching category logger.
    ///
    /// The message is interpolated as `public`: the library has already curated it, so OSLog's
    /// per-field redaction is not relied on.
    public func log(_ record: LogRecord) {
        loggers[record.category]?.log(level: record.level.osLogType, "\(record.message, privacy: .public)")
    }
}

/// Logging configuration for a ``Central``, fixed at initialization.
///
/// Passed as the second argument to ``Central/init(configuration:logging:)``. Held apart from
/// ``Central/Configuration`` because ``handler`` is a protocol existential and would cost
/// `Configuration` its `Equatable` conformance (PLAN.md §7 Q15, Q22).
///
/// ```swift
/// // Default: OSLog, on, at .notice.
/// let central = Central()
///
/// // More detail, still to OSLog.
/// let central = Central(logging: .init(minimumLevel: .debug))
///
/// // Somewhere else entirely.
/// let central = Central(logging: .init(handler: MyLogHandler()))
///
/// // Off.
/// let central = Central(logging: .init(isEnabled: false))
/// ```
public struct Logging: Sendable {
    /// Whether the library emits anything at all. Defaults to `true`.
    public var isEnabled: Bool

    /// The lowest level that is emitted. Defaults to ``LogLevel/notice``.
    public var minimumLevel: LogLevel

    /// Where records go. Defaults to an ``OSLogHandler`` under the `"com.asyncble"` subsystem.
    public var handler: LogHandler

    /// Creates a logging configuration.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the library emits anything. Defaults to `true`.
    ///   - minimumLevel: The lowest level emitted. Defaults to ``LogLevel/notice``.
    ///   - handler: The sink for records. Defaults to ``OSLogHandler``.
    public init(
        isEnabled: Bool = true,
        minimumLevel: LogLevel = .notice,
        handler: LogHandler = OSLogHandler()
    ) {
        self.isEnabled = isEnabled
        self.minimumLevel = minimumLevel
        self.handler = handler
    }
}

extension LogLevel {
    /// The `OSLogType` this level maps to.
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        }
    }
}
