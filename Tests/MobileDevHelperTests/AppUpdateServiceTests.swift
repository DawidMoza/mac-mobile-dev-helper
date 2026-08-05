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

    func testUpdateButtonTitleFormat() throws {
        let availability = AppUpdateAvailability(
            currentVersion: try AppVersion("0.1.4"),
            latestRelease: AppReleaseInfo(
                tag: "v0.2.0",
                htmlURL: URL(string: "https://example.com/v0.2.0"),
                publishedAt: nil
            )
        )
        XCTAssertEqual(
            "Update \(availability.currentVersion.description) -> \(try availability.latestVersion.description)",
            "Update v0.1.4 -> v0.2.0"
        )
    }

    @MainActor
    func testAutomaticChecksAreThrottledToOncePerDay() async {
        let networking = FakeAppUpdateNetworking(
            response: """
            {
              "tag_name": "v9.0.0",
              "html_url": "https://example.com/v9.0.0"
            }
            """
        )
        let suiteName = "AppUpdateThrottleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Date().timeIntervalSince1970, forKey: AppUpdateViewModel.lastCheckDefaultsKey)

        let model = AppUpdateViewModel(
            service: AppUpdateService(networking: networking),
            defaults: defaults,
            versionBundle: FakeVersionBundle(version: "0.1.4")
        )
        await model.checkForUpdatesIfNeeded()
        XCTAssertNil(model.availableUpdate)

        defaults.set(
            Date().timeIntervalSince1970 - AppUpdateViewModel.automaticCheckInterval - 1,
            forKey: AppUpdateViewModel.lastCheckDefaultsKey
        )
        await model.checkForUpdatesIfNeeded()
        XCTAssertEqual(model.availableUpdate?.latestRelease.tag, "v9.0.0")
        XCTAssertEqual(model.updateButtonTitle, "Update v0.1.4 -> v9.0.0")
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
