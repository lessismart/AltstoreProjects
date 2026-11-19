import SwiftUI

struct AskGemmaSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var busy = false
    @State private var result: AskGemmaResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ask Gemma searches only your locally recorded inventory on this device. No photos or inventory leave this device.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextEditor(text: $question)
                        .frame(minHeight: 96)
                        .padding(8)
                        .background(BoxFinderTheme.cardBackground)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                    Text("Example: \"What tools can I use to hang a picture?\" (max 500 chars)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        ask()
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "Searching with Gemma…" : "Find Boxes")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundColor(.red)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(12)
                    }

                    if let result {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Searched \(result.searchedCount) of \(result.totalCount) boxes. Verify items in the box before use.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if result.matches.isEmpty {
                                Text("No relevant recorded items were matched. Try the instant keyword search on the home screen — it always searches every record.")
                                    .font(.subheadline)
                            } else {
                                ForEach(result.matches) { box in
                                    Button {
                                        appState.selectedBoxId = box.id
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(box.code) · \(box.name)")
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Text(box.location)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding()
                                        .background(BoxFinderTheme.cardBackground)
                                        .cornerRadius(12)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(BoxFinderTheme.pageBackground)
            .navigationTitle("Ask Gemma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func ask() {
        errorMessage = nil
        result = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let boxes = appState.boxSummaries.map(\.box)
                var itemsMap: [Int64: [ItemRecord]] = [:]
                for s in appState.boxSummaries {
                    itemsMap[s.box.id] = s.items
                }
                result = try await appState.photoAi.askGemma(
                    question: question,
                    boxes: boxes,
                    itemsByBox: itemsMap
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
