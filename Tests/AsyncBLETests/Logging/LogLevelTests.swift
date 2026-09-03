// LogLevel is a public type consumers filter on, so its ordering and its cases are a contract.

import os
import Testing

@testable import AsyncBLE

@Suite("Log levels")
struct LogLevelTests {
    @Test("order runs from debug up to error")
    func ordering() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.notice)
        #expect(LogLevel.notice < LogLevel.error)
        #expect(LogLevel.allCases == [.debug, .info, .notice, .error])
    }

    @Test("raw values are stable")
    func rawValues() {
        #expect(LogLevel.debug.rawValue == 0)
        #expect(LogLevel.error.rawValue == 3)
    }

    @Test("each level maps to a distinct OSLogType")
    func osLogTypeMapping() {
        #expect(LogLevel.debug.osLogType == .debug)
        #expect(LogLevel.info.osLogType == .info)
        #expect(LogLevel.notice.osLogType == .default)
        #expect(LogLevel.error.osLogType == .error)
    }
}
