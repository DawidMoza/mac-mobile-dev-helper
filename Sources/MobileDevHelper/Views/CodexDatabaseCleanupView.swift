import SwiftUI

struct CodexDatabaseCleanupView: View {
    @ObservedObject var model: CleanupViewModel
    @State private var isConfirmingCompaction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.snapshot.codexDatabases.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Codex databases")
                            .font(.headline)
                        Text("\(CleanupViewModel.format(model.codexDatabaseSize + model.codexDatabaseWALSize)) total · \(model.snapshot.codexDatabases.count) database(s)")
                            .font(.callout.monospacedDigit())
                        Text("Reclaim unused database space while preserving all records. Savings may be zero.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        DisclosureGroup("Database files") {
                            databaseDetails
                                .padding(.top, 5)
                        }
                        if model.snapshot.runningAgents.contains(.codex) {
                            Text("Quit Codex, including CLI sessions and editor extensions, then refresh.")
                                .foregroundStyle(.orange)
                        } else if model.snapshot.codexDatabases.contains(where: { !$0.hasEnoughDiskSpace }) {
                            Text("Needs approximately \(CleanupViewModel.format(model.codexCompactionRequiredFreeSpace)) free to compact.")
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Compact All…") { isConfirmingCompaction = true }
                        .disabled(!model.canCompactCodexDatabases)
                }
                .padding(14)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(model.snapshot.agentDatabaseScanErrors, id: \.self) { error in
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $isConfirmingCompaction) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Compact all Codex databases?")
                    .font(.title2.bold())
                Text("This reclaims unused SQLite pages and preserves all database records. It does not delete conversations or logs, and may reclaim no space if the databases are already compact.")
                ScrollView {
                    databaseDetails
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                Text("Current size including write-ahead logs: \(CleanupViewModel.format(model.codexDatabaseSize + model.codexDatabaseWALSize))")
                Text("Databases are compacted one at a time. Allow approximately \(CleanupViewModel.format(model.codexCompactionRequiredFreeSpace)) of free space. Quit Codex and its terminal sessions and editor extensions first.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { isConfirmingCompaction = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Compact All Databases") {
                        isConfirmingCompaction = false
                        Task { await model.compactCodexDatabases() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCompactCodexDatabases)
                }
            }
            .padding(24)
            .frame(width: 600)
        }
    }

    private var databaseDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.snapshot.codexDatabases) { database in
                VStack(alignment: .leading, spacing: 3) {
                    Text(database.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("\(CleanupViewModel.format(database.allocatedSize)) database · \(CleanupViewModel.format(database.walSize)) write-ahead log")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}
