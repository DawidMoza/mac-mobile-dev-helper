import Foundation

struct EphemeralPortSnapshot: Sendable {
    enum Pressure: Sendable {
        case healthy
        case elevated
        case critical
    }

    let firstPort: Int
    let lastPort: Int
    let occupiedPortCount: Int
    let timeWaitSocketCount: Int

    var capacity: Int {
        max(0, lastPort - firstPort + 1)
    }

    var availablePortCount: Int {
        max(0, capacity - occupiedPortCount)
    }

    var utilization: Double {
        guard capacity > 0 else {
            return 0
        }
        return Double(occupiedPortCount) / Double(capacity)
    }

    var pressureUtilization: Double {
        guard capacity > 0 else {
            return 0
        }
        let timeWaitUtilization = Double(timeWaitSocketCount) / Double(capacity)
        return min(1, max(utilization, timeWaitUtilization))
    }

    var pressure: Pressure {
        if pressureUtilization >= 0.85 {
            return .critical
        }
        if pressureUtilization >= 0.60 {
            return .elevated
        }
        return .healthy
    }

    var isOverfilled: Bool {
        pressure == .critical
    }
}

actor EphemeralPortService {
    private let defaultFirstPort = 49_152
    private let defaultLastPort = 65_535

    func scan() throws -> EphemeralPortSnapshot {
        let range = ephemeralPortRange()
        let netstatOutput = try run(
            executable: "/usr/sbin/netstat",
            arguments: ["-an", "-p", "tcp"]
        )
        return Self.parse(
            netstatOutput: netstatOutput,
            firstPort: range.first,
            lastPort: range.last
        )
    }

    static func parse(
        netstatOutput: String,
        firstPort: Int,
        lastPort: Int
    ) -> EphemeralPortSnapshot {
        var occupiedPorts = Set<Int>()
        var timeWaitSocketCount = 0

        for line in netstatOutput.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard
                columns.count >= 5,
                columns[0].hasPrefix("tcp"),
                let portText = columns[3].split(separator: ".").last,
                let port = Int(portText),
                (firstPort...lastPort).contains(port)
            else {
                continue
            }

            occupiedPorts.insert(port)
            if columns.last == "TIME_WAIT" {
                timeWaitSocketCount += 1
            }
        }

        return EphemeralPortSnapshot(
            firstPort: firstPort,
            lastPort: lastPort,
            occupiedPortCount: occupiedPorts.count,
            timeWaitSocketCount: timeWaitSocketCount
        )
    }

    private func ephemeralPortRange() -> (first: Int, last: Int) {
        guard
            let output = try? run(
                executable: "/usr/sbin/sysctl",
                arguments: [
                    "-n",
                    "net.inet.ip.portrange.first",
                    "net.inet.ip.portrange.last"
                ]
            )
        else {
            return (defaultFirstPort, defaultLastPort)
        }

        let values = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        guard values.count >= 2, values[0] <= values[1] else {
            return (defaultFirstPort, defaultLastPort)
        }
        return (values[0], values[1])
    }

    private func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EphemeralPortError.commandFailed(
                message.isEmpty ? "\(executable) exited with status \(process.terminationStatus)." : message
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}

actor SystemRestartService {
    func restart() throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to restart"
        ]
        process.standardError = errorPipe

        try process.run()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EphemeralPortError.commandFailed(
                message.isEmpty ? "The restart request failed." : message
            )
        }
    }
}

enum EphemeralPortError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message
        }
    }
}
