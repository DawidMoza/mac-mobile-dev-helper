import Foundation

enum CleanupCategoryID: String, CaseIterable, Identifiable, Sendable {
    case coreDeviceDeltas
    case xcodeDerivedData
    case mobileBuildTemporaryFiles
    case cursorBackup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coreDeviceDeltas:
            "CoreDevice installation deltas"
        case .xcodeDerivedData:
            "Xcode compilation caches & indexes"
        case .mobileBuildTemporaryFiles:
            "Mobile build temporary files"
        case .cursorBackup:
            "Cursor database backup"
        }
    }

    var detail: String {
        switch self {
        case .coreDeviceDeltas:
            "Incremental physical-device installation caches. The next installation may be slower."
        case .xcodeDerivedData:
            "DerivedData build products, module/compilation caches, and Xcode documentation indexes. The next build or doc lookup may be slower."
        case .mobileBuildTemporaryFiles:
            "Recognized Android, iOS, and Godot build artifacts directly under /private/tmp."
        case .cursorBackup:
            "Cursor's fallback database copy. The active database is compacted separately and never selected here."
        }
    }

    var isSelectedByDefault: Bool {
        false
    }
}

struct CleanupItem: Identifiable, Hashable, Sendable {
    let categoryID: CleanupCategoryID
    let path: String
    let allocatedSize: Int64

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct CleanupCategory: Identifiable, Sendable {
    let id: CleanupCategoryID
    let items: [CleanupItem]
    let scanErrors: [String]

    var totalAllocatedSize: Int64 {
        items.reduce(0) { $0 + $1.allocatedSize }
    }
}

struct CursorDatabaseStatus: Sendable {
    let path: String
    let allocatedSize: Int64
    let walSize: Int64
    let isCursorRunning: Bool
    let availableDiskSpace: Int64?

    var needsCompaction: Bool {
        allocatedSize >= 1_073_741_824
    }

    static let minimumFreeSpaceToCompact: Int64 = 64 * 1_024 * 1_024

    var hasEnoughDiskSpaceToCompact: Bool {
        guard let availableDiskSpace else {
            return true
        }
        return availableDiskSpace >= Self.minimumFreeSpaceToCompact
    }
}

struct CursorCompactResult: Sendable {
    let sizeBefore: Int64
    let sizeAfter: Int64

    var reclaimedSize: Int64 {
        max(0, sizeBefore - sizeAfter)
    }
}

enum CursorCompactError: LocalizedError, Equatable {
    case cursorIsRunning
    case databaseMissing
    case sqliteMissing
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cursorIsRunning:
            "Quit Cursor completely before compacting the database."
        case .databaseMissing:
            "The active Cursor database was not found."
        case .sqliteMissing:
            "sqlite3 is required to compact the Cursor database."
        case .notEnoughDiskSpace(let needed, let available):
            "Compacting writes a small new copy and needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free. This volume has \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))."
        case .commandFailed(let message):
            message.isEmpty ? "Compacting the Cursor database failed." : message
        }
    }
}

struct CleanupSnapshot: Sendable {
    let categories: [CleanupCategory]
    let cursorDatabase: CursorDatabaseStatus?

    var activeCursorDatabaseSize: Int64? {
        cursorDatabase?.allocatedSize
    }

    static let empty = CleanupSnapshot(
        categories: CleanupCategoryID.allCases.map {
            CleanupCategory(id: $0, items: [], scanErrors: [])
        },
        cursorDatabase: nil
    )
}

struct CleanupFailure: Identifiable, Sendable {
    let path: String
    let message: String

    var id: String { path }
}

struct CleanupResult: Sendable {
    let removedCount: Int
    let reclaimedSize: Int64
    let failures: [CleanupFailure]
}
