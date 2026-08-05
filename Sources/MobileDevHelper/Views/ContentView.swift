import SwiftUI

struct ContentView: View {
    @StateObject private var model = CleanupViewModel()
    @State private var isConfirmingCleanup = false
    @State private var isAndroidFilesystemExpanded = true
    @State private var isCleanupExpanded = true
    @State private var isPortsExpanded = true

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
            await model.refresh()
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
        .alert(item: $model.message) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.body),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mac Mobile Dev Helper")
                .font(.largeTitle.bold())
            Text("Android device files, storage cleanup, and macOS development diagnostics.")
                .foregroundStyle(.secondary)
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
        if let size = model.snapshot.activeCursorDatabaseSize {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active Cursor database: \(CleanupViewModel.format(size))")
                        .font(.headline)
                    Text("This app never deletes state.vscdb. In Cursor, use “Developer: GC Agent KV Blobs” to safely compact agent data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var actionBar: some View {
        HStack {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning or cleaning…")
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
