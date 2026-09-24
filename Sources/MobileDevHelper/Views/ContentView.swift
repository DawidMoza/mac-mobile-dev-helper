import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = CleanupViewModel()
    @StateObject private var updateModel = AppUpdateViewModel()
    @State private var isConfirmingCleanup = false
    @State private var isConfirmingCursorCompact = false
    @State private var isAndroidFilesystemExpanded = true
    @State private var isCleanupExpanded = true
    @State private var isPortsExpanded = true

    private static let headerIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        // Swift Package runs do not have the installed app's resource bundle.
        let sourceIcon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcon.png")
        return NSImage(contentsOf: sourceIcon) ?? NSApplication.shared.applicationIconImage
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                androidFilesystemFeature
                cleanupFeature
                portsFeature
            }
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 720)
        .task {
            updateModel.startAutomaticUpdateChecks()
            await model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkForAppUpdates)) { _ in
            Task {
                await updateModel.checkForUpdates(force: true, showUpToDateMessage: true)
            }
        }
        .sheet(isPresented: $isConfirmingCursorCompact) {
            if let database = model.snapshot.cursorDatabase {
                CursorCompactConfirmationView(
                    database: database,
                    onCancel: { isConfirmingCursorCompact = false },
                    onConfirm: {
                        isConfirmingCursorCompact = false
                        Task {
                            await model.compactCursorDatabase()
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isConfirmingCleanup) {
            CleanupConfirmationView(
                items: model.selectedItems,
                totalSize: model.selectedSize,
                isXcodeRunning: model.isXcodeRunning,
                onCancel: { isConfirmingCleanup = false },
                onConfirm: {
                    isConfirmingCleanup = false
                    Task {
                        await model.cleanSelected()
                    }
                }
            )
        }
        .sheet(isPresented: $updateModel.isConfirmingUpdate) {
            UpdateConfirmationView(
                tag: updateModel.availableUpdate?.latestRelease.tag ?? "the latest tag",
                onCancel: { updateModel.isConfirmingUpdate = false },
                onConfirm: { updateModel.confirmUpdate() }
            )
        }
        .alert(item: $model.message) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.body),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $updateModel.message) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.body),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: Self.headerIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Mac Mobile Dev Helper")
                        .font(.largeTitle.bold())
                    Text("by Dawid Moza")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text("Android device files, storage cleanup, and macOS development diagnostics.")
                    .foregroundStyle(.secondary)
                if updateModel.isUpdating, let statusText = updateModel.statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                if updateModel.isUpdating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                } else {
                    HStack(spacing: 10) {
                        Button("Check for Updates") {
                            Task {
                                await updateModel.checkForUpdates(
                                    force: true,
                                    showUpToDateMessage: true
                                )
                            }
                        }
                        .disabled(updateModel.isChecking)

                        if updateModel.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if updateModel.availableUpdate != nil {
                            Button(updateModel.updateButtonTitle) {
                                updateModel.requestUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        } else {
                            Text(updateModel.currentVersionText)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var androidFilesystemFeature: some View {
        DisclosureGroup(isExpanded: $isAndroidFilesystemExpanded) {
            AndroidFilesystemView()
                .padding(.top, 14)
        } label: {
            Label("1. Android Filesystem Browser", systemImage: "cable.connector")
                .font(.title2.bold())
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary)
        }
    }

    private var cleanupFeature: some View {
        DisclosureGroup(isExpanded: $isCleanupExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                diskUsageIndicator
                cleanupCategories
                cursorDatabaseNotice
                actionBar
            }
            .padding(.top, 14)
        } label: {
            Label("2. Storage Cleanup", systemImage: "internaldrive")
                .font(.title2.bold())
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary)
        }
    }

    private var portsFeature: some View {
        DisclosureGroup(isExpanded: $isPortsExpanded) {
            EphemeralPortsView()
                .padding(.top, 14)
        } label: {
            Label("3. Ephemeral Port Usage", systemImage: "network")
                .font(.title2.bold())
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary)
        }
    }

    private var diskUsageIndicator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Disk Usage", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                if let usage = model.snapshot.diskUsage {
                    Text("\(CleanupViewModel.format(usage.availableCapacity)) free")
                        .font(.headline.monospacedDigit())
                }
            }

            if let usage = model.snapshot.diskUsage {
                ProgressView(value: usage.usedFraction)
                    .tint(usage.usedFraction >= 0.9 ? .orange : .blue)
                    .accessibilityLabel("Disk usage")
                    .accessibilityValue("\(CleanupViewModel.format(usage.usedCapacity)) used, \(CleanupViewModel.format(usage.availableCapacity)) free, \(CleanupViewModel.format(usage.totalCapacity)) total")

                HStack {
                    Text("\(CleanupViewModel.format(usage.usedCapacity)) used")
                    Spacer()
                    Text("\(CleanupViewModel.format(usage.totalCapacity)) total")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(model.isWorking ? "Reading disk capacity…" : "Disk capacity unavailable. Try refreshing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .help("Storage on the volume containing your home folder. Free space excludes purgeable files.")
    }

    private var cleanupCategories: some View {
        VStack(spacing: 0) {
            ForEach(model.snapshot.categories) { category in
                categoryRow(category)
                if category.id != model.snapshot.categories.last?.id {
                    Divider()
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary)
        }
    }

    private func categoryRow(_ category: CleanupCategory) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.selectedCategoryIDs.contains(category.id) },
                    set: { model.setSelected($0, categoryID: category.id) }
                )
            )
            .labelsHidden()
            .disabled(category.items.isEmpty || model.isWorking)

            VStack(alignment: .leading, spacing: 5) {
                Text(category.id.title)
                    .font(.headline)
                Text(category.id.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = category.scanErrors.first {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(CleanupViewModel.format(category.totalAllocatedSize))
                    .font(.headline.monospacedDigit())
                Text("\(category.items.count) item(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var cursorDatabaseNotice: some View {
        if let database = model.snapshot.cursorDatabase {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: database.needsCompaction ? "exclamationmark.triangle.fill" : "internaldrive")
                        .foregroundStyle(database.needsCompaction ? .orange : .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Active Cursor database: \(CleanupViewModel.format(database.allocatedSize))")
                            .font(.headline)
                        Text("Cached agent and chat blobs in state.vscdb. This writes a smaller new file, then replaces the original so the disk space can be reclaimed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if database.isCursorRunning {
                            Text("Quit Cursor completely before compacting.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        } else if !database.hasEnoughDiskSpaceToCompact, let available = database.availableDiskSpace {
                            Text("Needs about \(CleanupViewModel.format(CursorDatabaseStatus.minimumFreeSpaceToCompact)) free for the new copy. This volume has \(CleanupViewModel.format(available)).")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Compact…") {
                        isConfirmingCursorCompact = true
                    }
                    .disabled(!model.canCompactCursorDatabase)
                }
            }
            .padding(14)
            .background(
                (database.needsCompaction ? Color.orange : Color.blue).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var actionBar: some View {
        HStack {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text(model.workingStatus)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(CleanupViewModel.format(model.selectedSize)) selected")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Refresh") {
                Task {
                    await model.refresh()
                }
            }
            .disabled(model.isWorking)

            Button("Clean Selected…") {
                isConfirmingCleanup = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canClean)
        }
    }
}

private struct UpdateConfirmationView: View {
    let tag: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install update and relaunch?")
                .font(.title2.bold())

            Text("Mac Mobile Dev Helper will clone \(tag) from GitHub, build it with Swift, replace this app, and relaunch. Xcode Command Line Tools are required.")

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Update", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 220)
    }
}

private struct CleanupConfirmationView: View {
    let items: [CleanupItem]
    let totalSize: Int64
    let isXcodeRunning: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permanently delete selected files?")
                .font(.title2.bold())

            Text("\(items.count) item(s), approximately \(CleanupViewModel.format(totalSize)), will be deleted immediately. This does not use the Trash.")

            if isXcodeRunning {
                Label(
                    "Xcode is running. Stop any device installation before continuing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(CleanupViewModel.format(item.allocatedSize))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 420)
    }
}

private struct CursorCompactConfirmationView: View {
    let database: CursorDatabaseStatus
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compact the active Cursor database?")
                .font(.title2.bold())

            Text("This does not delete settings. It copies everything except cached agent and chat blobs into a new smaller file, then replaces state.vscdb.")

            VStack(alignment: .leading, spacing: 8) {
                labeledValue("Current size", CleanupViewModel.format(database.allocatedSize))
                if let available = database.availableDiskSpace {
                    labeledValue("Free space", CleanupViewModel.format(available))
                }
                labeledValue("Database", database.path)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("Quit Cursor completely first, including helpers.")
                Text("Settings stay. In-app chats may show “Loading Chat…”. Transcripts remain in ~/.cursor/projects.")
                Text("Only a little free space is required for the new copy. Scanning a 50+ GB database can still take a long time.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if database.isCursorRunning {
                Label(
                    "Cursor is still running. Quit it before continuing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Compact Database", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(database.isCursorRunning || !database.hasEnoughDiskSpaceToCompact)
            }
        }
        .padding(24)
        .frame(width: 640, height: 420)
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }
}
