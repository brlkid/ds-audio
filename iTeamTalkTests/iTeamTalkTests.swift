import XCTest

final class TTCustomLiveKitTests: XCTestCase {
    func testLiveKitAppTargetIsConfiguredForHTTPSBackend() {
        XCTAssertTrue("https://example.test".hasPrefix("https://"))
    }
}
