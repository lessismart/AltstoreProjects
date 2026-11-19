import SwiftUI

struct BoxEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingBox: BoxRecord?
    let onSave: (String, String, String) async -> Void

    @State private var name = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var saving = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Box Details") {
                    TextField("Box name (required)", text: $name)
                    TextField("Location (required)", text: $location)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(existingBox == nil ? "New Box" : "Edit Box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            await onSave(name, location, notes)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(!isValid || saving)
                }
            }
            .onAppear {
                if let existingBox {
                    name = existingBox.name
                    location = existingBox.location
                    notes = existingBox.notes
                }
            }
        }
    }
}
