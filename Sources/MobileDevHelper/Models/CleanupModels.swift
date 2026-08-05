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
            "Cursor's fallback database copy. The active database and chat history are never selected."
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

struct CleanupSnapshot: Sendable {
    let categories: [CleanupCategory]
    let activeCursorDatabaseSize: Int64?

    static let empty = CleanupSnapshot(
        categories: CleanupCategoryID.allCases.map {
            CleanupCategory(id: $0, items: [], scanErrors: [])
        },
        activeCursorDatabaseSize: nil
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
