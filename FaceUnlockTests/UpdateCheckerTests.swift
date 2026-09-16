import XCTest
@testable import FaceUnlock

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    }

    func testShorterVersionsAreTreatedAsZeroPadded() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
    }

    func testMalformedComponentsDoNotCrash() {
        XCTAssertFalse(UpdateChecker.isNewer("x.y.z", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "x.y.z"))
    }

    func testCheckingIsSkippedWhenDisabled() async {
        let checker = UpdateChecker(
            // A URL that would fail loudly if it were ever requested.
            feedURL: URL(fileURLWithPath: "/dev/null/never-requested"),
            currentVersion: "1.0.0",
            isEnabled: { false }
        )
        let result = await checker.checkForUpdates()
        XCTAssertEqual(result, .disabled)
    }

    func testManifestDecoding() throws {
        let json = Data(#"{"version":"2.1.0","notes":"https://example.com/n","download":"https://example.com/d"}"#.utf8)
        let manifest = try JSONDecoder().decode(UpdateChecker.Manifest.self, from: json)
        XCTAssertEqual(manifest.version, "2.1.0")
        XCTAssertEqual(manifest.notes, "https://example.com/n")
    }

    func testManifestWithoutOptionalFields() throws {
        let manifest = try JSONDecoder().decode(
            UpdateChecker.Manifest.self, from: Data(#"{"version":"2.1.0"}"#.utf8)
        )
        XCTAssertNil(manifest.notes)
        XCTAssertNil(manifest.download)
    }

    /// The update session must not be able to accumulate any state.
    func testSessionCarriesNoCookiesOrCache() {
        let configuration = UpdateChecker.makeSession().configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }
}
