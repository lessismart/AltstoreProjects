import SwiftUI

private enum CameraEditorTarget: Identifiable {
    case add
    case edit(CameraProfile)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let profile): return "edit-\(profile.id.uuidString)"
        }
    }
}

struct LiveDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editorTarget: CameraEditorTarget?
    @State private var isFullscreen = false
    @State private var showPTZPopover = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 14) {
                    if !self.isFullscreen {
                        self.cameraHeaderBar
                    }

                    if self.appState.gridModeEnabled && self.appState.cameras.count > 1 && !self.isFullscreen {
                        self.multiCameraGrid
                    } else if let camera = self.appState.selectedCamera {
                        self.singleCameraPane(camera: camera)
                    } else {
                        self.emptyState
                    }
                }
                .padding(self.isFullscreen ? 0 : 16)
            }
            .navigationTitle(self.isFullscreen ? "" : "Live View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(self.isFullscreen ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        if self.appState.cameras.count > 1 {
                            Button {
                                self.appState.gridModeEnabled.toggle()
                            } label: {
                                Label(self.appState.gridModeEnabled ? "Single" : "Grid", systemImage: self.appState.gridModeEnabled ? "rectangle" : "square.grid.2x2")
                            }
                        }
                        Button {
                            self.editorTarget = .add
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(item: self.$editorTarget) { target in
                switch target {
                case .add:
                    CameraEditorSheet(existingProfile: nil, initialPassword: "")
                        .environmentObject(self.appState)
                case .edit(let profile):
                    CameraEditorSheet(existingProfile: profile, initialPassword: self.appState.password(for: profile))
                        .environmentObject(self.appState)
                }
            }
        }
    }

    private var cameraHeaderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(self.appState.cameras) { cam in
                    let isSelected = cam.id == self.appState.selectedCamera?.id
                    Button {
                        self.appState.selectCamera(cam)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(self.appState.session(for: cam).isConnected ? Theme.green : Theme.muted.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text(cam.name)
                                .font(.subheadline.weight(.semibold))
                            Text(cam.host)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? Theme.teal.opacity(0.18) : Theme.surface)
                        .overlay(
                            Capsule().stroke(isSelected ? Theme.teal : Theme.border, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Camera") {
                            self.editorTarget = .edit(cam)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func singleCameraPane(camera: CameraProfile) -> some View {
        let session = self.appState.session(for: camera)
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                LiveVideoCanvas(session: session, showDetections: self.appState.kioskMonitoringActive)
                    .aspectRatio(self.isFullscreen ? nil : 16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: self.isFullscreen ? .infinity : 540)
                    .clipShape(RoundedRectangle(cornerRadius: self.isFullscreen ? 0 : 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: self.isFullscreen ? 0 : 16, style: .continuous)
                            .stroke(session.isRecording ? Theme.rose : Theme.border, lineWidth: session.isRecording ? 2 : 1)
                    )

                // Telemetry overlay
                HStack(spacing: 8) {
                    StatusChip(
                        text: session.isConnected ? "LIVE · \(session.fps) FPS · \(session.kbps) kbps" : session.statusText.uppercased(),
                        color: session.isConnected ? Theme.green : Theme.amber
                    )
                    if session.codecLabel != "--" {
                        StatusChip(text: "\(session.codecLabel) · \(session.resolutionText)", color: Theme.sky)
                    }
                    if session.isRecording {
                        StatusChip(text: "REC ●", color: Theme.rose)
                    }
                    Spacer()
                    Button {
                        self.isFullscreen.toggle()
                    } label: {
                        Image(systemName: self.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.bold())
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(12)
            }

            // Control strip
            ControlCard(nil) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button {
                            if session.isConnected || session.isConnecting {
                                self.appState.disconnectStream(for: camera)
                            } else {
                                self.appState.connectStream(for: camera)
                            }
                        } label: {
                            Label(session.isConnected || session.isConnecting ? "Disconnect" : "Connect Live",
                                  systemImage: session.isConnected || session.isConnecting ? "stop.circle.fill" : "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(session.isConnected || session.isConnecting ? Theme.rose : Theme.teal)

                        Button {
                            let target: StreamQuality = session.activeQuality == .main ? .sub : .main
                            self.appState.connectStream(for: camera, quality: target)
                        } label: {
                            Label(session.activeQuality.label, systemImage: "sparkles.tv")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.sky)

                        Button {
                            session.isMuted.toggle()
                        } label: {
                            Label(session.isMuted ? "Muted" : "Audio On",
                                  systemImage: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            self.appState.captureSnapshot(for: camera)
                        } label: {
                            Label("Snapshot", systemImage: "camera.fill")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await self.appState.toggleManualRecord(for: camera) }
                        } label: {
                            Label(session.isRecording ? "Stop Rec" : "Record",
                                  systemImage: session.isRecording ? "stop.fill" : "record.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(session.isRecording ? Theme.rose : Theme.amber)

                        if self.appState.onvifCapabilities?.supportsPTZ == true {
                            Button {
                                self.showPTZPopover.toggle()
                            } label: {
                                Label("PTZ", systemImage: "dpad")
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.teal)
                            .popover(isPresented: self.$showPTZPopover) {
                                PTZPadView(camera: camera)
                                    .environmentObject(self.appState)
                                    .padding()
                                    .frame(width: 260)
                                    .background(Theme.bg)
                            }
                        }

                        Button {
                            self.editorTarget = .edit(camera)
                        } label: {
                            Label("Setup", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var multiCameraGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(self.appState.cameras.prefix(4)) { cam in
                    let sess = self.appState.session(for: cam)
                    VStack(alignment: .leading, spacing: 6) {
                        LiveVideoCanvas(session: sess, showDetections: self.appState.kioskMonitoringActive)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Text(cam.name).font(.subheadline.bold())
                            Spacer()
                            Button(sess.isConnected ? "Stop" : "Play") {
                                if sess.isConnected { self.appState.disconnectStream(for: cam) }
                                else { self.appState.connectStream(for: cam, quality: .sub) }
                            }
                            .font(.caption.bold())
                        }
                    }
                    .padding(10)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture {
                        self.appState.selectCamera(cam)
                        self.appState.gridModeEnabled = false
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ControlCard("No Camera Configured") {
            Text("Add your Xiongmai / ONVIF camera by IP address or scan your local Wi-Fi network.")
                .foregroundStyle(Theme.muted)
            Button("Add Camera") {
                self.editorTarget = .add
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
        }
    }
}

struct PTZPadView: View {
    @EnvironmentObject private var appState: AppState
    let camera: CameraProfile

    var body: some View {
        VStack(spacing: 12) {
            Text("PTZ Control")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 48, height: 48)
                    self.ptzButton(icon: "arrow.up", pan: 0, tilt: 0.5)
                    Color.clear.frame(width: 48, height: 48)
                }
                GridRow {
                    self.ptzButton(icon: "arrow.left", pan: -0.5, tilt: 0)
                    Button {
                        Task { await self.appState.gotoHomePTZ(camera: self.camera) }
                    } label: {
                        Image(systemName: "house.fill")
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                    self.ptzButton(icon: "arrow.right", pan: 0.5, tilt: 0)
                }
                GridRow {
                    Color.clear.frame(width: 48, height: 48)
                    self.ptzButton(icon: "arrow.down", pan: 0, tilt: -0.5)
                    Color.clear.frame(width: 48, height: 48)
                }
            }
            if !self.appState.ptzPresets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(self.appState.ptzPresets) { p in
                            Button(p.name) {
                                Task { await self.appState.recallPTZPreset(p, camera: self.camera) }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func ptzButton(icon: String, pan: Double, tilt: Double) -> some View {
        Button {
            Task {
                await self.appState.movePTZ(camera: self.camera, pan: pan, tilt: tilt)
                try? await Task.sleep(nanoseconds: 400_000_000)
                await self.appState.stopPTZ(camera: self.camera)
            }
        } label: {
            Image(systemName: icon)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.surfaceAlt)
    }
}
