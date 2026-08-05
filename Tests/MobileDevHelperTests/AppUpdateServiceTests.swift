import Foundation
import XCTest
@testable import MobileDevHelper

final class AppUpdateServiceTests: XCTestCase {
    func testVersionComparisonHandlesPrefixesAndUnevenComponents() throws {
        XCTAssertEqual(try AppVersion("v1.2.3").description, "v1.2.3")
        XCTAssertTrue(try AppVersion("0.1.2") < AppVersion("v0.1.3"))
        XCTAssertTrue(try AppVersion("v0.1.3") > AppVersion("0.1.2"))
        XCTAssertTrue(try AppVersion("1.0") < AppVersion("1.0.1"))
        XCTAssertFalse(try AppVersion("1.2.0") < AppVersion("v1.2"))
        XCTAssertFalse(try AppVersion("v1.2") < AppVersion("1.2.0"))
        XCTAssertThrowsError(try AppVersion("latest"))
    }

    func testParseLatestReleaseReadsTagAndURL() throws {
        let json = """
        {
          "tag_name": "v0.1.4",
          "html_url": "https://github.com/DawidMoza/mac-mobile-dev-helper/releases/tag/v0.1.4",
          "published_at": "2026-08-05T10:00:00Z"
        }
        """.data(using: .utf8)!

        let release = try AppUpdateService.parseLatestRelease(json)
        XCTAssertEqual(release.tag, "v0.1.4")
        XCTAssertEqual(
            release.htmlURL?.absoluteString,
            "https://github.com/DawidMoza/mac-mobile-dev-helper/releases/tag/v0.1.4"
        )
        XCTAssertNotNil(release.publishedAt)
    }

    func testCheckForUpdateDetectsNewerRelease() async throws {
        let networking = FakeAppUpdateNetworking(
            response: """
            {
              "tag_name": "v9.9.9",
              "html_url": "https://example.com/v9.9.9"
            }
            """
        )
        let service = AppUpdateService(networking: networking)
        let availability = try await service.checkForUpdate(
            bundle: FakeVersionBundle(version: "0.1.3")
        )

        XCTAssertTrue(availability.isUpdateAvailable)
        XCTAssertEqual(availability.currentVersion.description, "v0.1.3")
        XCTAssertEqual(availability.latestRelease.tag, "v9.9.9")
    }

    func testCheckForUpdateWhenAlreadyCurrent() async throws {
        let networking = FakeAppUpdateNetworking(
            response: """
            {
              "tag_name": "v0.1.3",
              "html_url": "https://example.com/v0.1.3"
            }
            """
        )
        let service = AppUpdateService(networking: networking)
        let availability = try await service.checkForUpdate(
            bundle: FakeVersionBundle(version: "v0.1.3")
        )

        XCTAssertFalse(availability.isUpdateAvailable)
    }
}

private struct FakeAppUpdateNetworking: AppUpdateNetworking {
    let response: String

    func data(from url: URL) async throws -> Data {
        Data(response.utf8)
    }
}

private final class FakeVersionBundle: Bundle, @unchecked Sendable {
    private let version: String

    init(version: String) {
        self.version = version
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        key == "CFBundleShortVersionString" ? version : nil
    }
}
