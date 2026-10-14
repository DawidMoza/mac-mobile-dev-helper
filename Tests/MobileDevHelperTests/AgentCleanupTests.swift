import Foundation
import SQLite3
import XCTest
@testable import MobileDevHelper

final class AgentCleanupTests: XCTestCase {
    func testScanAndDeleteAgentFilesPreservesConfigurationMemoryAndDatabases() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        let session = "12345678-1234-1234-1234-123456789abc"
        let removable: [(CleanupCategoryID, String)] = [
            (.codexCaches, ".codex/log/codex-tui.log"),
            (.codexCaches, ".codex/cache/nested/data.bin"),
            (.codexCaches, ".codex/shell_snapshots/snapshot.sh"),
            (.codexCaches, ".codex/models_cache.json"),
            (.codexHistory, ".codex/sessions/2026/10/14/rollout-session.jsonl"),
            (.codexHistory, ".codex/archived_sessions/rollout-old.jsonl"),
            (.codexHistory, ".codex/history.jsonl"),
            (.claudeCodeCaches, ".claude/debug/session.txt"),
            (.claudeCodeCaches, ".claude/cache/data.bin"),
            (.claudeCodeHistory, ".claude/projects/project/\(session).jsonl"),
            (.claudeCodeHistory, ".claude/projects/project/\(session)/subagents/agent-abc.jsonl"),
            (.claudeCodeHistory, ".claude/projects/other/sessions/\(session).jsonl"),
            (.claudeCodeHistory, ".claude/history.jsonl")
        ]
        let protected = [
            ".codex/auth.json", ".codex/config.toml", ".codex/skills/example/SKILL.md",
            ".codex/state_5.sqlite", ".codex/state_5.sqlite-wal", ".codex/session_index.jsonl",
            ".codex/sessions/notes.txt", ".codex/generated_images/keep.png",
            ".claude/settings.json", ".claude/.credentials.json", ".claude/CLAUDE.md",
            ".claude/projects/project/memory/MEMORY.md",
            ".claude/projects/project/memory/\(session).jsonl",
            ".claude/projects/project/sessions-index.json", ".claude/projects/project/unknown.jsonl",
            ".claude/file-history/backup", ".claude/plugins/plugin.json", ".claude.json"
        ]
        for (_, path) in removable { try fixture.file(path) }
        for path in protected { try fixture.file(path) }
        let service = fixture.service()
        let snapshot = await service.scan()
        for category in snapshot.categories where category.id.agent != nil {
            XCTAssertEqual(Set(category.items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }), Set(removable.filter { $0.0 == category.id }.map { fixture.url($0.1).path }))
            XCTAssertGreaterThan(category.totalAllocatedSize, 0)
            XCTAssertTrue(category.scanErrors.isEmpty)
            XCTAssertFalse(category.id.isSelectedByDefault)
        }
        let result = await service.clean(items: snapshot.categories.filter { $0.id.agent != nil }.flatMap(\.items))
        XCTAssertEqual(result.removedCount, removable.count)
        XCTAssertTrue(result.failures.isEmpty)
        for (_, path) in removable { XCTAssertFalse(fixture.exists(path), path) }
        for path in protected { XCTAssertTrue(fixture.exists(path), path) }
    }

    func testScanSkipsSymlinkedRootsAndNestedDirectories() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.file("outside/rollout-secret.jsonl")
        try fixture.file(".codex/cache/real.bin")
        try FileManager.default.createSymbolicLink(at: fixture.url(".codex/sessions"), withDestinationURL: fixture.url("outside"))
        try FileManager.default.createSymbolicLink(at: fixture.url(".codex/cache/linked"), withDestinationURL: fixture.url("outside"))
        try FileManager.default.createSymbolicLink(at: fixture.url(".claude"), withDestinationURL: fixture.url("outside"))
        let snapshot = await fixture.service().scan()
        let items = snapshot.categories.flatMap(\.items)
        XCTAssertEqual(items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }, [fixture.url(".codex/cache/real.bin").path])
    }

    func testDeletionRechecksSymlinkedAncestorsAndRejectsForgedPaths() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.file(".codex/cache/nested/data.bin")
        try fixture.file("outside/data.bin")
        try fixture.file(".codex/auth.json")
        let service = fixture.service()
        let snapshot = await service.scan()
        try FileManager.default.removeItem(at: fixture.url(".codex/cache/nested"))
        try FileManager.default.createSymbolicLink(at: fixture.url(".codex/cache/nested"), withDestinationURL: fixture.url("outside"))
        let forged = [".codex/auth.json", ".codex/cache", ".codex/cache/../../outside/data.bin"].map {
            CleanupItem(categoryID: .codexCaches, path: fixture.url($0).path, allocatedSize: 4096)
        }
        let result = await service.clean(items: snapshot.categories.flatMap(\.items) + forged)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.failures.count, 4)
        XCTAssertTrue(fixture.exists("outside/data.bin"))
        XCTAssertTrue(fixture.exists(".codex/auth.json"))
    }

    @MainActor
    func testRunningAgentBlocksViewModelAndServiceDeletion() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.file(".codex/log/session.log")
        try fixture.file(".claude/debug/session.txt")
        let service = fixture.service(isRunning: { _ in true })
        let model = CleanupViewModel(service: service)
        await model.refresh()
        model.setSelected(true, categoryID: .codexCaches)
        model.setSelected(true, categoryID: .claudeCodeCaches)
        XCTAssertFalse(model.canClean)
        XCTAssertEqual(model.snapshot.runningAgents, Set(CleanupAgent.allCases))
        let result = await service.clean(items: model.selectedItems)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(fixture.exists(".codex/log/session.log"))
        XCTAssertTrue(fixture.exists(".claude/debug/session.txt"))
    }

    func testCustomHomesAreScannedInsteadOfDefaults() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.file("custom-codex/log/session.log")
        try fixture.file("custom-claude/debug/session.txt")
        try fixture.file("databases/logs_2.sqlite")
        try fixture.file(".codex/log/ignore.log")
        try fixture.file(".claude/debug/ignore.txt")
        var paths = fixture.paths
        paths.codexHomeOverride = fixture.url("custom-codex")
        paths.claudeHomeOverride = fixture.url("custom-claude")
        paths.codexSQLiteHomeOverride = fixture.url("databases")
        let service = CleanupService(paths: paths, isAgentRunning: { _ in false })
        let snapshot = await service.scan()
        XCTAssertEqual(Set(snapshot.categories.flatMap(\.items).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }), Set([
            fixture.url("custom-codex/log/session.log").path, fixture.url("custom-claude/debug/session.txt").path
        ]))
        XCTAssertEqual(snapshot.codexDatabases.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }, [fixture.url("databases/logs_2.sqlite").path])
    }

    @MainActor
    func testCompactionReclaimsFreePagesPreservesRecordsAndRefreshesSnapshot() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        let model = CleanupViewModel(service: fixture.service())
        await model.refresh()
        let before = try XCTUnwrap(model.snapshot.codexDatabases.first)
        XCTAssertTrue(model.canCompactCodexDatabase(before))
        await model.compactCodexDatabase(before)
        let after = try XCTUnwrap(model.snapshot.codexDatabases.first)
        XCTAssertLessThan(after.allocatedSize, before.allocatedSize)
        XCTAssertEqual(model.message?.title, "Codex database compacted")
        XCTAssertEqual(try fixture.sql("SELECT id || ':' || value FROM records;"), "1:keep\n")
        XCTAssertEqual(try fixture.sql("PRAGMA user_version;"), "42\n")
        XCTAssertEqual(try fixture.sql("SELECT name FROM sqlite_master WHERE type='index';"), "records_value\n")
        XCTAssertEqual(try fixture.sql("PRAGMA integrity_check;"), "ok\n")
        XCTAssertFalse(model.isWorking)
    }

    func testCompactionRejectsRunningAgentLowSpaceUnknownAndSymlinkedDatabases() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        for service in [fixture.service(isRunning: { _ in true }), fixture.service(freeSpace: 1)] {
            do {
                _ = try await service.compactCodexDatabase(at: fixture.database.path)
                XCTFail("Expected compaction to be blocked")
            } catch is AgentCleanupError { }
        }
        try fixture.file(".codex/unknown.sqlite")
        try FileManager.default.createSymbolicLink(at: fixture.url(".codex/logs_2.sqlite"), withDestinationURL: fixture.database)
        let service = fixture.service()
        for path in [".codex/unknown.sqlite", ".codex/logs_2.sqlite", ".codex/state_5.sqlite-wal", ".codex/state_99.sqlite"] {
            do {
                _ = try await service.compactCodexDatabase(at: fixture.url(path).path)
                XCTFail("Expected rejection for \(path)")
            } catch is AgentCleanupError { }
        }
        XCTAssertFalse(fixture.exists(".codex/state_99.sqlite"))
        XCTAssertEqual(try fixture.sql("SELECT value FROM records;"), "keep\n")
        let snapshot = await service.scan()
        XCTAssertEqual(snapshot.codexDatabases.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }, [fixture.database.path])
    }

    func testCompactionFailsSafelyWhenDatabaseIsLocked() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await fixture.service().compactCodexDatabase(at: fixture.database.path)
            XCTFail("Expected locked database failure")
        } catch { }
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try fixture.sql("SELECT value FROM records;"), "keep\n")
    }

    func testCompactionPreservesCommittedWALRecords() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; INSERT INTO records VALUES(3, 'from-wal');", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(fixture.exists(".codex/state_5.sqlite-wal"))

        _ = try await fixture.service().compactCodexDatabase(at: fixture.database.path)

        XCTAssertEqual(try fixture.sql("SELECT value FROM records ORDER BY id;"), "keep\nfrom-wal\n")
        XCTAssertEqual(try fixture.sql("PRAGMA integrity_check;"), "ok\n")
    }

    func testCompactionRejectsRedirectedWALBeforeOpeningDatabase() async throws {
        let fixture = try AgentCleanupFixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.file("outside-wal")
        let original = try Data(contentsOf: fixture.url("outside-wal"))
        try FileManager.default.createSymbolicLink(at: fixture.url(".codex/state_5.sqlite-wal"), withDestinationURL: fixture.url("outside-wal"))
        do {
            _ = try await fixture.service().compactCodexDatabase(at: fixture.database.path)
            XCTFail("Expected redirected WAL rejection")
        } catch is AgentCleanupError { }
        XCTAssertEqual(try Data(contentsOf: fixture.url("outside-wal")), original)
    }

    func testProcessDetectionIncludesNativeAndNodeCLIsWithoutMatchingPromptText() {
        for command in ["/usr/local/bin/codex app-server", "codex --resume", "/Applications/Codex.app/Contents/MacOS/Codex", "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js"] {
            XCTAssertTrue(CleanupService.isAgentProcess(command, agent: .codex), command)
        }
        for command in ["/Users/test/.local/bin/claude", "claude --resume", "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "node /usr/local/bin/claude"] {
            XCTAssertTrue(CleanupService.isAgentProcess(command, agent: .claudeCode), command)
        }
        for command in ["/bin/zsh -c echo codex", "node server.js claude", "rg /Applications/Codex.app/Contents/MacOS/Codex"] {
            XCTAssertFalse(CleanupService.isAgentProcess(command, agent: .codex), command)
            XCTAssertFalse(CleanupService.isAgentProcess(command, agent: .claudeCode), command)
        }
    }
}

private final class AgentCleanupFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("AgentCleanupTests-\(UUID().uuidString)")
    var paths: CleanupPaths { CleanupPaths(homeDirectory: root, temporaryDirectory: root.appendingPathComponent("tmp")) }
    var database: URL { url(".codex/state_5.sqlite") }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
    func file(_ path: String) throws {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 4096).write(to: target)
    }
    func service(freeSpace: Int64 = 1_000_000_000, isRunning: @escaping @Sendable (CleanupAgent) -> Bool = { _ in false }) -> CleanupService {
        CleanupService(paths: paths, isCursorRunning: { false }, diskUsageReader: { _ in
            DiskUsage(totalCapacity: 2_000_000_000, availableCapacity: freeSpace)
        }, isAgentRunning: isRunning)
    }
    func createDatabase() throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try sql("""
            PRAGMA auto_vacuum=NONE;
            PRAGMA user_version=42;
            CREATE TABLE records(id INTEGER PRIMARY KEY, value BLOB);
            CREATE INDEX records_value ON records(value);
            INSERT INTO records VALUES(1, 'keep'), (2, zeroblob(1048576));
            DELETE FROM records WHERE id=2;
            """)
    }
    func sql(_ query: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-bail", "-init", "/dev/null", database.path, query]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "AgentCleanupTests", code: Int(process.terminationStatus)) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
