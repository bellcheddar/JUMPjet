import XCTest

@testable import JUMPjet

/// Unit tests for the app target itself. The modules carry their own suites,
/// run on the host by Tools/test-all.sh; this target is for what only exists
/// once the app is assembled.
final class AppModelTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
