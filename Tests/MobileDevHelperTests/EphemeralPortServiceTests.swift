import XCTest
@testable import MobileDevHelper

final class EphemeralPortServiceTests: XCTestCase {
    func testParseCountsUniqueOccupiedPortsAndTimeWaitSockets() {
        let output = """
        tcp4       0      0  127.0.0.1.49152       127.0.0.1.443         TIME_WAIT
        tcp4       0      0  127.0.0.1.49152       127.0.0.2.443         TIME_WAIT
        tcp4       0      0  192.168.1.2.49153     1.1.1.1.443           ESTABLISHED
        tcp6       0      0  ::1.49154             ::1.443               TIME_WAIT
        tcp4       0      0  127.0.0.1.8080        *.*                   LISTEN
        udp4       0      0  *.49155               *.*
        """

        let snapshot = EphemeralPortService.parse(
            netstatOutput: output,
            firstPort: 49_152,
            lastPort: 65_535
        )

        XCTAssertEqual(snapshot.occupiedPortCount, 3)
        XCTAssertEqual(snapshot.timeWaitSocketCount, 3)
        XCTAssertEqual(snapshot.capacity, 16_384)
        XCTAssertEqual(snapshot.pressure, .healthy)
    }

    func testCriticalPressureStartsAtEightyFivePercent() {
        let output = (100...108)
            .map { "tcp4 0 0 127.0.0.1.\($0) 1.1.1.1.443 TIME_WAIT" }
            .joined(separator: "\n")

        let snapshot = EphemeralPortService.parse(
            netstatOutput: output,
            firstPort: 100,
            lastPort: 109
        )

        XCTAssertEqual(snapshot.occupiedPortCount, 9)
        XCTAssertEqual(snapshot.availablePortCount, 1)
        XCTAssertEqual(snapshot.pressure, .critical)
        XCTAssertTrue(snapshot.isOverfilled)
    }

    func testTimeWaitPressureCanDetectCriticalUsageAcrossRepeatedPorts() {
        let output = (1...9)
            .map { "tcp4 0 0 127.0.0.1.100 1.1.1.\($0).443 TIME_WAIT" }
            .joined(separator: "\n")

        let snapshot = EphemeralPortService.parse(
            netstatOutput: output,
            firstPort: 100,
            lastPort: 109
        )

        XCTAssertEqual(snapshot.occupiedPortCount, 1)
        XCTAssertEqual(snapshot.timeWaitSocketCount, 9)
        XCTAssertEqual(snapshot.pressure, .critical)
    }

    func testZeroByteFormattingUsesNumericZero() async {
        let formatted = await MainActor.run {
            CleanupViewModel.format(0)
        }

        XCTAssertEqual(formatted, "0 B")
    }
}
