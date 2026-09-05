// OSLog output cannot be read back in-process, so this is a smoke test: every level and category
// goes through without trapping, and a custom subsystem is accepted.

import Testing

@testable import AsyncBLE

@Suite("The OSLog handler")
struct OSLogHandlerTests {
    @Test("handles every level and category")
    func everyCombination() {
        let handler = OSLogHandler()
        for category in LogCategory.allCases {
            for level in LogLevel.allCases {
                handler.log(
                    LogRecord(level: level, category: category, message: "smoke \(category) \(level)")
                )
            }
        }
    }

    @Test("accepts a custom subsystem")
    func customSubsystem() {
        let handler = OSLogHandler(subsystem: "com.example.app.ble")
        handler.log(LogRecord(level: .notice, category: .central, message: "custom subsystem"))
    }

    @Test("is the default handler")
    func isDefault() {
        #expect(LogConfiguration().handler is OSLogHandler)
    }
}
