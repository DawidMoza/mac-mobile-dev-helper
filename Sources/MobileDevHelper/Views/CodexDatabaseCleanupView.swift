import SwiftUI

struct CodexDatabaseCleanupView: View {
    @ObservedObject var model: CleanupViewModel
    @State private var databaseToCompact: CodexDatabaseStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.snapshot.codexDatabases) { database in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Codex: \(URL(fileURLWithPath: database.path).lastPathComponent)")
                            .font(.headline)
                        Text("\(CleanupViewModel.format(database.allocatedSize)) database · \(CleanupViewModel.format(database.walSize)) write-ahead log")
                            .font(.callout.monospacedDigit())
                        Text("Reclaim unused database space while preserving all records. Savings may be zero.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(database.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if model.snapshot.runningAgents.contains(.codex) {
                            Text("Quit Codex, including CLI sessions and editor extensions, then refresh.")
                                .foregroundStyle(.orange)
                        } else if !database.hasEnoughDiskSpace {
                            Text("Needs approximately \(CleanupViewModel.format(database.requiredFreeSpace)) free to compact.")
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Compact…") { databaseToCompact = database }
                        .disabled(!model.canCompactCodexDatabase(database))
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
        .sheet(item: $databaseToCompact) { database in
            VStack(alignment: .leading, spacing: 16) {
                Text("Compact this Codex database?")
                    .font(.title2.bold())
                Text("This reclaims unused SQLite pages and preserves all database records. It does not delete conversations or logs, and may reclaim no space if the database is already compact.")
                Text(database.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("Current size including write-ahead log: \(CleanupViewModel.format(database.allocatedSize + database.walSize))")
                Text("Allow approximately \(CleanupViewModel.format(database.requiredFreeSpace)) of free space. Quit Codex and its terminal sessions and editor extensions first.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { databaseToCompact = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Compact Database") {
                        databaseToCompact = nil
                        Task { await model.compactCodexDatabase(database) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCompactCodexDatabase(database))
                }
            }
            .padding(24)
            .frame(width: 600)
        }
    }
}
