import Foundation

struct AppVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    let components: [Int]
    let original: String

    var description: String { original.hasPrefix("v") ? original : "v\(original)" }

    init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppUpdateError.invalidVersion(raw)
        }
        let normalized = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == parts.count else {
            throw AppUpdateError.invalidVersion(raw)
        }
        components = numbers
        original = "v\(normalized)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct AppReleaseInfo: Sendable, Equatable {
    let tag: String
    let htmlURL: URL?
    let publishedAt: Date?

    var version: AppVersion {
        get throws { try AppVersion(tag) }
    }
}

struct AppUpdateAvailability: Sendable, Equatable {
    let currentVersion: AppVersion
    let latestRelease: AppReleaseInfo

    var latestVersion: AppVersion {
        get throws { try latestRelease.version }
    }

    var isUpdateAvailable: Bool {
        (try? latestVersion > currentVersion) ?? false
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidVersion(String)
    case latestReleaseUnavailable
    case network(String)
    case missingTool(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVersion(let value):
            "Invalid version: \(value)"
        case .latestReleaseUnavailable:
            "No GitHub release was found."
        case .network(let message):
            message
        case .missingTool(let tool):
            "'\(tool)' is required to update. Install Xcode Command Line Tools, then retry."
        case .updateFailed(let message):
            message.isEmpty ? "The update failed." : message
        }
    }
}
