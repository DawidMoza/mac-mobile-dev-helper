import Foundation

enum AndroidDeviceState: Hashable, Sendable {
    case connected
    case unauthorized
    case offline
    case recovery
    case sideload
    case bootloader
    case unknown(String)

    init(adbValue: String) {
        switch adbValue {
        case "device":
            self = .connected
        case "unauthorized":
            self = .unauthorized
        case "offline":
            self = .offline
        case "recovery":
            self = .recovery
        case "sideload":
            self = .sideload
        case "bootloader":
            self = .bootloader
        default:
            self = .unknown(adbValue)
        }
    }

    var label: String {
        switch self {
        case .connected:
            "Connected"
        case .unauthorized:
            "Unauthorized"
        case .offline:
            "Offline"
        case .recovery:
            "Recovery"
        case .sideload:
            "Sideload"
        case .bootloader:
            "Bootloader"
        case .unknown(let value):
            value.isEmpty ? "Unknown" : value.capitalized
        }
    }
}

struct AndroidDevice: Identifiable, Hashable, Sendable {
    let serial: String
    let state: AndroidDeviceState
    let model: String?
    let product: String?
    let transportID: String?

    var id: String { serial }

    var displayName: String {
        guard let model, !model.isEmpty else {
            return serial
        }
        return model.replacingOccurrences(of: "_", with: " ")
    }
}

struct AndroidRemotePath: Hashable, Identifiable, Sendable {
    let root: String
    let value: String

    var id: String { value }
    var name: String {
        value == root ? "Internal storage" : URL(fileURLWithPath: value).lastPathComponent
    }
    var isRoot: Bool { value == root }

    init(root: String, value: String) throws {
        let normalizedRoot = Self.normalizeRoot(root)
        guard normalizedRoot.hasPrefix("/"), normalizedRoot != "/" else {
            throw AndroidFilesystemError.unsafePath(root)
        }
        guard
            !value.contains("\0"),
            value.hasPrefix("/"),
            value == normalizedRoot || value.hasPrefix(normalizedRoot + "/")
        else {
            throw AndroidFilesystemError.unsafePath(value)
        }

        let relative = value == normalizedRoot
            ? ""
            : String(value.dropFirst(normalizedRoot.count + 1))
        if !relative.isEmpty {
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw AndroidFilesystemError.unsafePath(value)
            }
        }

        self.root = normalizedRoot
        self.value = value
    }

    func appending(name: String) throws -> AndroidRemotePath {
        try Self.validateName(name)
        return try AndroidRemotePath(
            root: root,
            value: value + (value.hasSuffix("/") ? "" : "/") + name
        )
    }

    var parent: AndroidRemotePath? {
        guard !isRoot else {
            return nil
        }
        let parentValue = String(value.prefix(upTo: value.lastIndex(of: "/")!))
        return try? AndroidRemotePath(root: root, value: parentValue)
    }

    static func validateName(_ name: String) throws {
        guard
            !name.isEmpty,
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.contains("\0")
        else {
            throw AndroidFilesystemError.invalidName(name)
        }
    }

    private static func normalizeRoot(_ root: String) -> String {
        if root.count > 1, root.hasSuffix("/") {
            return String(root.dropLast())
        }
        return root
    }
}

enum AndroidEntryKind: String, Hashable, Sendable {
    case directory
    case file
    case symbolicLink
    case other

    var isDirectory: Bool { self == .directory }
    var isEditable: Bool { self == .file }
}

struct AndroidFileEntry: Identifiable, Hashable, Sendable {
    let path: AndroidRemotePath
    let kind: AndroidEntryKind
    let size: Int64
    let modifiedAt: Date?

    var id: String { path.value }
    var name: String { path.name }
}

struct AndroidDirectorySnapshot: Sendable {
    let path: AndroidRemotePath
    let entries: [AndroidFileEntry]
}

enum AndroidTextEncoding: String, Sendable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 with BOM"
    case utf16LittleEndian = "UTF-16 LE"
    case utf16BigEndian = "UTF-16 BE"
}

struct AndroidEditableDocument: Identifiable, Sendable {
    let path: AndroidRemotePath
    var text: String
    let encoding: AndroidTextEncoding
    let originalData: Data

    var id: String { path.value }
}

enum AndroidFilesystemError: LocalizedError, Equatable {
    case adbNotFound
    case commandFailed(String)
    case commandTimedOut
    case outputTooLarge
    case deviceUnavailable(String)
    case unsafePath(String)
    case invalidName(String)
    case invalidDirectoryListing
    case fileTooLarge(Int64)
    case unsupportedTextEncoding
    case fileChanged
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound:
            "ADB was not found. Install Android SDK Platform-Tools and reopen the app."
        case .commandFailed(let message):
            message.isEmpty ? "ADB command failed." : message
        case .commandTimedOut:
            "ADB did not respond before the operation timed out."
        case .outputTooLarge:
            "ADB returned more data than this operation allows."
        case .deviceUnavailable(let state):
            "The Android device is not ready (\(state))."
        case .unsafePath(let path):
            "The path is outside Android shared storage: \(path)"
        case .invalidName(let name):
            "The name is not valid: \(name)"
        case .invalidDirectoryListing:
            "The Android directory listing could not be read safely."
        case .fileTooLarge(let size):
            "The file is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)). Text editing is limited to 1 MB."
        case .unsupportedTextEncoding:
            "The file is binary or does not use supported UTF-8/UTF-16 text encoding."
        case .fileChanged:
            "The file changed on the device after it was opened. Reopen it before saving."
        case .destinationExists(let path):
            "An item already exists at \(path)."
        }
    }
}
