// The internal side of logging: the resolved configuration, and the category-bound value the
// engine actually calls.
//
// Logging config is init-only (PLAN.md §7 Q22), so `LogFacility` is immutable after
// construction — no queue confinement, `Sendable` by virtue of holding a `Sendable` handler.
//
// `Log` is a cheap value carrying one category. Every emit takes its message as an
// `@autoclosure`, so a call below the threshold — or while logging is off — builds no string.
// This matters most for `.bridge`, which would otherwise format on every CoreBluetooth callback.

import Foundation

/// The resolved logging configuration, shared by a ``Central`` and everything it creates.
final class LogFacility: Sendable {
    let isEnabled: Bool
    let minimumLevel: LogLevel
    let handler: LogHandler

    init(isEnabled: Bool, minimumLevel: LogLevel, handler: LogHandler) {
        self.isEnabled = isEnabled
        self.minimumLevel = minimumLevel
        self.handler = handler
    }

    /// Builds a facility from the public configuration.
    convenience init(_ logging: Logging) {
        self.init(
            isEnabled: logging.isEnabled,
            minimumLevel: logging.minimumLevel,
            handler: logging.handler
        )
    }

    /// A facility that never emits. The default in tests and wherever no configuration is given.
    static let disabled = LogFacility(
        isEnabled: false,
        minimumLevel: .error,
        handler: NoOpLogHandler()
    )

    /// Whether a record at `level` would be emitted.
    func isActive(_ level: LogLevel) -> Bool {
        isEnabled && level >= minimumLevel
    }

    /// Emits a record, unless the level is suppressed. `message` and `metadata` are not
    /// evaluated when suppressed.
    func emit(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        guard isActive(level) else { return }
        handler.log(
            LogRecord(level: level, category: category, message: message(), metadata: metadata())
        )
    }

    /// A ``Log`` bound to one category.
    func scoped(_ category: LogCategory) -> Log {
        Log(facility: self, category: category)
    }
}

/// A category-bound front end to a ``LogFacility``.
struct Log {
    let facility: LogFacility
    let category: LogCategory

    func debug(
        _ message: @autoclosure () -> String,
        _ metadata: @autoclosure () -> [String: String] = [:]
    ) {
        facility.emit(.debug, category, message(), metadata: metadata())
    }

    func info(
        _ message: @autoclosure () -> String,
        _ metadata: @autoclosure () -> [String: String] = [:]
    ) {
        facility.emit(.info, category, message(), metadata: metadata())
    }

    func notice(
        _ message: @autoclosure () -> String,
        _ metadata: @autoclosure () -> [String: String] = [:]
    ) {
        facility.emit(.notice, category, message(), metadata: metadata())
    }

    func error(
        _ message: @autoclosure () -> String,
        _ metadata: @autoclosure () -> [String: String] = [:]
    ) {
        facility.emit(.error, category, message(), metadata: metadata())
    }
}

/// A ``LogHandler`` that discards everything. Backs ``LogFacility/disabled``.
struct NoOpLogHandler: LogHandler {
    func log(_ record: LogRecord) {}
}
