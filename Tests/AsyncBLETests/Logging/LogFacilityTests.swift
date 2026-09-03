// The facility is the gate every log call passes through. What matters: it suppresses correctly,
// and a suppressed call costs nothing — the @autoclosure message is never built.

import Testing

@testable import AsyncBLE

@Suite("The log facility")
struct LogFacilityTests {
    @Test("a disabled facility emits nothing")
    func disabledEmitsNothing() {
        let recorder = RecordingLogHandler()
        let facility = LogFacility(isEnabled: false, minimumLevel: .debug, handler: recorder)

        facility.scoped(.connection).error("something went wrong")

        #expect(recorder.records.isEmpty)
    }

    @Test("levels below the threshold are dropped")
    func thresholdGating() {
        let recorder = RecordingLogHandler()
        let facility = LogFacility(isEnabled: true, minimumLevel: .notice, handler: recorder)
        let log = facility.scoped(.io)

        log.debug("trace")
        log.info("lifecycle")
        log.notice("connected")
        log.error("failed")

        #expect(recorder.records.map(\.level) == [.notice, .error])
    }

    @Test("a suppressed call never evaluates its message")
    func autoclosureNotEvaluatedWhenSuppressed() {
        let recorder = RecordingLogHandler()
        let facility = LogFacility(isEnabled: true, minimumLevel: .error, handler: recorder)
        let built = Flag()

        facility.scoped(.bridge).debug(built.markAndReturn("expensive"))

        #expect(built.wasSet == false)
        #expect(recorder.records.isEmpty)
    }

    @Test("an emitted call does evaluate its message, once")
    func autoclosureEvaluatedWhenEmitted() {
        let recorder = RecordingLogHandler()
        let facility = LogFacility(isEnabled: true, minimumLevel: .debug, handler: recorder)
        let built = Flag()

        facility.scoped(.bridge).debug(built.markAndReturn("cheap enough"))

        #expect(built.hits == 1)
        #expect(recorder.records.first?.message == "cheap enough")
    }

    @Test("category and metadata are carried through")
    func carriesCategoryAndMetadata() throws {
        let recorder = RecordingLogHandler()
        let facility = LogFacility.recording(recorder)

        facility.scoped(.reconnect).notice("giving up", ["peripheral": "ABC"])

        let record = try #require(recorder.records.first)
        #expect(record.category == .reconnect)
        #expect(record.metadata == ["peripheral": "ABC"])
    }

    @Test("the disabled singleton is inert")
    func disabledSingleton() {
        #expect(LogFacility.disabled.isActive(.error) == false)
    }

    /// Records whether an `@autoclosure` under test was forced.
    private final class Flag: @unchecked Sendable {
        private(set) var hits = 0
        var wasSet: Bool { hits != 0 }

        func markAndReturn(_ value: String) -> String {
            hits += 1
            return value
        }
    }
}
