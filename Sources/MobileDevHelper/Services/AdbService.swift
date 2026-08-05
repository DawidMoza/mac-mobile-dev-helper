import Darwin
import Foundation

struct ADBCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

protocol ADBCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputSize: Int
    ) async throws -> ADBCommandResult
}

struct ADBProcessRunner: ADBCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputSize: Int
    ) async throws -> ADBCommandResult {
        let runningProcess = ADBRunningProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.runSynchronously(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout,
                    maximumOutputSize: maximumOutputSize,
                    runningProcess: runningProcess
                )
            }.value
        } onCancel: {
            runningProcess.cancel()
        }
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputSize: Int,
        runningProcess: ADBRunningProcess
    ) throws -> ADBCommandResult {
        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacMobileDevHelper-ADB-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outputDirectory) }

        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        runningProcess.register(process)

        if runningProcess.isCancelled {
            throw CancellationError()
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !runningProcess.isCancelled {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        runningProcess.clear(process)
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        if runningProcess.isCancelled {
            throw CancellationError()
        }
        guard Date() < deadline || process.terminationStatus == 0 else {
            throw AndroidFilesystemError.commandTimedOut
        }

        let stdout = try Data(contentsOf: stdoutURL, options: .mappedIfSafe)
        let stderr = try Data(contentsOf: stderrURL, options: .mappedIfSafe)
        guard stdout.count + stderr.count <= maximumOutputSize else {
            throw AndroidFilesystemError.outputTooLarge
        }
        return ADBCommandResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }
}

private final class ADBRunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func register(_ process: Process) {
        lock.withLock {
            self.process = process
            if cancelled, process.isRunning {
                process.terminate()
            }
        }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning {
                process.terminate()
            }
        }
    }
}

struct ADBLocator: Sendable {
    let environment: [String: String]
    let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func candidates() -> [URL] {
        var urls: [URL] = []
        if let path = environment["PATH"] {
            urls += path
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("adb") }
        }
        urls.append(URL(fileURLWithPath: "/opt/homebrew/bin/adb"))
        urls.append(URL(fileURLWithPath: "/usr/local/bin/adb"))
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdkPath = environment[variable], !sdkPath.isEmpty {
                urls.append(
                    URL(fileURLWithPath: sdkPath, isDirectory: true)
                        .appendingPathComponent("platform-tools/adb")
                )
            }
        }
        urls.append(
            homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        )

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    func locate(using runner: any ADBCommandRunning) async throws -> URL {
        for candidate in candidates()
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            guard let result = try? await runner.run(
                executableURL: candidate,
                arguments: ["version"],
                timeout: 5,
                maximumOutputSize: 64 * 1_024
            ), result.exitCode == 0 else {
                continue
            }
            return candidate.standardizedFileURL
        }
        throw AndroidFilesystemError.adbNotFound
    }
}

enum ADBRemoteShell {
    static func arguments(script: String, parameters: [String]) -> [String] {
        let encoded = (["sh", "-c", script, "mac-mobile-dev-helper"] + parameters)
            .map(quote)
            .joined(separator: " ")
        return ["shell", "-T", encoded]
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

actor AdbService {
    static let maximumEditableFileSize: Int64 = 1_048_576

    private let runner: any ADBCommandRunning
    private let locator: ADBLocator
    private var adbURL: URL?

    init(
        runner: any ADBCommandRunning = ADBProcessRunner(),
        locator: ADBLocator = ADBLocator()
    ) {
        self.runner = runner
        self.locator = locator
    }

    func locateADB() async throws -> URL {
        if let adbURL {
            return adbURL
        }
        let located = try await locator.locate(using: runner)
        adbURL = located
        return located
    }

    func devices() async throws -> [AndroidDevice] {
        let result = try await runADB(
            arguments: ["devices", "-l"],
            timeout: 10,
            maximumOutputSize: 1_048_576
        )
        return Self.parseDevices(String(decoding: result.stdout, as: UTF8.self))
    }

    func sharedStorageRoot(serial: String) async throws -> AndroidRemotePath {
        try await requireConnected(serial: serial)
        let result = try await runShell(
            serial: serial,
            script: "resolved=$(realpath \"$1\") || exit 1; printf '%s\\0' \"$resolved\"",
            parameters: ["/sdcard"]
        )
        guard
            let rawRoot = result.stdout.split(separator: 0).first,
            let root = String(data: Data(rawRoot), encoding: .utf8)
        else {
            throw AndroidFilesystemError.invalidDirectoryListing
        }
        return try AndroidRemotePath(root: root, value: root)
    }

    func listDirectory(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> AndroidDirectorySnapshot {
        try await requireConnected(serial: serial)
        let canonical = try await canonicalPath(serial: serial, path: path)
        let preferred = try? await runShell(
            serial: serial,
            script: "find \"$1\" -mindepth 1 -maxdepth 1 -printf '%p\\0%y\\0%s\\0%T@\\0'",
            parameters: [canonical.value],
            maximumOutputSize: 16 * 1_024 * 1_024
        )

        let entries: [AndroidFileEntry]
        if let preferred, let parsed = try? Self.parseDirectoryListing(
            preferred.stdout,
            root: canonical.root
        ) {
            entries = parsed
        } else if let batched = try? await runShell(
            serial: serial,
            script: """
            find "$1" -mindepth 1 -maxdepth 1 -print0 |
            while IFS= read -r -d '' path; do
                if [ -L "$path" ]; then type=l
                elif [ -d "$path" ]; then type=d
                elif [ -f "$path" ]; then type=f
                else type=o
                fi
                size=$(stat -c %s "$path" 2>/dev/null || printf 0)
                modified=$(stat -c %Y "$path" 2>/dev/null || printf 0)
                printf '%s\\0%s\\0%s\\0%s\\0' "$path" "$type" "$size" "$modified"
            done
            """,
            parameters: [canonical.value],
            maximumOutputSize: 16 * 1_024 * 1_024
        ), let parsed = try? Self.parseDirectoryListing(
            batched.stdout,
            root: canonical.root
        ) {
            entries = parsed
        } else {
            entries = try await listDirectoryFallback(serial: serial, path: canonical)
        }

        return AndroidDirectorySnapshot(
            path: canonical,
            entries: entries.sorted {
                if $0.kind.isDirectory != $1.kind.isDirectory {
                    return $0.kind.isDirectory
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        )
    }

    func createDirectory(
        serial: String,
        parent: AndroidRemotePath,
        name: String
    ) async throws {
        try AndroidRemotePath.validateName(name)
        let canonicalParent = try await canonicalPath(serial: serial, path: parent)
        let destination = try canonicalParent.appending(name: name)
        let destinationExists = try await remoteItemExists(serial: serial, path: destination)
        guard !destinationExists else {
            throw AndroidFilesystemError.destinationExists(destination.value)
        }
        _ = try await runShell(
            serial: serial,
            script: "mkdir \"$1\"",
            parameters: [destination.value]
        )
    }

    func rename(
        serial: String,
        path: AndroidRemotePath,
        newName: String
    ) async throws {
        try AndroidRemotePath.validateName(newName)
        guard let parent = path.parent else {
            throw AndroidFilesystemError.unsafePath(path.value)
        }
        let canonicalSource = try await canonicalPath(serial: serial, path: path)
        let canonicalParent = try await canonicalPath(serial: serial, path: parent)
        let destination = try canonicalParent.appending(name: newName)
        let destinationExists = try await remoteItemExists(serial: serial, path: destination)
        guard !destinationExists else {
            throw AndroidFilesystemError.destinationExists(destination.value)
        }
        _ = try await runShell(
            serial: serial,
            script: "mv \"$1\" \"$2\"",
            parameters: [canonicalSource.value, destination.value]
        )
    }

    func delete(
        serial: String,
        path: AndroidRemotePath,
        isDirectory: Bool
    ) async throws {
        guard !path.isRoot else {
            throw AndroidFilesystemError.unsafePath(path.value)
        }
        let canonical = try await canonicalPath(serial: serial, path: path)
        let script = isDirectory ? "rm -rf \"$1\"" : "rm -f \"$1\""
        _ = try await runShell(
            serial: serial,
            script: script,
            parameters: [canonical.value]
        )
    }

    func openTextDocument(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> AndroidEditableDocument {
        let data = try await readFileData(serial: serial, path: path)
        let decoded = try Self.decodeText(data)
        return AndroidEditableDocument(
            path: path,
            text: decoded.text,
            encoding: decoded.encoding,
            originalData: data
        )
    }

    func saveTextDocument(
        serial: String,
        document: AndroidEditableDocument
    ) async throws {
        let currentData = try await readFileData(serial: serial, path: document.path)
        guard currentData == document.originalData else {
            throw AndroidFilesystemError.fileChanged
        }
        let encoded = try Self.encodeText(document.text, encoding: document.encoding)
        try await uploadData(
            encoded,
            serial: serial,
            destination: document.path,
            replaceExisting: true
        )
    }

    func upload(
        serial: String,
        localURL: URL,
        to directory: AndroidRemotePath
    ) async throws {
        try AndroidRemotePath.validateName(localURL.lastPathComponent)
        let canonicalDirectory = try await canonicalPath(serial: serial, path: directory)
        let destination = try canonicalDirectory.appending(name: localURL.lastPathComponent)
        let destinationExists = try await remoteItemExists(serial: serial, path: destination)
        guard !destinationExists else {
            throw AndroidFilesystemError.destinationExists(destination.value)
        }
        let dataSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try await uploadLocalFile(
            localURL,
            size: Int64(dataSize),
            serial: serial,
            destination: destination,
            replaceExisting: false
        )
    }

    func download(
        serial: String,
        path: AndroidRemotePath,
        to destinationURL: URL
    ) async throws {
        let canonical = try await canonicalPath(serial: serial, path: path)
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacMobileDevHelper-Download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let temporaryURL = temporaryDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        _ = try await runADB(
            arguments: ["-s", serial, "pull", canonical.value, temporaryURL.path],
            timeout: 120,
            maximumOutputSize: 1_048_576
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    static func parseDevices(_ output: String) -> [AndroidDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> AndroidDevice? in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2 else {
                    return nil
                }
                let attributes = Dictionary(
                    uniqueKeysWithValues: columns.dropFirst(2).compactMap { column -> (String, String)? in
                        let parts = column.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2 else {
                            return nil
                        }
                        return (String(parts[0]), String(parts[1]))
                    }
                )
                return AndroidDevice(
                    serial: String(columns[0]),
                    state: AndroidDeviceState(adbValue: String(columns[1])),
                    model: attributes["model"],
                    product: attributes["product"],
                    transportID: attributes["transport_id"]
                )
            }
    }

    static func parseDirectoryListing(
        _ data: Data,
        root: String
    ) throws -> [AndroidFileEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        let meaningfulFields = fields.last?.isEmpty == true ? fields.dropLast() : fields[...]
        guard meaningfulFields.count.isMultiple(of: 4) else {
            throw AndroidFilesystemError.invalidDirectoryListing
        }

        var entries: [AndroidFileEntry] = []
        var index = meaningfulFields.startIndex
        while index < meaningfulFields.endIndex {
            let pathData = Data(meaningfulFields[index])
            let typeData = Data(meaningfulFields[meaningfulFields.index(index, offsetBy: 1)])
            let sizeData = Data(meaningfulFields[meaningfulFields.index(index, offsetBy: 2)])
            let modifiedData = Data(meaningfulFields[meaningfulFields.index(index, offsetBy: 3)])
            guard
                let pathText = String(data: pathData, encoding: .utf8),
                let typeText = String(data: typeData, encoding: .utf8),
                let sizeText = String(data: sizeData, encoding: .utf8),
                let size = Int64(sizeText),
                let modifiedText = String(data: modifiedData, encoding: .utf8)
            else {
                throw AndroidFilesystemError.invalidDirectoryListing
            }

            let kind: AndroidEntryKind
            switch typeText {
            case "d":
                kind = .directory
            case "f":
                kind = .file
            case "l":
                kind = .symbolicLink
            default:
                kind = .other
            }
            let modifiedAt = Double(modifiedText).map(Date.init(timeIntervalSince1970:))
            entries.append(
                AndroidFileEntry(
                    path: try AndroidRemotePath(root: root, value: pathText),
                    kind: kind,
                    size: size,
                    modifiedAt: modifiedAt
                )
            )
            index = meaningfulFields.index(index, offsetBy: 4)
        }
        return entries
    }

    static func decodeText(
        _ data: Data
    ) throws -> (text: String, encoding: AndroidTextEncoding) {
        guard data.count <= maximumEditableFileSize else {
            throw AndroidFilesystemError.fileTooLarge(Int64(data.count))
        }

        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8BOM)
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AndroidFilesystemError.unsupportedTextEncoding
        }
        return (text, .utf8)
    }

    static func encodeText(
        _ text: String,
        encoding: AndroidTextEncoding
    ) throws -> Data {
        let data: Data?
        switch encoding {
        case .utf8:
            data = text.data(using: .utf8)
        case .utf8BOM:
            data = Data([0xEF, 0xBB, 0xBF]) + (text.data(using: .utf8) ?? Data())
        case .utf16LittleEndian:
            data = Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BigEndian:
            data = Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data())
        }
        guard let data, data.count <= maximumEditableFileSize else {
            throw AndroidFilesystemError.fileTooLarge(Int64(data?.count ?? 0))
        }
        return data
    }

    private func listDirectoryFallback(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> [AndroidFileEntry] {
        let result = try await runShell(
            serial: serial,
            script: "find \"$1\" -mindepth 1 -maxdepth 1 -print0",
            parameters: [path.value],
            maximumOutputSize: 16 * 1_024 * 1_024
        )
        let rawPaths = result.stdout.split(separator: 0)
        var entries: [AndroidFileEntry] = []
        for rawPath in rawPaths {
            guard let pathText = String(data: Data(rawPath), encoding: .utf8) else {
                throw AndroidFilesystemError.invalidDirectoryListing
            }
            let remotePath = try AndroidRemotePath(root: path.root, value: pathText)
            let metadata = try await runShell(
                serial: serial,
                script: """
                if [ -L "$1" ]; then type=l
                elif [ -d "$1" ]; then type=d
                elif [ -f "$1" ]; then type=f
                else type=o
                fi
                size=$(stat -c %s "$1" 2>/dev/null || printf 0)
                modified=$(stat -c %Y "$1" 2>/dev/null || printf 0)
                printf '%s\\0%s\\0%s\\0' "$type" "$size" "$modified"
                """,
                parameters: [pathText]
            )
            let fields = metadata.stdout.split(separator: 0)
            guard
                fields.count == 3,
                let type = String(data: Data(fields[0]), encoding: .utf8),
                let sizeText = String(data: Data(fields[1]), encoding: .utf8),
                let size = Int64(sizeText),
                let modifiedText = String(data: Data(fields[2]), encoding: .utf8)
            else {
                throw AndroidFilesystemError.invalidDirectoryListing
            }
            let kind: AndroidEntryKind = switch type {
            case "d": .directory
            case "f": .file
            case "l": .symbolicLink
            default: .other
            }
            entries.append(
                AndroidFileEntry(
                    path: remotePath,
                    kind: kind,
                    size: size,
                    modifiedAt: Double(modifiedText).map(Date.init(timeIntervalSince1970:))
                )
            )
        }
        return entries
    }

    private func requireConnected(serial: String) async throws {
        let matchingDevice = try await devices().first { $0.serial == serial }
        guard let matchingDevice else {
            throw AndroidFilesystemError.deviceUnavailable("disconnected")
        }
        guard matchingDevice.state == .connected else {
            throw AndroidFilesystemError.deviceUnavailable(matchingDevice.state.label)
        }
    }

    private func canonicalPath(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> AndroidRemotePath {
        let result = try await runShell(
            serial: serial,
            script: "resolved=$(realpath \"$1\") || exit 1; printf '%s\\0' \"$resolved\"",
            parameters: [path.value]
        )
        guard
            let rawPath = result.stdout.split(separator: 0).first,
            let canonical = String(data: Data(rawPath), encoding: .utf8)
        else {
            throw AndroidFilesystemError.unsafePath(path.value)
        }
        return try AndroidRemotePath(root: path.root, value: canonical)
    }

    private func remoteItemExists(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> Bool {
        let result = try await runShell(
            serial: serial,
            script: "if [ -e \"$1\" ] || [ -L \"$1\" ]; then printf yes; fi",
            parameters: [path.value]
        )
        return result.stdout == Data("yes".utf8)
    }

    private func remoteFileSize(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> Int64 {
        let result = try await runShell(
            serial: serial,
            script: "stat -c %s \"$1\"",
            parameters: [path.value]
        )
        let value = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int64(value) else {
            throw AndroidFilesystemError.commandFailed("Could not read the remote file size.")
        }
        return size
    }

    private func readFileData(
        serial: String,
        path: AndroidRemotePath
    ) async throws -> Data {
        let canonical = try await canonicalPath(serial: serial, path: path)
        let size = try await remoteFileSize(serial: serial, path: canonical)
        guard size <= Self.maximumEditableFileSize else {
            throw AndroidFilesystemError.fileTooLarge(size)
        }
        let result = try await runShell(
            serial: serial,
            script: "cat \"$1\"",
            parameters: [canonical.value],
            maximumOutputSize: Int(Self.maximumEditableFileSize) + 1_024
        )
        return result.stdout
    }

    private func uploadData(
        _ data: Data,
        serial: String,
        destination: AndroidRemotePath,
        replaceExisting: Bool
    ) async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMobileDevHelper-Upload-\(UUID().uuidString)")
        try data.write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }
        try await uploadLocalFile(
            localURL,
            size: Int64(data.count),
            serial: serial,
            destination: destination,
            replaceExisting: replaceExisting
        )
    }

    private func uploadLocalFile(
        _ localURL: URL,
        size: Int64,
        serial: String,
        destination: AndroidRemotePath,
        replaceExisting: Bool
    ) async throws {
        guard let parent = destination.parent else {
            throw AndroidFilesystemError.unsafePath(destination.value)
        }
        let canonicalParent = try await canonicalPath(serial: serial, path: parent)
        let finalDestination = try canonicalParent.appending(name: destination.name)
        let destinationExists = try await remoteItemExists(
            serial: serial,
            path: finalDestination
        )
        if !replaceExisting, destinationExists {
            throw AndroidFilesystemError.destinationExists(finalDestination.value)
        }

        let temporary = try canonicalParent.appending(
            name: ".mac-mobile-dev-helper-\(UUID().uuidString).tmp"
        )
        do {
            _ = try await runADB(
                arguments: ["-s", serial, "push", localURL.path, temporary.value],
                timeout: 120,
                maximumOutputSize: 1_048_576
            )
            let remoteSize = try await remoteFileSize(serial: serial, path: temporary)
            guard remoteSize == size else {
                throw AndroidFilesystemError.commandFailed(
                    "The uploaded size did not match the local file."
                )
            }
            _ = try await runShell(
                serial: serial,
                script: replaceExisting
                    ? "mv -f \"$1\" \"$2\""
                    : "if [ -e \"$2\" ] || [ -L \"$2\" ]; then exit 17; fi; mv \"$1\" \"$2\"",
                parameters: [temporary.value, finalDestination.value]
            )
        } catch {
            _ = try? await runShell(
                serial: serial,
                script: "rm -f \"$1\"",
                parameters: [temporary.value]
            )
            throw error
        }
    }

    @discardableResult
    private func runShell(
        serial: String,
        script: String,
        parameters: [String],
        timeout: TimeInterval = 20,
        maximumOutputSize: Int = 4 * 1_024 * 1_024
    ) async throws -> ADBCommandResult {
        try await runADB(
            arguments: ["-s", serial] + ADBRemoteShell.arguments(
                script: script,
                parameters: parameters
            ),
            timeout: timeout,
            maximumOutputSize: maximumOutputSize
        )
    }

    private func runADB(
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputSize: Int
    ) async throws -> ADBCommandResult {
        try Task.checkCancellation()
        let executable = try await locateADB()
        let result = try await runner.run(
            executableURL: executable,
            arguments: arguments,
            timeout: timeout,
            maximumOutputSize: maximumOutputSize
        )
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidFilesystemError.commandFailed(
                stderr.isEmpty ? stdout : stderr
            )
        }
        return result
    }
}
