import SwiftUI

struct SuggestionReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var items: [SuggestedItem]
    let onCommit: ([SuggestedItem]) async -> Void

    init(session: ReviewSuggestionSession, onCommit: @escaping ([SuggestedItem]) async -> Void) {
        self._items = State(initialValue: session.items)
        self.onCommit = onCommit
    }

    private var selectedCount: Int {
        items.filter(\.selected).count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Review and edit AI suggestions before saving them to this box. Nothing is added automatically.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("Suggested Items (\(selectedCount) selected)") {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Toggle(isOn: $item.selected) {
                                    Text(item.name.isEmpty ? "Unnamed item" : item.name)
                                        .font(.headline)
                                }
                                if item.uncertain {
                                    Text("Uncertain")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.16))
                                        .foregroundColor(.orange)
                                        .cornerRadius(6)
                                }
                            }

                            if item.selected {
                                TextField("Item name", text: $item.name)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Category (optional)", text: $item.category)
                                    .textFieldStyle(.roundedBorder)
                                Stepper("Quantity: \(item.quantity)", value: $item.quantity, in: 1...9999)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Review Suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedCount))") {
                        Task {
                            await onCommit(items)
                            dismiss()
                        }
                    }
                    .disabled(selectedCount == 0 || items.filter(\.selected).contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
        }
    }
}
