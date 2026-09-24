import AppKit
import Foundation

struct CleanupPaths: Sendable {
    let homeDirectory: URL
    let temporaryDirectory: URL

    static let live = CleanupPaths(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    )

    var coreDeviceDeltas: URL {
        homeDirectory
            .appendingPathComponent("Library/Containers/com.apple.CoreDevice.CoreDeviceService")
            .appendingPathComponent("Data/Library/Caches/AppInstallationBinaryDeltas", isDirectory: true)
    }

    var cursorGlobalStorage: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
    }

    var cursorBackup: URL {
        cursorGlobalStorage.appendingPathComponent("state.vscdb.backup")
    }

    var activeCursorDatabase: URL {
        cursorGlobalStorage.appendingPathComponent("state.vscdb")
    }

    var activeCursorDatabaseWAL: URL {
        cursorGlobalStorage.appendingPathComponent("state.vscdb-wal")
    }

    var activeCursorDatabaseSHM: URL {
        cursorGlobalStorage.appendingPathComponent("state.vscdb-shm")
    }

    var compactingCursorDatabase: URL {
        cursorGlobalStorage.appendingPathComponent("state.vscdb.compacting")
    }

    var xcodeDerivedData: URL {
        homeDirectory
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    var xcodeDocumentationCache: URL {
        homeDirectory
            .appendingPathComponent("Library/Developer/Xcode/DocumentationCache", isDirectory: true)
    }

    var xcodeDocumentationIndex: URL {
        homeDirectory
            .appendingPathComponent("Library/Developer/Xcode/DocumentationIndex", isDirectory: true)
    }
}

actor CleanupService {
    private static let temporaryExtensions: Set<String> = [
        "apk", "ipa", "pck", "xcframework", "xcodeproj"
    ]

    private static let temporaryDirectoryPrefixes = [
        "godot-", "ios-", "xcode-", "qaas-", "screw-"
    ]

    private let paths: CleanupPaths
    private let isCursorRunning: @Sendable () -> Bool
    private let sqliteExecutable: URL

    init(
        paths: CleanupPaths = .live,
        isCursorRunning: @escaping @Sendable () -> Bool = CleanupService.detectCursorRunning,
        sqliteExecutable: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    ) {
        self.paths = paths
        self.isCursorRunning = isCursorRunning
        self.sqliteExecutable = sqliteExecutable
    }

    func scan() -> CleanupSnapshot {
        let coreDevice = scanChildren(
            at: paths.coreDeviceDeltas,
            categoryID: .coreDeviceDeltas,
            matches: { _ in true }
        )
        let xcodeCaches = scanXcodeCompilationCachesAndIndexes()
        let temporaryFiles = scanChildren(
            at: paths.temporaryDirectory,
            categoryID: .mobileBuildTemporaryFiles,
            matches: isRecognizedTemporaryItem
        )
        let cursorBackup = scanSingleFile(
            at: paths.cursorBackup,
            categoryID: .cursorBackup
        )

        return CleanupSnapshot(
            categories: [coreDevice, xcodeCaches, temporaryFiles, cursorBackup],
            cursorDatabase: scanCursorDatabase(),
            diskUsage: scanDiskUsage()
        )
    }

    func compactCursorDatabase() throws -> CursorCompactResult {
        guard !isCursorRunning() else {
            throw CursorCompactError.cursorIsRunning
        }
        guard FileManager.default.fileExists(atPath: paths.activeCursorDatabase.path) else {
            throw CursorCompactError.databaseMissing
        }
        guard FileManager.default.isExecutableFile(atPath: sqliteExecutable.path) else {
            throw CursorCompactError.sqliteMissing
        }

        let sizeBefore = existingAllocatedSize(at: paths.activeCursorDatabase) ?? 0
        if let available = volumeAvailableCapacity(at: paths.activeCursorDatabase),
           available < CursorDatabaseStatus.minimumFreeSpaceToCompact {
            throw CursorCompactError.notEnoughDiskSpace(
                needed: CursorDatabaseStatus.minimumFreeSpaceToCompact,
                available: available
            )
        }

        let compactingURL = paths.compactingCursorDatabase
        try? FileManager.default.removeItem(at: compactingURL)
        do {
            try rebuildCompactedDatabase(to: compactingURL)
            try replaceActiveDatabase(with: compactingURL)
        } catch {
            try? FileManager.default.removeItem(at: compactingURL)
            throw error
        }

        let sizeAfter = existingAllocatedSize(at: paths.activeCursorDatabase) ?? 0
        return CursorCompactResult(sizeBefore: sizeBefore, sizeAfter: sizeAfter)
    }

    func clean(items: [CleanupItem]) -> CleanupResult {
        let fileManager = FileManager.default
        var removedCount = 0
        var reclaimedSize: Int64 = 0
        var failures: [CleanupFailure] = []

        for item in items {
            guard isAllowedForDeletion(item) else {
                failures.append(
                    CleanupFailure(path: item.path, message: "The path is outside the cleanup allowlist.")
                )
                continue
            }

            guard fileManager.fileExists(atPath: item.path) else {
                continue
            }

            do {
                try fileManager.removeItem(at: URL(fileURLWithPath: item.path))
                removedCount += 1
                reclaimedSize += item.allocatedSize
            } catch {
                failures.append(CleanupFailure(path: item.path, message: error.localizedDescription))
            }
        }

        return CleanupResult(
            removedCount: removedCount,
            reclaimedSize: reclaimedSize,
            failures: failures
        )
    }

    static func detectCursorRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            if application.bundleIdentifier == "com.todesktop.230313mzl4w4u92" {
                return true
            }
            let name = (application.localizedName ?? "").lowercased()
            return name == "cursor" || name.hasPrefix("cursor helper")
        }
    }

    private func scanDiskUsage() -> DiskUsage? {
        guard let values = try? paths.homeDirectory.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        ),
        let total = values.volumeTotalCapacity, total > 0,
        let available = values.volumeAvailableCapacity else {
            return nil
        }

        return DiskUsage(
            totalCapacity: Int64(total),
            availableCapacity: Int64(min(total, max(0, available)))
        )
    }

    private func scanCursorDatabase() -> CursorDatabaseStatus? {
        guard let allocatedSize = existingAllocatedSize(at: paths.activeCursorDatabase) else {
            return nil
        }
        return CursorDatabaseStatus(
            path: paths.activeCursorDatabase.path,
            allocatedSize: allocatedSize,
            walSize: existingAllocatedSize(at: paths.activeCursorDatabaseWAL) ?? 0,
            isCursorRunning: isCursorRunning(),
            availableDiskSpace: volumeAvailableCapacity(at: paths.activeCursorDatabase)
        )
    }

    private func volumeAvailableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let capacity = fallback?.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return nil
    }

    private func rebuildCompactedDatabase(to destination: URL) throws {
        let tables = try sqliteMasterObjects(from: paths.activeCursorDatabase, type: "table")
        let indexes = try sqliteMasterObjects(from: paths.activeCursorDatabase, type: "index")
        let views = try sqliteMasterObjects(from: paths.activeCursorDatabase, type: "view")
        let triggers = try sqliteMasterObjects(from: paths.activeCursorDatabase, type: "trigger")

        var statements = [
            "PRAGMA journal_mode=OFF;",
            "PRAGMA synchronous=OFF;",
            "ATTACH DATABASE \(quoteSQLString(paths.activeCursorDatabase.path)) AS src;"
        ]

        for table in tables {
            statements.append(statement(from: table.sql))
            let quoted = quoteSQLIdentifier(table.name)
            if table.name == "cursorDiskKV" {
                statements.append(
                    """
                    INSERT INTO \(quoted) SELECT * FROM src.\(quoted)
                    WHERE key NOT LIKE 'agentKv:%'
                      AND key NOT LIKE 'bubbleId:%'
                      AND key NOT LIKE 'checkpointId:%'
                      AND key NOT LIKE 'composerData:%';
                    """
                )
            } else {
                statements.append("INSERT INTO \(quoted) SELECT * FROM src.\(quoted);")
            }
        }

        for object in indexes + views + triggers {
            statements.append(statement(from: object.sql))
        }

        statements.append("DETACH DATABASE src;")

        _ = try runSQLite(on: destination, statements.joined(separator: "\n"), captureOutput: false)
        let integrity = try runSQLite(on: destination, "PRAGMA integrity_check;", captureOutput: true)
            .standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard integrity == "ok" else {
            throw CursorCompactError.commandFailed(
                integrity.isEmpty ? "The compacted database failed its integrity check." : integrity
            )
        }
    }

    private func replaceActiveDatabase(with compacted: URL) throws {
        let fileManager = FileManager.default
        for sidecar in [paths.activeCursorDatabaseWAL, paths.activeCursorDatabaseSHM] {
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
        _ = try fileManager.replaceItemAt(paths.activeCursorDatabase, withItemAt: compacted)
    }

    private func sqliteMasterObjects(
        from database: URL,
        type: String
    ) throws -> [(name: String, sql: String)] {
        let output = try runSQLite(
            on: database,
            """
            SELECT name, sql FROM sqlite_master
            WHERE type='\(type.replacingOccurrences(of: "'", with: "''"))'
              AND name NOT LIKE 'sqlite_%'
              AND sql IS NOT NULL
            ORDER BY name;
            """,
            captureOutput: true,
            recordSeparator: "\u{1e}",
            columnSeparator: "\u{1f}"
        )
        return output.standardOutput
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let columns = record.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
                guard columns.count == 2 else {
                    return nil
                }
                let name = String(columns[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let sql = String(columns[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !sql.isEmpty else {
                    return nil
                }
                return (name, sql)
            }
    }

    private func statement(from sql: String) -> String {
        sql.hasSuffix(";") ? sql : sql + ";"
    }

    private func quoteSQLIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func quoteSQLString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func runSQLite(
        on database: URL,
        _ sql: String,
        captureOutput: Bool,
        recordSeparator: String? = nil,
        columnSeparator: String? = nil
    ) throws -> (standardOutput: String, error: String) {
        let process = Process()
        process.executableURL = sqliteExecutable
        var arguments = ["-noheader"]
        if let recordSeparator {
            arguments += ["-newline", recordSeparator]
        }
        if let columnSeparator {
            arguments += ["-separator", columnSeparator]
        }
        arguments.append(database.path)
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let standardOutput = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw CursorCompactError.commandFailed(error)
        }
        if !error.isEmpty {
            throw CursorCompactError.commandFailed(error)
        }
        return (captureOutput ? standardOutput : "", error)
    }

    private func scanChildren(
        at root: URL,
        categoryID: CleanupCategoryID,
        matches: (URL) -> Bool
    ) -> CleanupCategory {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return CleanupCategory(id: categoryID, items: [], scanErrors: [])
        }

        do {
            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
            var items: [CleanupItem] = []
            var errors: [String] = []

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                    guard values.isSymbolicLink != true, matches(child) else {
                        continue
                    }
                    items.append(
                        CleanupItem(
                            categoryID: categoryID,
                            path: child.path,
                            allocatedSize: try allocatedSize(of: child)
                        )
                    )
                } catch {
                    errors.append("\(child.path): \(error.localizedDescription)")
                }
            }

            return CleanupCategory(id: categoryID, items: items, scanErrors: errors)
        } catch {
            return CleanupCategory(
                id: categoryID,
                items: [],
                scanErrors: ["\(root.path): \(error.localizedDescription)"]
            )
        }
    }

    private func scanSingleFile(
        at url: URL,
        categoryID: CleanupCategoryID
    ) -> CleanupCategory {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CleanupCategory(id: categoryID, items: [], scanErrors: [])
        }

        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                return CleanupCategory(id: categoryID, items: [], scanErrors: [])
            }
            let item = CleanupItem(
                categoryID: categoryID,
                path: url.path,
                allocatedSize: try allocatedSize(of: url)
            )
            return CleanupCategory(id: categoryID, items: [item], scanErrors: [])
        } catch {
            return CleanupCategory(
                id: categoryID,
                items: [],
                scanErrors: ["\(url.path): \(error.localizedDescription)"]
            )
        }
    }

    private func existingAllocatedSize(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? allocatedSize(of: url)
    }

    private func allocatedSize(of root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true else {
            return 0
        }

        if rootValues.isDirectory != true {
            return Int64(rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var size: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return size
    }

    private func isRecognizedTemporaryItem(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        if Self.temporaryExtensions.contains(fileExtension) {
            return true
        }

        guard
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
            values.isDirectory == true
        else {
            return false
        }
        let name = url.lastPathComponent.lowercased()
        return Self.temporaryDirectoryPrefixes.contains { name.hasPrefix($0) }
    }

    private func scanXcodeCompilationCachesAndIndexes() -> CleanupCategory {
        let derivedData = scanChildren(
            at: paths.xcodeDerivedData,
            categoryID: .xcodeDerivedData,
            matches: { _ in true }
        )
        let documentationCache = scanExistingDirectory(
            at: paths.xcodeDocumentationCache,
            categoryID: .xcodeDerivedData
        )
        let documentationIndex = scanExistingDirectory(
            at: paths.xcodeDocumentationIndex,
            categoryID: .xcodeDerivedData
        )

        return CleanupCategory(
            id: .xcodeDerivedData,
            items: (derivedData.items + documentationCache + documentationIndex)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            scanErrors: derivedData.scanErrors
        )
    }

    private func scanExistingDirectory(
        at url: URL,
        categoryID: CleanupCategoryID
    ) -> [CleanupItem] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                return []
            }
            return [
                CleanupItem(
                    categoryID: categoryID,
                    path: url.path,
                    allocatedSize: try allocatedSize(of: url)
                )
            ]
        } catch {
            return []
        }
    }

    private func isAllowedForDeletion(_ item: CleanupItem) -> Bool {
        let url = URL(fileURLWithPath: item.path).standardizedFileURL
        switch item.categoryID {
        case .coreDeviceDeltas:
            return url.deletingLastPathComponent().standardizedFileURL == paths.coreDeviceDeltas.standardizedFileURL
        case .xcodeDerivedData:
            let parent = url.deletingLastPathComponent().standardizedFileURL
            return parent == paths.xcodeDerivedData.standardizedFileURL
                || url == paths.xcodeDocumentationCache.standardizedFileURL
                || url == paths.xcodeDocumentationIndex.standardizedFileURL
        case .mobileBuildTemporaryFiles:
            return url.deletingLastPathComponent().standardizedFileURL == paths.temporaryDirectory.standardizedFileURL
                && isRecognizedTemporaryItem(url)
        case .cursorBackup:
            return url == paths.cursorBackup.standardizedFileURL
        }
    }
}
