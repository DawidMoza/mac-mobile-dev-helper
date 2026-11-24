import Foundation

struct CustomCleanupPaths: Sendable {
    let homeDirectory: URL

    var fileURL: URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/Mac Mobile Dev Helper/custom-cleanup-paths.txt"
        )
    }

    func read() throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }

    func save(_ text: String, replacing original: String) throws {
        guard try read() == original else { throw CustomCleanupError.configurationChanged }
        try createDirectory()
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func prepareFileForEditing() throws -> URL {
        try createDirectory()
        do {
            try Data().write(to: fileURL, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            // Keep existing text, including any edits from another app.
        }
        return fileURL
    }

    func configuredPaths() throws -> (urls: [URL], errors: [String]) {
        var urls: [URL] = []
        var errors: [String] = []
        var seen: Set<String> = []

        for (index, line) in try read().split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            guard let url = targetURL(for: text) else {
                errors.append("Line \(index + 1): Enter an absolute path or a path starting with ~/ without parent-directory components.")
                continue
            }
            if seen.insert(url.path).inserted {
                urls.append(url)
            }
        }

        return (urls, errors)
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    private func targetURL(for text: String) -> URL? {
        guard text.hasPrefix("/") || text.hasPrefix("~/"),
              !text.contains("\0"), !text.split(separator: "/").contains("..") else { return nil }
        let path = text.hasPrefix("~/") ? homeDirectory.path + String(text.dropFirst()) : text
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }
}

enum CustomCleanupError: LocalizedError {
    case configurationChanged
    case protectedPath
    case unsupportedFileType
    case couldNotOpenFile

    var errorDescription: String? {
        switch self {
        case .configurationChanged:
            "The text file changed while this editor was open. Reload it before saving."
        case .protectedPath:
            "This path includes a protected location or uses a symbolic link."
        case .unsupportedFileType:
            "Choose a regular file or folder."
        case .couldNotOpenFile:
            "macOS could not open the custom paths text file."
        }
    }
}
