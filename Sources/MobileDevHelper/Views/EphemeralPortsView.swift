import Combine
import SwiftUI

@MainActor
final class EphemeralPortViewModel: ObservableObject {
    struct Message: Identifiable {
        let title: String
        let body: String

        var id: String { title + body }
    }

    @Published private(set) var snapshot: EphemeralPortSnapshot?
    @Published private(set) var isWorking = false
    @Published var isConfirmingRestart = false
    @Published var message: Message?

    private let portService: EphemeralPortService
    private let restartService: SystemRestartService

    init(
        portService: EphemeralPortService = EphemeralPortService(),
        restartService: SystemRestartService = SystemRestartService()
    ) {
        self.portService = portService
        self.restartService = restartService
    }

    func refresh() async {
        isWorking = true
        defer { isWorking = false }

        do {
            snapshot = try await portService.scan()
        } catch {
            message = Message(
                title: "Port scan failed",
                body: error.localizedDescription
            )
        }
    }

    func restartMac() async {
        guard snapshot?.isOverfilled == true else {
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            try await restartService.restart()
        } catch {
            message = Message(
                title: "Restart failed",
                body: error.localizedDescription
            )
        }
    }
}

struct EphemeralPortsView: View {
    @StateObject private var model = EphemeralPortViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = model.snapshot {
                statusHeader(snapshot)
                ProgressView(value: snapshot.pressureUtilization)
                    .tint(statusColor(snapshot.pressure))
                metrics(snapshot)

                if snapshot.isOverfilled {
                    Label(
                        "Ephemeral ports are critically full. New network connections may fail until TIME_WAIT sockets drain or the Mac restarts.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)

                    Button("Restart Mac…", role: .destructive) {
                        model.isConfirmingRestart = true
                    }
                    .disabled(model.isWorking)
                }
            } else if model.isWorking {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting TCP sockets…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Port usage has not been scanned.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Critical when occupied ports or TIME_WAIT pressure reaches 85% of the configured range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Ports") {
                    Task {
                        await model.refresh()
                    }
                }
                .disabled(model.isWorking)
            }
        }
        .task {
            if model.snapshot == nil {
                await model.refresh()
            }
        }
        .alert("Restart Mac?", isPresented: $model.isConfirmingRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) {
                Task {
                    await model.restartMac()
                }
            }
        } message: {
            Text("All applications will close and unsaved work may be lost. Restart only after saving your work.")
        }
        .alert(item: $model.message) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.body),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func statusHeader(_ snapshot: EphemeralPortSnapshot) -> some View {
        HStack {
            Label(statusTitle(snapshot.pressure), systemImage: statusIcon(snapshot.pressure))
                .font(.headline)
                .foregroundStyle(statusColor(snapshot.pressure))
            Spacer()
            Text(snapshot.pressureUtilization, format: .percent.precision(.fractionLength(1)))
                .font(.title3.bold().monospacedDigit())
        }
    }

    private func metrics(_ snapshot: EphemeralPortSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 7) {
            GridRow {
                metric("Occupied ports", value: snapshot.occupiedPortCount.formatted())
                metric("Available ports", value: snapshot.availablePortCount.formatted())
            }
            GridRow {
                metric("TIME_WAIT sockets", value: snapshot.timeWaitSocketCount.formatted())
                metric("Configured range", value: "\(snapshot.firstPort)–\(snapshot.lastPort)")
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    private func statusTitle(_ pressure: EphemeralPortSnapshot.Pressure) -> String {
        switch pressure {
        case .healthy:
            "Healthy"
        case .elevated:
            "Elevated usage"
        case .critical:
            "Critical usage"
        }
    }

    private func statusIcon(_ pressure: EphemeralPortSnapshot.Pressure) -> String {
        switch pressure {
        case .healthy:
            "checkmark.circle.fill"
        case .elevated:
            "exclamationmark.circle.fill"
        case .critical:
            "xmark.octagon.fill"
        }
    }

    private func statusColor(_ pressure: EphemeralPortSnapshot.Pressure) -> Color {
        switch pressure {
        case .healthy:
            .green
        case .elevated:
            .orange
        case .critical:
            .red
        }
    }
}
