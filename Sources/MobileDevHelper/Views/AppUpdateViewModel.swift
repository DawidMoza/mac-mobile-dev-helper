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

    static let lastCheckDefaultsKey = "appUpdate.lastCheckAt"
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var currentVersionText = "…"
    @Published private(set) var availableUpdate: AppUpdateAvailability?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusText: String?
    @Published var isConfirmingUpdate = false
    @Published var message: Message?

    private let service: AppUpdateService
    private let defaults: UserDefaults
    private let versionBundle: Bundle
    private var dailyCheckTask: Task<Void, Never>?

    init(
        service: AppUpdateService = AppUpdateService(),
        defaults: UserDefaults = .standard,
        versionBundle: Bundle = .main
    ) {
        self.service = service
        self.defaults = defaults
        self.versionBundle = versionBundle
        if let version = versionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            currentVersionText = version.hasPrefix("v") ? version : "v\(version)"
        } else {
            currentVersionText = "v0.0.0"
        }
    }

    deinit {
        dailyCheckTask?.cancel()
    }

    var updateButtonTitle: String {
        guard let availableUpdate,
              let latest = try? availableUpdate.latestVersion else {
            return "Update"
        }
        return "Update \(availableUpdate.currentVersion.description) -> \(latest.description)"
    }

    func startAutomaticUpdateChecks() {
        dailyCheckTask?.cancel()
        dailyCheckTask = Task { [weak self] in
            await self?.checkForUpdatesIfNeeded()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.automaticCheckInterval))
                } catch {
                    return
                }
                await self?.checkForUpdatesIfNeeded()
            }
        }
    }

    func checkForUpdatesIfNeeded() async {
        guard shouldAutomaticallyCheck else {
            return
        }
        await checkForUpdates(force: false, showUpToDateMessage: false)
    }

    func checkForUpdates(
        force: Bool = true,
        showUpToDateMessage: Bool = false
    ) async {
        guard !isChecking, !isUpdating else {
            return
        }
        if !force, !shouldAutomaticallyCheck {
            return
        }

        isChecking = true
        statusText = nil
        defer { isChecking = false }

        do {
            let availability = try await service.checkForUpdate(bundle: versionBundle)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckDefaultsKey)
            currentVersionText = availability.currentVersion.description
            if availability.isUpdateAvailable {
                availableUpdate = availability
            } else {
                availableUpdate = nil
                if showUpToDateMessage {
                    message = Message(
                        title: "You're up to date",
                        body: "Mac Mobile Dev Helper \(availability.currentVersion.description) is the latest release."
                    )
                }
            }
        } catch {
            if showUpToDateMessage {
                availableUpdate = nil
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

    private var shouldAutomaticallyCheck: Bool {
        let lastCheck = defaults.double(forKey: Self.lastCheckDefaultsKey)
        guard lastCheck > 0 else {
            return true
        }
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        return elapsed >= Self.automaticCheckInterval
    }
}
