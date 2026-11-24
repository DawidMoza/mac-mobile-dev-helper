import SwiftUI

struct CustomCleanupPathsView: View {
    let model: CleanupViewModel
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var original: String?
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Cleanup Paths")
                .font(.title2.bold())
            Text("Enter one file or folder per line. Use an absolute path or start with ~/. Lines beginning with # are comments.")
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Custom cleanup paths")
                .border(.quaternary)
                .disabled(original == nil || isBusy)
                .frame(minHeight: 180)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Open Text File") {
                    Task { await perform { try await model.openCustomPathsFile() } }
                }
                .disabled(isBusy || (original != nil && text != original))

                Button("Reload Text File") {
                    Task { await load() }
                }
                .disabled(isBusy)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    guard let original else { return }
                    Task {
                        await perform {
                            try await model.saveCustomPaths(text, replacing: original)
                            onSave()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || original == nil || text == original)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { await load() }
    }

    private func load() async {
        await perform {
            let saved = try await model.readCustomPaths()
            original = saved
            text = saved
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
