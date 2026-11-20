import AVKit
import SwiftUI

struct RecordingsView: View {
    enum SourceTab: String, CaseIterable {
        case sdCard = "Camera MicroSD (:34567)"
        case localDevice = "iPad / iPhone Local"
    }

    @EnvironmentObject private var appState: AppState
    @State private var sourceTab: SourceTab = .localDevice
    @State private var queryDate = Date()
    @State private var alarmOnly = false
    @State private var playingURL: URL?
    @State private var previewSnapshot: LocalMediaItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 14) {
                    Picker("Source", selection: self.$sourceTab) {
                        ForEach(SourceTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if self.sourceTab == .sdCard {
                        self.cameraSDTab
                    } else {
                        self.localMediaTab
                    }
                }
                .padding(.top, 12)
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: self.$previewSnapshot) { item in
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        if let img = UIImage(contentsOfFile: self.appState.mediaStore.fileURL(forRelativePath: item.relativePath).path) {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Save to Photos") {
                                if let img = UIImage(contentsOfFile: self.appState.mediaStore.fileURL(forRelativePath: item.relativePath).path) {
                                    Task {
                                        try? await LocalMediaStore.exportImageToPhotos(img)
                                        self.appState.showBanner("Saved snapshot to Photos.")
                                    }
                                }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close") { self.previewSnapshot = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { self.playingURL != nil },
                set: { if !$0 { self.playingURL = nil } }
            )) {
                if let url = self.playingURL {
                    NavigationStack {
                        VideoPlayer(player: AVPlayer(url: url))
                            .ignoresSafeArea(edges: .bottom)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Save to Photos") {
                                        Task {
                                            try? await LocalMediaStore.exportVideoToPhotos(url)
                                            self.appState.showBanner("Saved clip to Photos.")
                                        }
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Close") { self.playingURL = nil }
                                }
                            }
                    }
                }
            }
        }
    }

    private var cameraSDTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let camera = self.appState.selectedCamera {
                    ControlCard("Query MicroSD Recordings (\(camera.name))", accent: Theme.sky) {
                        DatePicker("Date", selection: self.$queryDate, displayedComponents: .date)
                        Toggle("Alarm / Motion Clips Only", isOn: self.$alarmOnly)

                        HStack {
                            Button {
                                Task {
                                    await self.appState.querySDRecordings(camera: camera, day: self.queryDate, alarmOnly: self.alarmOnly)
                                }
                            } label: {
                                Label("Search MicroSD", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.sky)

                            if self.appState.isDownloadingRecording {
                                ProgressView()
                                    .padding(.leading, 8)
                            }
                        }
                    }

                    ControlCard("Camera Clips (\(self.appState.dvripRecordings.count))", accent: Theme.teal) {
                        if self.appState.dvripRecordings.isEmpty {
                            Text("Tap 'Search MicroSD' to list recordings stored inside the camera.")
                                .foregroundStyle(Theme.muted)
                        } else {
                            ForEach(self.appState.dvripRecordings) { rec in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text(rec.beginTime)
                                                .font(.subheadline.monospaced().bold())
                                                .foregroundStyle(Theme.text)
                                            if rec.isAlarm {
                                                StatusChip(text: "ALARM", color: Theme.amber)
                                            }
                                        }
                                        Text("\(rec.fileName) · \(ByteCountFormatter.string(fromByteCount: rec.sizeBytes, countStyle: .file))")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Theme.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Download MP4") {
                                        Task { await self.appState.downloadSDRecording(rec, camera: camera) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(self.appState.isDownloadingRecording)
                                }
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                } else {
                    Text("No camera selected.")
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(16)
        }
    }

    private var localMediaTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if self.appState.mediaItems.isEmpty {
                    ControlCard("No Local Clips or Snapshots") {
                        Text("Snapshots, manual MP4 recordings, Vision alert clips, and downloaded camera recordings appear here.")
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    ForEach(self.appState.mediaItems) { item in
                        let fileURL = self.appState.mediaStore.fileURL(forRelativePath: item.relativePath)
                        ControlCard(nil) {
                            HStack(spacing: 12) {
                                if item.kind == .snapshot, let img = UIImage(contentsOfFile: fileURL.path) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 96, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Image(systemName: "film.fill")
                                        .font(.title2)
                                        .foregroundStyle(Theme.teal)
                                        .frame(width: 96, height: 60)
                                        .background(Theme.surfaceAlt)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        StatusChip(text: item.kind.badge, color: item.kind == .alertClip ? Theme.amber : Theme.teal)
                                        Text(item.cameraName)
                                            .font(.subheadline.bold())
                                    }
                                    Text(item.caption.isEmpty ? item.relativePath : item.caption)
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                        .lineLimit(1)
                                    Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                ShareLink(item: fileURL) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    self.appState.deleteMediaItem(item)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if item.kind == .snapshot {
                                    self.previewSnapshot = item
                                } else {
                                    self.playingURL = fileURL
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}
