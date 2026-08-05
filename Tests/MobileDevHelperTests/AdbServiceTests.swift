import Foundation
import XCTest
@testable import MobileDevHelper

final class AdbServiceTests: XCTestCase {
    func testParseDevicesPreservesStatesAndMetadata() {
        let output = """
        List of devices attached
        emulator-5554 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:1
        R3CN unauthorized usb:1-2 transport_id:2
        old-phone offline transport_id:3
        """

        let devices = AdbService.parseDevices(output)

        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].serial, "emulator-5554")
        XCTAssertEqual(devices[0].state, .connected)
        XCTAssertEqual(devices[0].model, "sdk_gphone64_arm64")
        XCTAssertEqual(devices[0].transportID, "1")
        XCTAssertEqual(devices[1].state, .unauthorized)
        XCTAssertEqual(devices[2].state, .offline)
    }

    func testDirectoryParserSupportsWhitespaceQuotesAndNewlines() throws {
        var listing = Data()
        appendField("/storage/emulated/0/My file.txt", to: &listing)
        appendField("f", to: &listing)
        appendField("42", to: &listing)
        appendField("1722852000.5", to: &listing)
        appendField("/storage/emulated/0/line\nbreak's folder", to: &listing)
        appendField("d", to: &listing)
        appendField("0", to: &listing)
        appendField("1722852001", to: &listing)

        let entries = try AdbService.parseDirectoryListing(
            listing,
            root: "/storage/emulated/0"
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "My file.txt")
        XCTAssertEqual(entries[0].kind, .file)
        XCTAssertEqual(entries[0].size, 42)
        XCTAssertEqual(entries[1].name, "line\nbreak's folder")
        XCTAssertEqual(entries[1].kind, .directory)
    }

    func testDirectoryParserRejectsMalformedFields() {
        var listing = Data()
        appendField("/storage/emulated/0/file", to: &listing)
        appendField("f", to: &listing)

        XCTAssertThrowsError(
            try AdbService.parseDirectoryListing(
                listing,
                root: "/storage/emulated/0"
            )
        ) { error in
            XCTAssertEqual(error as? AndroidFilesystemError, .invalidDirectoryListing)
        }
    }

    func testRemotePathsRejectEscapesAndInvalidNames() throws {
        let root = "/storage/emulated/0"
        let safe = try AndroidRemotePath(root: root, value: root + "/Download/file.txt")
        XCTAssertEqual(safe.name, "file.txt")
        XCTAssertEqual(safe.parent?.value, root + "/Download")

        XCTAssertThrowsError(
            try AndroidRemotePath(root: root, value: "/data/local/tmp/file")
        )
        XCTAssertThrowsError(
            try AndroidRemotePath(root: root, value: root + "/../private")
        )
        XCTAssertThrowsError(try safe.appending(name: "../bad"))
        XCTAssertThrowsError(try safe.appending(name: "folder/file"))
        XCTAssertThrowsError(try AndroidRemotePath(root: "/", value: "/"))
    }

    func testRemoteShellQuotesInjectionCharactersAsOneParameter() {
        let arguments = ADBRemoteShell.arguments(
            script: "printf '%s' \"$1\"",
            parameters: ["a'$(touch /tmp/pwned); newline\nname"]
        )

        XCTAssertEqual(arguments.prefix(2), ["shell", "-T"])
        XCTAssertTrue(arguments[2].contains("'a'\\''$(touch /tmp/pwned); newline\nname'"))
        XCTAssertTrue(arguments[2].contains("'printf '"))
        XCTAssertTrue(arguments[2].contains("'mac-mobile-dev-helper'"))
    }

    func testTextCodecPreservesSupportedByteOrderMarks() throws {
        let samples: [(AndroidTextEncoding, String)] = [
            (.utf8, "plain text"),
            (.utf8BOM, "zażółć"),
            (.utf16LittleEndian, "little endian"),
            (.utf16BigEndian, "big endian")
        ]

        for (encoding, text) in samples {
            let encoded = try AdbService.encodeText(text, encoding: encoding)
            let decoded = try AdbService.decodeText(encoded)
            XCTAssertEqual(decoded.text, text)
            XCTAssertEqual(decoded.encoding, encoding)
            XCTAssertEqual(
                try AdbService.encodeText(decoded.text, encoding: decoded.encoding),
                encoded
            )
        }
    }

    func testTextCodecRejectsBinaryAndLargeFiles() {
        XCTAssertThrowsError(try AdbService.decodeText(Data([0x41, 0x00, 0x42]))) {
            error in
            XCTAssertEqual(
                error as? AndroidFilesystemError,
                .unsupportedTextEncoding
            )
        }

        let oversized = Data(
            repeating: 0x41,
            count: Int(AdbService.maximumEditableFileSize + 1)
        )
        XCTAssertThrowsError(try AdbService.decodeText(oversized))
    }

    func testLocatorOrdersPathAndStandardSDKLocations() {
        let locator = ADBLocator(
            environment: [
                "PATH": "/custom/bin:/second/bin",
                "ANDROID_HOME": "/android/home",
                "ANDROID_SDK_ROOT": "/android/root"
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(
            locator.candidates().map(\.path),
            [
                "/custom/bin/adb",
                "/second/bin/adb",
                "/opt/homebrew/bin/adb",
                "/usr/local/bin/adb",
                "/android/home/platform-tools/adb",
                "/android/root/platform-tools/adb",
                "/Users/example/Library/Android/sdk/platform-tools/adb"
            ]
        )
    }

    func testServiceUsesSelectedSerialForDeviceCommands() async throws {
        let environment = try FakeADBEnvironment(
            responses: [
                .success("Android Debug Bridge version 1.0.41"),
                .success(
                    """
                    List of devices attached
                    serial-123 device model:Pixel_9 transport_id:4
                    """
                ),
                .success(
                    """
                    List of devices attached
                    serial-123 device model:Pixel_9 transport_id:4
                    """
                ),
                .successData(Data("/storage/emulated/0\0".utf8))
            ]
        )
        defer { environment.remove() }

        let service = AdbService(runner: environment.runner, locator: environment.locator)
        let devices = try await service.devices()
        let root = try await service.sharedStorageRoot(serial: "serial-123")

        XCTAssertEqual(devices.first?.displayName, "Pixel 9")
        XCTAssertEqual(root.value, "/storage/emulated/0")

        let invocations = await environment.runner.invocations
        XCTAssertEqual(invocations[1].arguments, ["devices", "-l"])
        XCTAssertEqual(invocations[2].arguments, ["devices", "-l"])
        XCTAssertEqual(invocations[3].arguments.prefix(2), ["-s", "serial-123"])
        XCTAssertEqual(invocations[3].arguments[2], "shell")
    }

    func testServiceRejectsUnauthorizedDeviceBeforeBrowsing() async throws {
        let environment = try FakeADBEnvironment(
            responses: [
                .success("Android Debug Bridge version 1.0.41"),
                .success(
                    """
                    List of devices attached
                    serial-123 unauthorized transport_id:4
                    """
                )
            ]
        )
        defer { environment.remove() }

        let service = AdbService(runner: environment.runner, locator: environment.locator)
        do {
            _ = try await service.sharedStorageRoot(serial: "serial-123")
            XCTFail("Expected an unauthorized-device error.")
        } catch {
            XCTAssertEqual(
                error as? AndroidFilesystemError,
                .deviceUnavailable("Unauthorized")
            )
        }
    }

    func testDirectoryListingFallsBackWhenFindPrintfIsUnavailable() async throws {
        var batchedListing = Data()
        appendField("/storage/emulated/0/Download/My file.txt", to: &batchedListing)
        appendField("f", to: &batchedListing)
        appendField("42", to: &batchedListing)
        appendField("1722852000", to: &batchedListing)
        let environment = try FakeADBEnvironment(
            responses: [
                .success("Android Debug Bridge version 1.0.41"),
                .success(
                    """
                    List of devices attached
                    serial-123 device model:Pixel_9 transport_id:4
                    """
                ),
                .successData(Data("/storage/emulated/0/Download\0".utf8)),
                .failure("find: bad -printf"),
                .successData(batchedListing)
            ]
        )
        defer { environment.remove() }

        let service = AdbService(runner: environment.runner, locator: environment.locator)
        let path = try AndroidRemotePath(
            root: "/storage/emulated/0",
            value: "/storage/emulated/0/Download"
        )
        let snapshot = try await service.listDirectory(
            serial: "serial-123",
            path: path
        )

        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries[0].name, "My file.txt")
        XCTAssertEqual(snapshot.entries[0].size, 42)
    }

    func testSaveDetectsRemoteConflictBeforeUploading() async throws {
        let environment = try FakeADBEnvironment(
            responses: [
                .success("Android Debug Bridge version 1.0.41"),
                .successData(Data("/storage/emulated/0/note.txt\0".utf8)),
                .success("5\n"),
                .success("hello"),
                .successData(Data("/storage/emulated/0/note.txt\0".utf8)),
                .success("7\n"),
                .success("changed")
            ]
        )
        defer { environment.remove() }

        let service = AdbService(runner: environment.runner, locator: environment.locator)
        let path = try AndroidRemotePath(
            root: "/storage/emulated/0",
            value: "/storage/emulated/0/note.txt"
        )
        var document = try await service.openTextDocument(
            serial: "serial-123",
            path: path
        )
        document.text = "local edit"

        do {
            try await service.saveTextDocument(serial: "serial-123", document: document)
            XCTFail("Expected a remote-change conflict.")
        } catch {
            XCTAssertEqual(error as? AndroidFilesystemError, .fileChanged)
        }

        let invocations = await environment.runner.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.contains("push") })
    }

    func testProcessRunnerTimesOutAndCancels() async throws {
        let runner = ADBProcessRunner()
        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.1,
                maximumOutputSize: 1_024
            )
            XCTFail("Expected timeout.")
        } catch {
            XCTAssertEqual(error as? AndroidFilesystemError, .commandTimedOut)
        }

        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 5,
                maximumOutputSize: 1_024
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private struct FakeInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
}

private actor FakeADBRunner: ADBCommandRunning {
    private var responses: [ADBCommandResult]
    private(set) var invocations: [FakeInvocation] = []

    init(responses: [ADBCommandResult]) {
        self.responses = responses
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputSize: Int
    ) async throws -> ADBCommandResult {
        invocations.append(
            FakeInvocation(executableURL: executableURL, arguments: arguments)
        )
        guard !responses.isEmpty else {
            throw AndroidFilesystemError.commandFailed("Unexpected fake ADB invocation.")
        }
        return responses.removeFirst()
    }
}

private final class FakeADBEnvironment {
    let root: URL
    let runner: FakeADBRunner
    let locator: ADBLocator

    init(responses: [ADBCommandResult]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeADB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let adbURL = root.appendingPathComponent("adb")
        try Data("#!/bin/sh\n".utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )

        runner = FakeADBRunner(responses: responses)
        locator = ADBLocator(environment: ["PATH": root.path], homeDirectory: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension ADBCommandResult {
    static func success(_ output: String) -> ADBCommandResult {
        successData(Data(output.utf8))
    }

    static func successData(_ output: Data) -> ADBCommandResult {
        ADBCommandResult(stdout: output, stderr: Data(), exitCode: 0)
    }

    static func failure(_ error: String) -> ADBCommandResult {
        ADBCommandResult(stdout: Data(), stderr: Data(error.utf8), exitCode: 1)
    }
}

private func appendField(_ value: String, to data: inout Data) {
    data.append(Data(value.utf8))
    data.append(0)
}
