// A LogHandler that keeps every record, so a test can assert on what the library logged.
//
// The library's whole test story is seams driven by fakes (PLAN.md §7 Q7); this is the same
// shape for logging. "Did the reconnect log a give-up?" becomes one `#expect`.

import Foundation

@testable import AsyncBLE

/// Captures every ``LogRecord`` the library emits.
final class RecordingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogRecord] = []

    /// Every record so far, in order.
    var records: [LogRecord] {
        lock.withLock { storage }
    }

    func log(_ record: LogRecord) {
        lock.withLock { storage.append(record) }
    }

    /// The records from one category.
    func records(in category: LogCategory) -> [LogRecord] {
        records.filter { $0.category == category }
    }

    /// Whether any record matches a level, a category, and a message substring.
    func contains(
        level: LogLevel,
        category: LogCategory,
        messageContains fragment: String
    ) -> Bool {
        records.contains {
            $0.level == level && $0.category == category && $0.message.contains(fragment)
        }
    }

    /// Whether any record's message contains a substring, at any level or category.
    func contains(messageContains fragment: String) -> Bool {
        records.contains { $0.message.contains(fragment) }
    }
}

extension LogFacility {
    /// A facility that records into `handler`, enabled down to `minimumLevel`.
    static func recording(
        _ handler: RecordingLogHandler,
        minimumLevel: LogLevel = .debug
    ) -> LogFacility {
        LogFacility(isEnabled: true, minimumLevel: minimumLevel, handler: handler)
    }
}
