import PhotosUI
import SwiftUI
import UIKit

struct BoxDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let boxId: Int64

    @State private var box: BoxRecord?
    @State private var items: [ItemRecord] = []
    @State private var photos: [PhotoRecord] = []

    @State private var showEditBox = false
    @State private var showQRLabel = false
    @State private var editingItem: ItemRecord?
    @State private var showAddItem = false
    @State private var showCamera = false
    @State private var selectedPhotoPicker: PhotosPickerItem?
    @State private var showDeleteBoxConfirm = false
    @State private var photoPendingDelete: PhotoRecord?
    @State private var viewerSelection: PhotoViewerSelection?
    @State private var showOnlineUploadConfirm = false

    struct PhotoViewerSelection: Identifiable {
        let id = UUID()
        let initialPhotoId: Int64
    }

    var body: some View {
        ScrollView {
            if let box {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard(box)
                    photosSection
                    itemsSection
                    manageSection
                }
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                Text("This box is no longer available.")
                    .foregroundColor(.secondary)
                    .padding(32)
            }
        }
        .background(BoxFinderTheme.pageBackground)
        .navigationTitle(box.map { "\($0.code) · \($0.name)" } ?? "Box")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: boxId) {
            await loadDetails()
        }
        .onChange(of: appState.boxSummaries) { _ in
            Task { await loadDetails() }
        }
        .onChange(of: selectedPhotoPicker) { newItem in
            guard let newItem else { return }
            selectedPhotoPicker = nil
            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        appState.notice = AlertNotice(title: "Unreadable photo", message: "The selected image could not be opened.")
                        return
                    }
                    await appState.addPhoto(image, toBox: boxId)
                    await loadDetails()
                } catch {
                    appState.notice = AlertNotice(title: "Photo error", message: error.localizedDescription)
                }
            }
        }
        .sheet(isPresented: $showEditBox) {
            if let box {
                BoxEditorSheet(existingBox: box) { name, location, notes in
                    _ = await appState.saveBox(id: box.id, name: name, location: location, notes: notes)
                    await loadDetails()
                }
            }
        }
        .sheet(isPresented: $showQRLabel) {
            if let box {
                QRLabelSheet(box: box)
            }
        }
        .sheet(isPresented: $showAddItem) {
            ItemEditorSheet(existingItem: nil) { name, category, quantity, notes in
                _ = await appState.saveItem(
                    id: 0,
                    boxId: boxId,
                    name: name,
                    category: category,
                    quantity: quantity,
                    notes: notes,
                    source: "manual"
                )
                await loadDetails()
            } onDelete: {}
        }
        .sheet(item: $editingItem) { item in
            ItemEditorSheet(existingItem: item) { name, category, quantity, notes in
                _ = await appState.saveItem(
                    id: item.id,
                    boxId: boxId,
                    name: name,
                    category: category,
                    quantity: quantity,
                    notes: notes,
                    source: item.source
                )
                await loadDetails()
            } onDelete: {
                await appState.deleteItem(id: item.id)
                await loadDetails()
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { image in
                Task {
                    await appState.addPhoto(image, toBox: boxId)
                    await loadDetails()
                }
            }
        }
        .fullScreenCover(item: $viewerSelection) { selection in
            PhotoViewerView(photos: photos, initialPhotoId: selection.initialPhotoId)
        }
        .confirmationDialog("Delete box?", isPresented: $showDeleteBoxConfirm, titleVisibility: .visible) {
            Button("Delete Box, Items & Photos", role: .destructive) {
                Task {
                    await appState.deleteBox(id: boxId)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the box, all its items, and its stored photos from this device.")
        }
        .confirmationDialog(
            "Remove photo?",
            isPresented: Binding(
                get: { photoPendingDelete != nil },
                set: { if !$0 { photoPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Photo", role: .destructive) {
                if let target = photoPendingDelete {
                    photoPendingDelete = nil
                    Task {
                        await appState.deletePhoto(target)
                        await loadDetails()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                photoPendingDelete = nil
            }
        }
        .confirmationDialog("Analyze photos online?", isPresented: $showOnlineUploadConfirm, titleVisibility: .visible) {
            Button("Analyze Online") {
                Task { await appState.identifyItemsInBox(boxId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let p = appState.photoAi.currentProvider
            let model = appState.settings.selectedOnlineModel(for: p)
            Text("Send \(photos.count) photo(s) from this box to \(p.displayName) using \(model)? API charges and provider limits may apply. No other inventory or Pi pairing key is sent.")
        }
    }

    private func headerCard(_ box: BoxRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Edit box") { showEditBox = true }
                    .buttonStyle(.bordered)
                Button("QR label") { showQRLabel = true }
                    .buttonStyle(.bordered)
                Spacer()
                Text(box.code)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(BoxFinderTheme.accent.opacity(0.14))
                    .foregroundColor(BoxFinderTheme.accent)
                    .cornerRadius(8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("LOCATION")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(box.location)
                    .font(.title3.weight(.semibold))
            }

            if !box.notes.isEmpty {
                Text(box.notes)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(BoxFinderTheme.cardBackground)
        .cornerRadius(16)
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos (\(photos.count)/4)")
                .font(.headline)
            Text("Add up to four photos of the contents. Tap a thumbnail to enlarge or locate objects.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        appState.notice = AlertNotice(title: "Camera unavailable", message: "Use Choose photo on this device or simulator.")
                    }
                } label: {
                    Label("Take photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(photos.count >= 4)

                PhotosPicker(selection: $selectedPhotoPicker, matching: .images) {
                    Label("Choose photo", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(photos.count >= 4)
            }

            if photos.isEmpty {
                Text("No photos yet. A photo can help identify several items at once.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { idx, photo in
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    viewerSelection = PhotoViewerSelection(initialPhotoId: photo.id)
                                } label: {
                                    PhotoThumbnailView(url: try? appState.fileStore.photoURL(for: photo.filename))
                                        .frame(width: 210, height: 152)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .accessibilityLabel("Open larger photo \(idx + 1)")

                                Text("Tap to enlarge / locate objects")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Button("Remove photo", role: .destructive) {
                                    photoPendingDelete = photo
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                let provider = appState.photoAi.currentProvider
                if photos.isEmpty {
                    appState.notice = AlertNotice(title: "Add a photo", message: "Take or choose a photo of the box contents first.")
                } else if !appState.photoAi.isCurrentProviderReady() {
                    appState.showPhotoAiSetupSheet = true
                } else if provider.isOnline && appState.settings.confirmUpload {
                    showOnlineUploadConfirm = true
                } else {
                    Task { await appState.identifyItemsInBox(boxId) }
                }
            } label: {
                Label("Identify items in photos", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Text("Photo AI: \(appState.photoAi.currentSummary())")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Setup") {
                    appState.showPhotoAiSetupSheet = true
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(16)
        .background(BoxFinderTheme.cardBackground)
        .cornerRadius(16)
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Items (\(items.count))")
                    .font(.headline)
                Spacer()
                Button {
                    showAddItem = true
                } label: {
                    Label("Add item", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if items.isEmpty {
                Text("No items recorded yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(items) { item in
                    Button {
                        editingItem = item
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.quantity) × \(item.name)")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.primary)
                                let meta = [item.category, item.notes].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                                if !meta.isEmpty {
                                    Text(meta)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if item.source != "manual" {
                                Text("AI")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(BoxFinderTheme.accent.opacity(0.14))
                                    .foregroundColor(BoxFinderTheme.accent)
                                    .cornerRadius(6)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(BoxFinderTheme.secondaryFill)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(BoxFinderTheme.cardBackground)
        .cornerRadius(16)
    }

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manage Box")
                .font(.headline)
            Button("Delete this box", role: .destructive) {
                showDeleteBoxConfirm = true
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(BoxFinderTheme.cardBackground)
        .cornerRadius(16)
    }

    private func loadDetails() async {
        box = try? await appState.repository.box(id: boxId)
        items = (try? await appState.repository.items(boxId: boxId)) ?? []
        photos = (try? await appState.repository.photos(boxId: boxId)) ?? []
    }
}

private struct PhotoThumbnailView: View {
    let url: URL?

    var body: some View {
        if let url, let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                BoxFinderTheme.secondaryFill
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            }
        }
    }
}
