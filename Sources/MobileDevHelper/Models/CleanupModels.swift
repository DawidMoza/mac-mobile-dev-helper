import Foundation

enum CleanupCategoryID: String, CaseIterable, Identifiable, Sendable {
    case coreDeviceDeltas
    case xcodeDerivedData
    case mobileBuildTemporaryFiles
    case cursorBackup
    case codexCaches
    case codexHistory
    case claudeCodeCaches
    case claudeCodeHistory

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
        case .codexCaches:
            "Codex logs & caches"
        case .codexHistory:
            "Codex conversation history"
        case .claudeCodeCaches:
            "Claude Code debug logs & caches"
        case .claudeCodeHistory:
            "Claude Code conversation history"
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
        case .codexCaches:
            "Log files, cached files, and shell snapshots. Quit Codex and its CLI sessions before deleting."
        case .codexHistory:
            "Session and archived transcripts, plus prompt history. Deletion permanently removes local conversations and may leave unavailable chats in the session list."
        case .claudeCodeCaches:
            "Debug logs and cached files. Quit Claude Code sessions before deleting."
        case .claudeCodeHistory:
            "Session and subagent transcripts, plus prompt history. Deleted conversations can no longer be resumed. Project memory is preserved."
        }
    }

    var isSelectedByDefault: Bool {
        false
    }

    var agent: CleanupAgent? {
        switch self {
        case .codexCaches, .codexHistory: .codex
        case .claudeCodeCaches, .claudeCodeHistory: .claudeCode
        default: nil
        }
    }

    var removesConversationHistory: Bool {
        self == .codexHistory || self == .claudeCodeHistory
    }
}

enum CleanupAgent: String, CaseIterable, Sendable {
    case codex
    case claudeCode

    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

struct CodexDatabaseStatus: Identifiable, Sendable {
    let path: String
    let allocatedSize: Int64
    let walSize: Int64
    let availableDiskSpace: Int64?

    var id: String { path }
    // SQLite VACUUM may need up to twice the original database size in free space.
    let requiredFreeSpace: Int64

    var hasEnoughDiskSpace: Bool {
        availableDiskSpace.map { $0 >= requiredFreeSpace } ?? true
    }
}

enum AgentCleanupError: LocalizedError {
    case appIsRunning(CleanupAgent)
    case invalidDatabase
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .appIsRunning(let agent):
            "Quit \(agent.title), including terminal sessions and editor extensions, then refresh and try again."
        case .invalidDatabase:
            "The database is missing or outside the Codex database allowlist."
        case .insufficientSpace:
            "There is not enough free space to compact this database safely."
        }
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

struct DiskUsage: Sendable {
    let totalCapacity: Int64
    let availableCapacity: Int64

    var usedCapacity: Int64 {
        totalCapacity - availableCapacity
    }

    var usedFraction: Double {
        Double(usedCapacity) / Double(totalCapacity)
    }
}

struct CleanupSnapshot: Sendable {
    let categories: [CleanupCategory]
    let cursorDatabase: CursorDatabaseStatus?
    let diskUsage: DiskUsage?
    var codexDatabases: [CodexDatabaseStatus] = []
    var runningAgents: Set<CleanupAgent> = []
    var agentDatabaseScanErrors: [String] = []

    var activeCursorDatabaseSize: Int64? {
        cursorDatabase?.allocatedSize
    }

    static let empty = CleanupSnapshot(
        categories: CleanupCategoryID.allCases.map {
            CleanupCategory(id: $0, items: [], scanErrors: [])
        },
        cursorDatabase: nil,
        diskUsage: nil
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
