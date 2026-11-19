import SwiftUI

struct ItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingItem: ItemRecord?
    let onSave: (String, String, Int, String) async -> Void
    let onDelete: () async -> Void

    @State private var name = ""
    @State private var category = ""
    @State private var quantity = 1
    @State private var notes = ""
    @State private var showDeleteConfirm = false
    @State private var saving = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...9999).contains(quantity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item Details") {
                    TextField("Item name (required)", text: $name)
                    TextField("Category (optional)", text: $category)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...9999)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if existingItem != nil {
                    Section {
                        Button("Delete Item", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .navigationTitle(existingItem == nil ? "Add Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            await onSave(name, category, quantity, notes)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(!isValid || saving)
                }
            }
            .onAppear {
                if let existingItem {
                    name = existingItem.name
                    category = existingItem.category
                    quantity = max(1, min(9999, existingItem.quantity))
                    notes = existingItem.notes
                }
            }
            .confirmationDialog("Delete item?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Item", role: .destructive) {
                    Task {
                        await onDelete()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
