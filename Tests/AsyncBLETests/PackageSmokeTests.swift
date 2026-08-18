import Testing

@testable import AsyncBLE

@Suite("Package wiring")
struct PackageSmokeTests {
    @Test("Test target links AsyncBLE and swift-testing runs")
    func packageBuilds() {
        #expect(Bool(true))
    }
}
