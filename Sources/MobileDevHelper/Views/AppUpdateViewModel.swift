import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateViewModel: ObservableObject {
    struct Message: Identifiable {
        let title: String
        let body: String

        var id: String { title + body }
    }

    @Published private(set) var currentVersionText = "…"
    @Published private(set) var availableUpdate: AppUpdateAvailability?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusText: String?
    @Published var isConfirmingUpdate = false
    @Published var message: Message?

    private let service: AppUpdateService

    init(service: AppUpdateService = AppUpdateService()) {
        self.service = service
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            currentVersionText = version.hasPrefix("v") ? version : "v\(version)"
        } else {
            currentVersionText = "v0.0.0"
        }
    }

    var updateButtonTitle: String {
        guard let availableUpdate,
              let latest = try? availableUpdate.latestVersion else {
            return "Update"
        }
        return "Update to \(latest.description)"
    }

    func checkForUpdates(showUpToDateMessage: Bool = false) async {
        guard !isChecking, !isUpdating else {
            return
        }
        isChecking = true
        statusText = nil
        defer { isChecking = false }

        do {
            let availability = try await service.checkForUpdate()
            currentVersionText = availability.currentVersion.description
            if availability.isUpdateAvailable {
                availableUpdate = availability
                statusText = "Version \(availability.latestRelease.tag) is available."
            } else {
                availableUpdate = nil
                statusText = nil
                if showUpToDateMessage {
                    message = Message(
                        title: "You're up to date",
                        body: "Mac Mobile Dev Helper \(availability.currentVersion.description) is the latest release."
                    )
                }
            }
        } catch {
            availableUpdate = nil
            if showUpToDateMessage {
                message = Message(
                    title: "Update check failed",
                    body: error.localizedDescription
                )
            }
        }
    }

    func requestUpdate() {
        guard availableUpdate != nil else {
            return
        }
        isConfirmingUpdate = true
    }

    func confirmUpdate() {
        guard let availableUpdate else {
            return
        }
        isConfirmingUpdate = false
        isUpdating = true
        statusText = "Building \(availableUpdate.latestRelease.tag) from source. This can take a few minutes…"

        Task {
            do {
                try await service.applyUpdate(to: availableUpdate.latestRelease.tag)
                statusText = "Installing update and relaunching…"
                NSApplication.shared.terminate(nil)
            } catch {
                isUpdating = false
                statusText = nil
                message = Message(
                    title: "Update failed",
                    body: error.localizedDescription
                )
            }
        }
    }
}
