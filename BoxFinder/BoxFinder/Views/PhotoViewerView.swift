import SwiftUI
import UIKit

struct PhotoViewerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let photos: [PhotoRecord]
    let initialPhotoId: Int64

    @State private var currentIndex = 0
    @State private var loadedImage: UIImage?
    @State private var objects: [DetectedObject] = []
    @State private var overlaySource = ""
    @State private var showBoxes = true
    @State private var selectedObjectIndex: Int?
    @State private var resetTrigger = 0
    @State private var focusRequest: AnnotatedPhotoCanvas.FocusRequest?

    @State private var busy = false
    @State private var errorNotice: AlertNotice?
    @State private var showSetupSheet = false
    @State private var showObjectListSheet = false
    @State private var showOnlineUploadConfirm = false

    private var currentPhotoURL: URL? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return try? appState.fileStore.photoURL(for: photos[currentIndex].filename)
    }

    private var statusText: String {
        if let idx = selectedObjectIndex, objects.indices.contains(idx) {
            let obj = objects[idx]
            return obj.label + (obj.uncertain ? " · check identification/location" : "")
        }
        if objects.isEmpty {
            return "Pinch to zoom · Drag to move · Tap Identify objects to locate items."
        }
        let sourceNote = overlaySource.isEmpty ? "" : " · saved with \(overlaySource)"
        return "\(objects.count) suggested object(s)\(sourceNote) · Tap a box or open Object list. Dashed/? indicates uncertain label or location."
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topNavigationBar
                if let loadedImage {
                    AnnotatedPhotoCanvas(
                        image: loadedImage,
                        objects: objects,
                        showBoxes: showBoxes,
                        selectedIndex: $selectedObjectIndex,
                        resetTrigger: $resetTrigger,
                        focusRequest: $focusRequest
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                    Text("This photo could not be opened.")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                }

                VStack(spacing: 10) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button(objects.isEmpty && overlaySource.isEmpty ? "Identify objects" : "Identify again") {
                            triggerDetection()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || loadedImage == nil)

                        Button("Photo AI setup") {
                            showSetupSheet = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .disabled(busy)
                    }

                    HStack(spacing: 10) {
                        Toggle("Show boxes", isOn: $showBoxes)
                            .foregroundColor(.white)
                            .onChange(of: showBoxes) { newVal in
                                appState.settings.showBoxesInViewer = newVal
                            }

                        Button("Reset view") {
                            selectedObjectIndex = nil
                            resetTrigger += 1
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        Button("Object list") {
                            showObjectListSheet = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .disabled(objects.isEmpty)
                    }
                }
                .padding()
                .background(BoxFinderTheme.navy)
            }
            .background(BoxFinderTheme.navy.ignoresSafeArea())
            .overlay {
                if busy {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Locating objects…")
                                .foregroundColor(.white)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(24)
                        .background(BoxFinderTheme.navy)
                        .cornerRadius(16)
                    }
                }
            }
            .onAppear {
                showBoxes = appState.settings.showBoxesInViewer
                if let idx = photos.firstIndex(where: { $0.id == initialPhotoId }) {
                    currentIndex = idx
                }
                loadCurrentPhoto()
            }
            .sheet(isPresented: $showSetupSheet) {
                NavigationStack {
                    PhotoAiSetupView()
                }
            }
            .sheet(isPresented: $showObjectListSheet) {
                NavigationStack {
                    List(Array(objects.enumerated()), id: \.element.id) { idx, obj in
                        Button {
                            showBoxes = true
                            showObjectListSheet = false
                            focusRequest = AnnotatedPhotoCanvas.FocusRequest(index: idx)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(BoxFinderTheme.detectionColor(forIndex: idx, isSelected: idx == selectedObjectIndex))
                                    .frame(width: 12, height: 12)
                                Text("\(idx + 1). \(obj.label)")
                                    .foregroundColor(.primary)
                                Spacer()
                                if obj.uncertain {
                                    Text("Uncertain")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .navigationTitle("Suggested Objects")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showObjectListSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Identify this photo online?", isPresented: $showOnlineUploadConfirm, titleVisibility: .visible) {
                Button("Identify Online") {
                    Task { await runDetection() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let p = appState.photoAi.currentProvider
                let model = appState.settings.selectedOnlineModel(for: p)
                Text("Send only this single photo to \(p.displayName) using \(model)? API charges and provider limits may apply.")
            }
            .alert(item: $errorNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var topNavigationBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Spacer()

            Text("Photo \(currentIndex + 1) of \(max(1, photos.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)

            Spacer()

            Button("Prev") {
                guard !busy, currentIndex > 0 else { return }
                currentIndex -= 1
                loadCurrentPhoto()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(busy || currentIndex <= 0)

            Button("Next") {
                guard !busy, currentIndex + 1 < photos.count else { return }
                currentIndex += 1
                loadCurrentPhoto()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(busy || currentIndex + 1 >= photos.count)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(BoxFinderTheme.navy)
    }

    private func loadCurrentPhoto() {
        selectedObjectIndex = nil
        objects = []
        overlaySource = ""
        loadedImage = nil

        guard let url = currentPhotoURL,
              let img = UIImage(contentsOfFile: url.path) else {
            return
        }
        loadedImage = img
        if let stored = appState.annotationStore.load(forPhotoAt: url) {
            objects = stored.objects
            overlaySource = PhotoAiProvider(rawValue: stored.provider)?.displayName ?? stored.provider
        }
    }

    private func triggerDetection() {
        guard !busy else { return }
        if !appState.photoAi.isCurrentProviderReady() {
            showSetupSheet = true
            return
        }
        let provider = appState.photoAi.currentProvider
        if provider.isOnline && appState.settings.confirmUpload {
            showOnlineUploadConfirm = true
        } else {
            Task { await runDetection() }
        }
    }

    private func runDetection() async {
        guard let url = currentPhotoURL else { return }
        busy = true
        defer { busy = false }
        do {
            let meta = try await appState.photoAi.detectPhotoObjects(photoURL: url)
            objects = meta.objects
            overlaySource = PhotoAiProvider(rawValue: meta.provider)?.displayName ?? meta.provider
            selectedObjectIndex = nil
            showBoxes = true
            if objects.isEmpty {
                errorNotice = AlertNotice(
                    title: "No object locations returned",
                    message: "This model did not return usable bounding boxes. Object location quality depends on the vision model — try a clearer photo or another model in Photo AI setup."
                )
            }
        } catch {
            errorNotice = AlertNotice(
                title: "Could not locate objects",
                message: "\(error.localizedDescription)\n\nLocation quality depends on the vision model; you can switch providers or models in Photo AI setup."
            )
        }
    }
}
