import AppKit
import Combine
import Foundation

@MainActor
final class CleanupViewModel: ObservableObject {
    struct Message: Identifiable {
        let title: String
        let body: String

        var id: String { title + body }
    }

    @Published private(set) var snapshot = CleanupSnapshot.empty
    @Published var selectedCategoryIDs = Set(
        CleanupCategoryID.allCases.filter(\.isSelectedByDefault)
    )
    @Published private(set) var isWorking = false
    @Published private(set) var isXcodeRunning = false
    @Published var message: Message?

    private let service: CleanupService

    init(service: CleanupService = CleanupService()) {
        self.service = service
    }

    var selectedItems: [CleanupItem] {
        snapshot.categories
            .filter { selectedCategoryIDs.contains($0.id) }
            .flatMap(\.items)
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.allocatedSize }
    }

    var canClean: Bool {
        !selectedItems.isEmpty && !isWorking
    }

    func refresh() async {
        isWorking = true
        snapshot = await service.scan()
        isXcodeRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .isEmpty
        isWorking = false
    }

    func setSelected(_ isSelected: Bool, categoryID: CleanupCategoryID) {
        if isSelected {
            selectedCategoryIDs.insert(categoryID)
        } else {
            selectedCategoryIDs.remove(categoryID)
        }
    }

    func cleanSelected() async {
        let items = selectedItems
        guard !items.isEmpty else {
            return
        }

        isWorking = true
        let result = await service.clean(items: items)
        snapshot = await service.scan()
        isWorking = false

        var details = "Removed \(result.removedCount) item(s) and reclaimed approximately \(Self.format(result.reclaimedSize))."
        if !result.failures.isEmpty {
            let failures = result.failures
                .map { "\($0.path): \($0.message)" }
                .joined(separator: "\n")
            details += "\n\n\(result.failures.count) item(s) could not be removed:\n\(failures)"
        }
        message = Message(
            title: result.failures.isEmpty ? "Cleanup complete" : "Cleanup finished with errors",
            body: details
        )
    }

    static func format(_ byteCount: Int64) -> String {
        guard byteCount > 0 else {
            return "0 B"
        }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
