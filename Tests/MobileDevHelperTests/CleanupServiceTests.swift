import Foundation
import XCTest
@testable import MobileDevHelper

final class CleanupServiceTests: XCTestCase {
    func testScanFindsOnlyAllowlistedItemsAndSkipsSymlinks() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }

        let coreApp = environment.paths.coreDeviceDeltas.appendingPathComponent("com.example.app")
        try environment.createFile(at: coreApp.appendingPathComponent("delta.bin"), size: 1_024)

        let temporaryBuild = environment.paths.temporaryDirectory.appendingPathComponent("example.apk")
        try environment.createFile(at: temporaryBuild, size: 2_048)
        try environment.createFile(
            at: environment.paths.temporaryDirectory.appendingPathComponent("keep.txt"),
            size: 4_096
        )

        let outside = environment.root.appendingPathComponent("outside.apk")
        try environment.createFile(at: outside, size: 512)
        try FileManager.default.createSymbolicLink(
            at: environment.paths.temporaryDirectory.appendingPathComponent("linked.apk"),
            withDestinationURL: outside
        )

        try environment.createFile(at: environment.paths.cursorBackup, size: 1_024)
        try environment.createFile(at: environment.paths.activeCursorDatabase, size: 1_024)

        let snapshot = await CleanupService(paths: environment.paths).scan()

        XCTAssertEqual(snapshot.category(.coreDeviceDeltas).items.map(\.name), ["com.example.app"])
        XCTAssertEqual(snapshot.category(.mobileBuildTemporaryFiles).items.map(\.name), ["example.apk"])
        XCTAssertEqual(snapshot.category(.cursorBackup).items.map(\.name), ["state.vscdb.backup"])
        XCTAssertGreaterThan(snapshot.category(.coreDeviceDeltas).totalAllocatedSize, 0)
        XCTAssertGreaterThan(snapshot.activeCursorDatabaseSize ?? 0, 0)
    }

    func testCleanRemovesScannedItemsButPreservesOtherFiles() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }

        let coreApp = environment.paths.coreDeviceDeltas.appendingPathComponent("com.example.app")
        try environment.createFile(at: coreApp.appendingPathComponent("delta.bin"), size: 1_024)
        let temporaryBuild = environment.paths.temporaryDirectory.appendingPathComponent("build.pck")
        try environment.createFile(at: temporaryBuild, size: 2_048)
        let ignoredFile = environment.paths.temporaryDirectory.appendingPathComponent("notes.txt")
        try environment.createFile(at: ignoredFile, size: 2_048)
        try environment.createFile(at: environment.paths.cursorBackup, size: 2_048)

        let service = CleanupService(paths: environment.paths)
        let snapshot = await service.scan()
        let selectedItems = snapshot.categories
            .filter { $0.id != .cursorBackup }
            .flatMap(\.items)
        let result = await service.clean(items: selectedItems)

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coreApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryBuild.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.paths.coreDeviceDeltas.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.paths.cursorBackup.path))
    }

    func testCleanRejectsForgedPathOutsideAllowlist() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }

        let protectedFile = environment.root.appendingPathComponent("protected.apk")
        try environment.createFile(at: protectedFile, size: 1_024)
        let forgedItem = CleanupItem(
            categoryID: .mobileBuildTemporaryFiles,
            path: protectedFile.path,
            allocatedSize: 1_024
        )

        let result = await CleanupService(paths: environment.paths).clean(items: [forgedItem])

        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedFile.path))
    }

    func testMissingCleanupDirectoriesProduceEmptySnapshot() async throws {
        let environment = try TestEnvironment(createDirectories: false)
        defer { environment.remove() }

        let snapshot = await CleanupService(paths: environment.paths).scan()

        XCTAssertTrue(snapshot.categories.allSatisfy(\.items.isEmpty))
        XCTAssertNil(snapshot.activeCursorDatabaseSize)
    }
}

private extension CleanupSnapshot {
    func category(_ id: CleanupCategoryID) -> CleanupCategory {
        categories.first { $0.id == id }!
    }
}

private final class TestEnvironment {
    let root: URL
    let paths: CleanupPaths

    init(createDirectories: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileDevHelperTests-\(UUID().uuidString)", isDirectory: true)
        paths = CleanupPaths(
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )

        if createDirectories {
            try FileManager.default.createDirectory(
                at: paths.coreDeviceDeltas,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: paths.temporaryDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: paths.cursorGlobalStorage,
                withIntermediateDirectories: true
            )
        }
    }

    func createFile(at url: URL, size: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xA5, count: size).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
