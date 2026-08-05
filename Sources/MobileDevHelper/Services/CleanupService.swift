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

    init(paths: CleanupPaths = .live) {
        self.paths = paths
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
            activeCursorDatabaseSize: existingAllocatedSize(at: paths.activeCursorDatabase)
        )
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
