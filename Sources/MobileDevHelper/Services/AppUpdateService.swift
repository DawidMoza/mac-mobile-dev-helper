import Foundation

protocol AppUpdateNetworking: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionAppUpdateNetworking: AppUpdateNetworking {
    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("mac-mobile-dev-helper", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppUpdateError.network("GitHub returned HTTP \(http.statusCode).")
        }
        return data
    }
}

actor AppUpdateService {
    static let repositorySlug = "DawidMoza/mac-mobile-dev-helper"
    static let repositoryURL = URL(string: "https://github.com/DawidMoza/mac-mobile-dev-helper.git")!

    private let networking: any AppUpdateNetworking
    private let fileManager: FileManager
    private let processRunner: any ADBCommandRunning

    init(
        networking: any AppUpdateNetworking = URLSessionAppUpdateNetworking(),
        fileManager: FileManager = .default,
        processRunner: any ADBCommandRunning = ADBProcessRunner()
    ) {
        self.networking = networking
        self.fileManager = fileManager
        self.processRunner = processRunner
    }

    func currentVersion(
        bundle: Bundle = .main,
        fallback: String = "0.0.0"
    ) throws -> AppVersion {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return try AppVersion(raw?.isEmpty == false ? raw! : fallback)
    }

    func latestRelease() async throws -> AppReleaseInfo {
        let url = URL(
            string: "https://api.github.com/repos/\(Self.repositorySlug)/releases/latest"
        )!
        let data: Data
        do {
            data = try await networking.data(from: url)
        } catch let error as AppUpdateError {
            throw error
        } catch {
            throw AppUpdateError.network(error.localizedDescription)
        }
        return try Self.parseLatestRelease(data)
    }

    func checkForUpdate(
        bundle: Bundle = .main
    ) async throws -> AppUpdateAvailability {
        let current = try currentVersion(bundle: bundle)
        let latest = try await latestRelease()
        return AppUpdateAvailability(currentVersion: current, latestRelease: latest)
    }

    func applyUpdate(
        to tag: String,
        destinationAppURL: URL = Bundle.main.bundleURL,
        currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) async throws {
        try requireTools()
        let version = try AppVersion(tag)
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacMobileDevHelper-Update-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = workDirectory.appendingPathComponent("src", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        try await run(
            executable: "git",
            arguments: [
                "clone",
                "--depth", "1",
                "--branch", version.original,
                Self.repositoryURL.absoluteString,
                sourceDirectory.path
            ],
            timeout: 180
        )

        let buildScript = sourceDirectory.appendingPathComponent("scripts/build-app.sh")
        guard fileManager.isExecutableFile(atPath: buildScript.path)
            || fileManager.fileExists(atPath: buildScript.path) else {
            throw AppUpdateError.updateFailed("The release is missing scripts/build-app.sh.")
        }

        try await run(
            executable: "bash",
            arguments: [buildScript.path],
            timeout: 900,
            environment: [
                "VERSION": version.original,
                "BUNDLE_VERSION": "1"
            ],
            currentDirectory: sourceDirectory
        )

        let builtApp = sourceDirectory
            .appendingPathComponent("dist/Mac Mobile Dev Helper.app", isDirectory: true)
        guard fileManager.fileExists(atPath: builtApp.path) else {
            throw AppUpdateError.updateFailed("The update build did not produce an app bundle.")
        }

        let helper = workDirectory.appendingPathComponent("replace-and-relaunch.sh")
        let helperSource = """
        #!/bin/bash
        set -euo pipefail
        PID="$1"
        NEW_APP="$2"
        DEST_APP="$3"
        WORK_DIR="$4"
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.4
        rm -rf "$DEST_APP"
        /usr/bin/ditto "$NEW_APP" "$DEST_APP"
        /usr/bin/open "$DEST_APP"
        rm -rf "$WORK_DIR"
        """
        try helperSource.write(to: helper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            helper.path,
            String(currentProcessIdentifier),
            builtApp.path,
            destinationAppURL.path,
            workDirectory.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func parseLatestRelease(_ data: Data) throws -> AppReleaseInfo {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String,
            !tag.isEmpty
        else {
            throw AppUpdateError.latestReleaseUnavailable
        }

        let htmlURL = (object["html_url"] as? String).flatMap(URL.init(string:))
        let publishedAt: Date?
        if let published = object["published_at"] as? String {
            publishedAt = ISO8601DateFormatter().date(from: published)
        } else {
            publishedAt = nil
        }

        _ = try AppVersion(tag)
        return AppReleaseInfo(tag: tag, htmlURL: htmlURL, publishedAt: publishedAt)
    }

    private func requireTools() throws {
        for tool in ["git", "swift", "bash", "ditto"] {
            _ = try resolveExecutable(tool)
        }
    }

    private func resolveExecutable(_ name: String) throws -> URL {
        let candidates = [
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)"
        ]
        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: match)
        }
        throw AppUpdateError.missingTool(name)
    }

    private func enrichedEnvironment(
        extras: [String: String] = [:]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let pathParts = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ] + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        var seen = Set<String>()
        environment["PATH"] = pathParts.filter { seen.insert($0).inserted }.joined(separator: ":")
        for (key, value) in extras {
            environment[key] = value
        }
        return environment
    }

    private func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws {
        let executableURL: URL
        if executable.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: executable)
        } else {
            executableURL = try resolveExecutable(executable)
        }

        if environment == nil, currentDirectory == nil {
            let result = try await processRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                maximumOutputSize: 2 * 1_024 * 1_024
            )
            guard result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppUpdateError.updateFailed(stderr)
            }
            return
        }

        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacMobileDevHelper-UpdateCmd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outputDirectory) }

        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.environment = enrichedEnvironment(extras: environment ?? [:])

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
        }
        if process.isRunning {
            process.terminate()
            throw AppUpdateError.updateFailed("The update command timed out.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateError.updateFailed(message)
        }
    }
}
