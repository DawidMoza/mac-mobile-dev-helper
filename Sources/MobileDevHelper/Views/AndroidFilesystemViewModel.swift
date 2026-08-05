import Combine
import Foundation

@MainActor
final class AndroidFilesystemViewModel: ObservableObject {
    struct Message: Identifiable {
        let title: String
        let body: String

        var id: String { title + body }
    }

    @Published private(set) var adbPath: String?
    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var currentDirectory: AndroidRemotePath?
    @Published private(set) var entries: [AndroidFileEntry] = []
    @Published var selectedSerial: String?
    @Published var selectedEntryID: String?
    @Published private(set) var isWorking = false
    @Published var message: Message?
    @Published var pendingDelete: AndroidFileEntry?
    @Published private(set) var editorDocument: AndroidEditableDocument?
    @Published var editorText = ""
    @Published var isConfirmingDiscard = false

    private let service: AdbService
    private var operationTask: Task<Void, Never>?
    private var devicePollingTask: Task<Void, Never>?
    private var hasStarted = false

    init(service: AdbService = AdbService()) {
        self.service = service
    }

    deinit {
        operationTask?.cancel()
        devicePollingTask?.cancel()
    }

    var selectedDevice: AndroidDevice? {
        devices.first { $0.serial == selectedSerial }
    }

    var selectedEntry: AndroidFileEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    var editorIsPresented: Bool {
        editorDocument != nil
    }

    var editorIsDirty: Bool {
        guard let editorDocument else {
            return false
        }
        return editorText != editorDocument.text
    }

    var breadcrumbs: [AndroidRemotePath] {
        guard let currentDirectory else {
            return []
        }
        var result: [AndroidRemotePath] = []
        guard let root = try? AndroidRemotePath(
            root: currentDirectory.root,
            value: currentDirectory.root
        ) else {
            return []
        }
        result.append(root)
        guard !currentDirectory.isRoot else {
            return result
        }

        let relative = currentDirectory.value.dropFirst(currentDirectory.root.count + 1)
        var path = root
        for component in relative.split(separator: "/") {
            guard let next = try? path.appending(name: String(component)) else {
                break
            }
            result.append(next)
            path = next
        }
        return result
    }

    var statusText: String {
        if adbPath == nil, !hasStarted {
            return "Looking for ADB…"
        }
        if adbPath == nil {
            return "ADB not found"
        }
        guard let selectedDevice else {
            return devices.isEmpty ? "No Android devices detected" : "Select a device"
        }
        switch selectedDevice.state {
        case .connected:
            return currentDirectory == nil ? "Connecting…" : selectedDevice.state.label
        case .unauthorized:
            return "Unlock the phone and allow USB debugging"
        default:
            return selectedDevice.state.label
        }
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        refreshDevices()
        startDevicePolling()
    }

    func refreshDevices() {
        beginOperation(title: "Device refresh failed") {
            let adbURL = try await self.service.locateADB()
            let devices = try await self.service.devices()
            self.adbPath = adbURL.path
            try await self.applyDeviceRefresh(devices)
        }
    }

    func selectDevice(serial: String?) {
        selectedSerial = serial
        currentDirectory = nil
        entries = []
        selectedEntryID = nil
        beginOperation(title: "Could not open device") {
            try await self.loadSelectedDevice()
        }
    }

    func refreshDirectory() {
        guard let currentDirectory else {
            refreshDevices()
            return
        }
        beginOperation(title: "Folder refresh failed") {
            try await self.loadDirectory(currentDirectory)
        }
    }

    func navigate(to path: AndroidRemotePath) {
        beginOperation(title: "Could not open folder") {
            try await self.loadDirectory(path)
        }
    }

    func openSelected() {
        guard let selectedEntry else {
            return
        }
        if selectedEntry.kind.isDirectory {
            navigate(to: selectedEntry.path)
        } else if selectedEntry.kind.isEditable {
            openEditor(for: selectedEntry)
        }
    }

    func openEditor(for entry: AndroidFileEntry) {
        guard entry.kind.isEditable, let serial = selectedSerial else {
            return
        }
        beginOperation(title: "Could not open file") {
            let document = try await self.service.openTextDocument(
                serial: serial,
                path: entry.path
            )
            self.editorDocument = document
            self.editorText = document.text
        }
    }

    func saveEditor() {
        guard var document = editorDocument, let serial = selectedSerial else {
            return
        }
        document.text = editorText
        beginOperation(title: "Could not save file") {
            try await self.service.saveTextDocument(serial: serial, document: document)
            self.editorDocument = nil
            self.editorText = ""
            try await self.reloadCurrentDirectory()
        }
    }

    func requestCloseEditor() {
        if editorIsDirty {
            isConfirmingDiscard = true
        } else {
            closeEditor()
        }
    }

    func discardEditorChanges() {
        isConfirmingDiscard = false
        closeEditor()
    }

    func createDirectory(named name: String) {
        guard let serial = selectedSerial, let currentDirectory else {
            return
        }
        beginOperation(title: "Could not create folder") {
            try await self.service.createDirectory(
                serial: serial,
                parent: currentDirectory,
                name: name
            )
            try await self.loadDirectory(currentDirectory)
        }
    }

    func renameSelected(to newName: String) {
        guard let serial = selectedSerial, let selectedEntry else {
            return
        }
        beginOperation(title: "Could not rename item") {
            try await self.service.rename(
                serial: serial,
                path: selectedEntry.path,
                newName: newName
            )
            try await self.reloadCurrentDirectory()
        }
    }

    func requestDeleteSelected() {
        pendingDelete = selectedEntry
    }

    func confirmDelete() {
        guard let serial = selectedSerial, let entry = pendingDelete else {
            return
        }
        pendingDelete = nil
        beginOperation(title: "Could not delete item") {
            try await self.service.delete(
                serial: serial,
                path: entry.path,
                isDirectory: entry.kind.isDirectory
            )
            try await self.reloadCurrentDirectory()
        }
    }

    func upload(localURL: URL) {
        guard let serial = selectedSerial, let currentDirectory else {
            return
        }
        beginOperation(title: "Upload failed") {
            try await self.service.upload(
                serial: serial,
                localURL: localURL,
                to: currentDirectory
            )
            try await self.loadDirectory(currentDirectory)
        }
    }

    func downloadSelected(to destinationURL: URL) {
        guard let serial = selectedSerial, let selectedEntry else {
            return
        }
        beginOperation(title: "Download failed") {
            try await self.service.download(
                serial: serial,
                path: selectedEntry.path,
                to: destinationURL
            )
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    private func loadSelectedDevice() async throws {
        guard let serial = selectedSerial else {
            currentDirectory = nil
            entries = []
            return
        }
        guard let device = devices.first(where: { $0.serial == serial }) else {
            currentDirectory = nil
            entries = []
            return
        }
        guard device.state == .connected else {
            currentDirectory = nil
            entries = []
            return
        }
        let root = try await service.sharedStorageRoot(serial: serial)
        try await loadDirectory(root)
    }

    private func startDevicePolling() {
        devicePollingTask?.cancel()
        devicePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !self.isWorking else {
                    continue
                }
                await self.pollDevices()
            }
        }
    }

    private func pollDevices() async {
        guard !isWorking else {
            return
        }
        do {
            let adbURL = try await service.locateADB()
            let refreshedDevices = try await service.devices()
            guard !isWorking else {
                return
            }
            adbPath = adbURL.path
            try await applyDeviceRefresh(refreshedDevices)
        } catch is CancellationError {
            return
        } catch AndroidFilesystemError.adbNotFound {
            adbPath = nil
            devices = []
            currentDirectory = nil
            entries = []
            selectedSerial = nil
            selectedEntryID = nil
        } catch {
            // Polling is best-effort. Manual refresh reports actionable failures.
        }
    }

    private func applyDeviceRefresh(_ refreshedDevices: [AndroidDevice]) async throws {
        let previousSerial = selectedSerial
        let previousState = selectedDevice?.state
        devices = refreshedDevices

        if let previousSerial,
           refreshedDevices.contains(where: { $0.serial == previousSerial }) {
            selectedSerial = previousSerial
        } else {
            selectedSerial = refreshedDevices
                .first(where: { $0.state == .connected })?.serial
                ?? refreshedDevices.first?.serial
        }

        guard let selectedDevice else {
            currentDirectory = nil
            entries = []
            selectedEntryID = nil
            return
        }
        guard selectedDevice.state == .connected else {
            currentDirectory = nil
            entries = []
            selectedEntryID = nil
            return
        }

        let selectionChanged = selectedSerial != previousSerial
        let becameConnected = previousState != .connected
        if currentDirectory == nil || selectionChanged || becameConnected {
            try await loadSelectedDevice()
        }
    }

    private func loadDirectory(_ path: AndroidRemotePath) async throws {
        guard let serial = selectedSerial else {
            return
        }
        let snapshot = try await service.listDirectory(serial: serial, path: path)
        currentDirectory = snapshot.path
        entries = snapshot.entries
        selectedEntryID = nil
    }

    private func reloadCurrentDirectory() async throws {
        guard let currentDirectory else {
            return
        }
        try await loadDirectory(currentDirectory)
    }

    private func closeEditor() {
        editorDocument = nil
        editorText = ""
    }

    private func beginOperation(
        title: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        operationTask?.cancel()
        isWorking = true
        operationTask = Task {
            defer {
                self.isWorking = false
                self.operationTask = nil
            }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                if case AndroidFilesystemError.adbNotFound = error {
                    self.adbPath = nil
                    self.devices = []
                    self.currentDirectory = nil
                    self.entries = []
                }
                self.message = Message(
                    title: title,
                    body: error.localizedDescription
                )
            }
        }
    }
}
