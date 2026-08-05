import AppKit
import SwiftUI

struct AndroidFilesystemView: View {
    @StateObject private var model = AndroidFilesystemViewModel()
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isRenaming = false
    @State private var renameName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceBar

            if model.currentDirectory != nil {
                breadcrumbBar
                browserToolbar
                fileList
            } else {
                connectionGuidance
            }
        }
        .frame(minHeight: 410)
        .task {
            model.start()
        }
        .sheet(
            isPresented: Binding(
                get: { model.editorIsPresented },
                set: { isPresented in
                    if !isPresented {
                        model.requestCloseEditor()
                    }
                }
            )
        ) {
            if let document = model.editorDocument {
                AndroidTextEditorSheet(model: model, document: document)
            }
        }
        .alert("Discard unsaved changes?", isPresented: $model.isConfirmingDiscard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive) {
                model.discardEditorChanges()
            }
        } message: {
            Text("The changes in the editor have not been saved to the phone.")
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                model.createDirectory(named: newFolderName)
                newFolderName = ""
            }
        } message: {
            Text("Create a folder in \(model.currentDirectory?.value ?? "shared storage").")
        }
        .alert("Rename Item", isPresented: $isRenaming) {
            TextField("New name", text: $renameName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                model.renameSelected(to: renameName)
                renameName = ""
            }
        } message: {
            Text("Enter a new name without slash characters.")
        }
        .alert(
            "Delete permanently?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        model.pendingDelete = nil
                    }
                }
            ),
            presenting: model.pendingDelete
        ) { _ in
            Button("Cancel", role: .cancel) {
                model.pendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                model.confirmDelete()
            }
        } message: { entry in
            Text(
                "\(entry.path.value) will be deleted immediately from the phone. This cannot be undone."
            )
        }
        .alert(item: $model.message) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.body),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var deviceBar: some View {
        HStack(spacing: 10) {
            Picker(
                "Device",
                selection: Binding(
                    get: { model.selectedSerial ?? "" },
                    set: { model.selectDevice(serial: $0.isEmpty ? nil : $0) }
                )
            ) {
                if model.devices.isEmpty {
                    Text("No devices").tag("")
                }
                ForEach(model.devices) { device in
                    Text("\(device.displayName) — \(device.state.label)")
                        .tag(device.serial)
                }
            }
            .frame(maxWidth: 360)
            .disabled(model.devices.isEmpty || model.isWorking)

            Label(model.statusText, systemImage: statusIcon)
                .font(.callout)
                .foregroundStyle(statusColor)
                .lineLimit(1)

            Spacer()

            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") {
                    model.cancelOperation()
                }
            }

            Button {
                model.refreshDevices()
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
            .disabled(model.isWorking)
        }
    }

    private var breadcrumbBar: some View {
        let breadcrumbs = model.breadcrumbs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(breadcrumbs, id: \.value) { path in
                    if !path.isRoot {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(path.name) {
                        model.navigate(to: path)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        path == model.currentDirectory ? Color.primary : Color.blue
                    )
                    .disabled(path == model.currentDirectory || model.isWorking)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.openSelected()
            } label: {
                Label("Open", systemImage: "arrow.forward.circle")
            }
            .disabled(model.selectedEntry == nil || !canOpenSelected || model.isWorking)

            Button {
                newFolderName = ""
                isCreatingFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(model.isWorking)

            Button {
                chooseUpload()
            } label: {
                Label("Upload", systemImage: "arrow.up.doc")
            }
            .disabled(model.isWorking)

            Button {
                chooseDownloadDestination()
            } label: {
                Label("Download", systemImage: "arrow.down.doc")
            }
            .disabled(model.selectedEntry == nil || model.isWorking)

            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(model.selectedEntry == nil || model.isWorking)

            Button(role: .destructive) {
                model.requestDeleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selectedEntry == nil || model.isWorking)

            Spacer()

            Button {
                model.refreshDirectory()
            } label: {
                Label("Refresh Folder", systemImage: "arrow.clockwise")
            }
            .disabled(model.isWorking)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Size")
                    .frame(width: 90, alignment: .trailing)
                Text("Modified")
                    .frame(width: 155, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Folder is empty")
                        .font(.headline)
                    Text("Upload a file or create a folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedEntryID) {
                    ForEach(model.entries) { entry in
                        fileRow(entry)
                            .tag(entry.id)
                            .contextMenu {
                                entryContextMenu(entry)
                            }
                            .onTapGesture(count: 2) {
                                model.selectedEntryID = entry.id
                                if entry.kind.isDirectory {
                                    model.navigate(to: entry.path)
                                } else if entry.kind.isEditable {
                                    model.openEditor(for: entry)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private func fileRow(_ entry: AndroidFileEntry) -> some View {
        HStack {
            Label(entry.name, systemImage: icon(for: entry))
                .lineLimit(1)
                .help(entry.path.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.kind.isDirectory ? "—" : CleanupViewModel.format(entry.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text(
                entry.modifiedAt?.formatted(
                    date: .abbreviated,
                    time: .shortened
                ) ?? "—"
            )
            .foregroundStyle(.secondary)
            .frame(width: 155, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func entryContextMenu(_ entry: AndroidFileEntry) -> some View {
        if entry.kind.isDirectory || entry.kind.isEditable {
            Button("Open") {
                model.selectedEntryID = entry.id
                if entry.kind.isDirectory {
                    model.navigate(to: entry.path)
                } else {
                    model.openEditor(for: entry)
                }
            }
        }
        Button("Download…") {
            model.selectedEntryID = entry.id
            chooseDownloadDestination()
        }
        Divider()
        Button("Rename…") {
            model.selectedEntryID = entry.id
            beginRename()
        }
        Button("Delete…", role: .destructive) {
            model.selectedEntryID = entry.id
            model.requestDeleteSelected()
        }
    }

    private var connectionGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.statusText, systemImage: statusIcon)
                .font(.headline)
                .foregroundStyle(statusColor)

            if model.adbPath == nil {
                Text("Install Android SDK Platform-Tools so the app can find the `adb` executable.")
            } else if model.devices.isEmpty {
                Text("Connect an Android phone by USB, enable USB debugging, then refresh devices.")
            } else if model.selectedDevice?.state == .unauthorized {
                Text("Unlock the phone and accept the “Allow USB debugging?” prompt, then refresh.")
            } else {
                Text("The selected device must be online in normal Android mode.")
            }

            Text("Only shared storage is exposed. App-private data and root access are not attempted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let adbPath = model.adbPath {
                Text(adbPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canOpenSelected: Bool {
        guard let entry = model.selectedEntry else {
            return false
        }
        return entry.kind.isDirectory || entry.kind.isEditable
    }

    private var statusIcon: String {
        if model.isWorking {
            return "ellipsis.circle"
        }
        guard model.adbPath != nil else {
            return "exclamationmark.triangle"
        }
        switch model.selectedDevice?.state {
        case .connected:
            return "checkmark.circle.fill"
        case .unauthorized:
            return "lock.trianglebadge.exclamationmark"
        case .none:
            return "cable.connector"
        default:
            return "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        if model.isWorking {
            return .secondary
        }
        switch model.selectedDevice?.state {
        case .connected:
            return .green
        case .unauthorized:
            return .orange
        default:
            return model.adbPath == nil ? .red : .secondary
        }
    }

    private func icon(for entry: AndroidFileEntry) -> String {
        switch entry.kind {
        case .directory:
            "folder.fill"
        case .file:
            "doc"
        case .symbolicLink:
            "link"
        case .other:
            "questionmark.square.dashed"
        }
    }

    private func beginRename() {
        guard let entry = model.selectedEntry else {
            return
        }
        renameName = entry.name
        isRenaming = true
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = "Upload to Android"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.upload(localURL: url)
        }
    }

    private func chooseDownloadDestination() {
        guard let entry = model.selectedEntry else {
            return
        }
        let panel = NSSavePanel()
        panel.title = "Download from Android"
        panel.prompt = "Download"
        panel.nameFieldStringValue = entry.name
        if panel.runModal() == .OK, let url = panel.url {
            model.downloadSelected(to: url)
        }
    }
}

private struct AndroidTextEditorSheet: View {
    @ObservedObject var model: AndroidFilesystemViewModel
    let document: AndroidEditableDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.path.name)
                        .font(.title2.bold())
                    Text(document.path.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(document.encoding.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $model.editorText)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }

            HStack {
                Text(
                    "\(model.editorText.utf8.count.formatted()) bytes as UTF-8 · 1 MB editor limit"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") {
                    model.requestCloseEditor()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isWorking)

                Button("Save") {
                    model.saveEditor()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.editorIsDirty || model.isWorking)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
        .interactiveDismissDisabled(model.editorIsDirty || model.isWorking)
    }
}
