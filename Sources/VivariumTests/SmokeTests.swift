import XCTest
@testable import Vivarium

final class SmokeTests: XCTestCase {
    func test_appBundleLoads() {
        // Confirms the test target links against the app target.
        XCTAssertNotNil(Bundle(for: AppDelegate.self))
    }
}
