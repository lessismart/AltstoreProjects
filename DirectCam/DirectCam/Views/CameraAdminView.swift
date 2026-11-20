import SwiftUI

struct CameraAdminView: View {
    @EnvironmentObject private var appState: AppState

    @State private var brightness = 50.0
    @State private var contrast = 50.0
    @State private var saturation = 50.0
    @State private var sharpness = 50.0
    @State private var irMode: IRCutFilterMode = .auto

    @State private var mainCodec = "H.265"
    @State private var mainFPS = 15
    @State private var mainBitrate = 1024
    @State private var encodeAudio = true

    @State private var osdTitle = ""
    @State private var osdShowTitle = true
    @State private var osdShowTime = true

    @State private var motionEnabled = true
    @State private var motionLevel = 3
    @State private var humanEnabled = true
    @State private var humanSensitivity = 50
    @State private var whiteLightMode: DVRIPWhiteLightMode = .auto
    @State private var cloudP2PEnabled = false

    @State private var newPresetName = ""
    @State private var newPassword = ""
    @State private var confirmReboot = false
    @State private var confirmFormatStep1 = false
    @State private var confirmFormatStep2 = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    if let camera = self.appState.selectedCamera {
                        VStack(spacing: 16) {
                            self.diagnosticsSection(camera: camera)
                            self.imagingSection(camera: camera)
                            if self.appState.onvifCapabilities?.supportsPTZ == true {
                                self.ptzSection(camera: camera)
                            }
                            self.encoderOSDSection(camera: camera)
                            self.detectionEventsSection(camera: camera)
                            self.storagePrivacySection(camera: camera)
                        }
                        .padding(16)
                    } else {
                        Text("Select or add a camera in Live View first.")
                            .foregroundStyle(Theme.muted)
                            .padding()
                    }
                }
            }
            .navigationTitle("Direct Camera Admin")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: self.appState.imagingSettings) { settings in
                if let settings {
                    self.brightness = settings.brightness
                    self.contrast = settings.contrast
                    self.saturation = settings.saturation
                    self.sharpness = settings.sharpness
                    self.irMode = settings.irCutFilter
                }
            }
            .onChange(of: self.appState.dvripEncodeConfig) { enc in
                if let enc {
                    self.mainCodec = enc.mainStream.compression
                    self.mainFPS = enc.mainStream.fps
                    self.mainBitrate = enc.mainStream.bitRate
                    self.encodeAudio = enc.mainStream.audioEnable
                }
            }
            .onChange(of: self.appState.dvripDetectionConfig) { det in
                if let det {
                    self.motionEnabled = det.motionEnabled
                    self.motionLevel = det.motionLevel
                    self.humanEnabled = det.humanEnabled
                    self.humanSensitivity = det.humanSensitivity
                }
            }
            .onChange(of: self.appState.dvripWhiteLightConfig) { wl in
                if let wl { self.whiteLightMode = wl.workMode }
            }
            .onChange(of: self.appState.dvripOSDConfig) { osd in
                if let osd {
                    self.osdTitle = osd.title
                    self.osdShowTitle = osd.showTitle
                    self.osdShowTime = osd.showTimestamp
                }
            }
            .onChange(of: self.appState.dvripPrivacyConfig) { priv in
                if let priv { self.cloudP2PEnabled = priv.natEnabled }
            }
        }
    }

    private func diagnosticsSection(camera: CameraProfile) -> some View {
        ControlCard("Device Diagnostics & Maintenance (\(camera.host))", accent: Theme.sky) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        _ = await self.appState.probePorts(for: camera)
                        await self.appState.refreshAllAdmin(for: camera)
                    }
                } label: {
                    Label(self.appState.isLoadingAdmin ? "Refreshing..." : "Load Camera Info", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .disabled(self.appState.isLoadingAdmin)

                Button {
                    Task { await self.appState.syncCameraClock(for: camera) }
                } label: {
                    Label("Sync Clock", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    self.confirmReboot = true
                } label: {
                    Label("Reboot", systemImage: "power")
                }
                .buttonStyle(.bordered)
            }
            .confirmationDialog("Reboot \(camera.name)?", isPresented: self.$confirmReboot) {
                Button("Reboot Camera Now", role: .destructive) {
                    Task { await self.appState.rebootCamera(camera) }
                }
            }

            if let msg = self.appState.adminStatusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }

            if let probe = self.appState.portProbes[camera.id] {
                HStack(spacing: 8) {
                    StatusChip(text: "RTSP :\(camera.rtspPort)", color: probe.rtspOpen ? Theme.green : Theme.rose)
                    StatusChip(text: "ONVIF :\(camera.onvifPort)", color: probe.onvifOpen ? Theme.green : Theme.amber)
                    StatusChip(text: "DVRIP :\(camera.dvripPort)", color: probe.dvripOpen ? Theme.green : Theme.amber)
                    StatusChip(text: "HTTP :\(camera.httpPort)", color: probe.httpOpen ? Theme.green : Theme.muted)
                }
            }

            if let dev = self.appState.onvifDeviceInfo {
                Text("ONVIF: \(dev.manufacturer) \(dev.model) · FW \(dev.firmwareVersion) · SN \(dev.serialNumber)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.text)
            }
            if let sys = self.appState.dvripSystemInfo {
                Text("DVRIP Hardware: \(sys.hardWare) · SW: \(sys.softWareVersion) · Build: \(sys.buildTime)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func imagingSection(camera: CameraProfile) -> some View {
        ControlCard("Image, Night Vision & Spotlight", accent: Theme.amber) {
            Picker("IR Cut Filter (ONVIF)", selection: self.$irMode) {
                ForEach(IRCutFilterMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)

            self.sliderRow("Brightness", value: self.$brightness)
            self.sliderRow("Contrast", value: self.$contrast)
            self.sliderRow("Saturation", value: self.$saturation)
            self.sliderRow("Sharpness", value: self.$sharpness)

            HStack {
                Button("Apply ONVIF Imaging") {
                    let s = ONVIFImagingSettings(
                        brightness: self.brightness,
                        contrast: self.contrast,
                        saturation: self.saturation,
                        sharpness: self.sharpness,
                        irCutFilter: self.irMode
                    )
                    Task { await self.appState.applyImagingSettings(s, for: camera) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
            }

            Divider().overlay(Theme.border)

            Picker("White LED / Spotlight (DVRIP)", selection: self.$whiteLightMode) {
                ForEach(DVRIPWhiteLightMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Button("Save Spotlight Mode") {
                Task { await self.appState.saveDVRIPWhiteLight(self.whiteLightMode, for: camera) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func ptzSection(camera: CameraProfile) -> some View {
        ControlCard("PTZ & Camera Presets", accent: Theme.teal) {
            PTZPadView(camera: camera)
                .environmentObject(self.appState)

            HStack {
                TextField("New preset name", text: self.$newPresetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save Preset") {
                    let trimmed = self.newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task {
                        await self.appState.savePTZPreset(named: trimmed, camera: camera)
                        self.newPresetName = ""
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func encoderOSDSection(camera: CameraProfile) -> some View {
        ControlCard("Encoder Stream & On-Screen Display (:34567)", accent: Theme.teal) {
            Picker("Codec", selection: self.$mainCodec) {
                Text("H.265 (HEVC)").tag("H.265")
                Text("H.264").tag("H.264")
            }
            .pickerStyle(.segmented)

            Stepper("Main FPS: \(self.mainFPS)", value: self.$mainFPS, in: 5...30)
            Stepper("Bitrate (kbps): \(self.mainBitrate)", value: self.$mainBitrate, in: 256...6144, step: 128)
            Toggle("Camera Audio Stream Enabled", isOn: self.$encodeAudio)

            Button("Save Encoder Settings") {
                Task {
                    await self.appState.saveDVRIPEncoder(
                        mainCodec: self.mainCodec,
                        mainFPS: self.mainFPS,
                        mainBitrate: self.mainBitrate,
                        audioEnable: self.encodeAudio,
                        for: camera
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)

            Divider().overlay(Theme.border)

            TextField("OSD Camera Title", text: self.$osdTitle)
                .textFieldStyle(.roundedBorder)
            Toggle("Show Channel Title Overlay", isOn: self.$osdShowTitle)
            Toggle("Show Timestamp Overlay", isOn: self.$osdShowTime)
            Button("Save OSD Overlay") {
                Task {
                    await self.appState.saveDVRIPOSD(
                        title: self.osdTitle,
                        showTitle: self.osdShowTitle,
                        showTimestamp: self.osdShowTime,
                        for: camera
                    )
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func detectionEventsSection(camera: CameraProfile) -> some View {
        ControlCard("Camera AI Detection & ONVIF PullPoint Events", accent: Theme.green) {
            Toggle("Camera Motion Detection", isOn: self.$motionEnabled)
            Stepper("Motion Sensitivity Level: \(self.motionLevel)", value: self.$motionLevel, in: 1...6)
            Toggle("Camera Humanoid Detection", isOn: self.$humanEnabled)
            Stepper("Humanoid Sensitivity: \(self.humanSensitivity)", value: self.$humanSensitivity, in: 1...100, step: 5)

            Button("Save DVRIP Detection Rules") {
                Task {
                    await self.appState.saveDVRIPDetection(
                        motionEnabled: self.motionEnabled,
                        motionLevel: self.motionLevel,
                        humanEnabled: self.humanEnabled,
                        humanSens: self.humanSensitivity,
                        for: camera
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.green)

            Divider().overlay(Theme.border)

            HStack {
                Button {
                    self.appState.toggleONVIFEventMonitor(for: camera)
                } label: {
                    Label(self.appState.isPullingEvents ? "Stop ONVIF Event Listener" : "Subscribe ONVIF Events",
                          systemImage: "bell.badge")
                }
                .buttonStyle(.bordered)
                Spacer()
                if self.appState.isPullingEvents {
                    ProgressView()
                }
            }

            ForEach(self.appState.motionEvents.prefix(5)) { ev in
                Text("[\(ev.timestamp.formatted(date: .omitted, time: .standard))] \(ev.topic): \(ev.detail)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func storagePrivacySection(camera: CameraProfile) -> some View {
        ControlCard("MicroSD Storage & Privacy Lockdown (:34567)", accent: Theme.rose) {
            if let storage = self.appState.dvripStorageInfo, !storage.partitions.isEmpty {
                ForEach(storage.partitions) { part in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("SD Partition \(part.partIndex) (\(part.statusText))")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(part.remainMB) MB free / \(part.totalMB) MB total")
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.muted)
                        }
                        ProgressView(value: Double(max(0, part.totalMB - part.remainMB)), total: Double(max(1, part.totalMB)))
                            .tint(Theme.sky)
                    }
                }
            } else {
                Text("No MicroSD storage details loaded yet (tap Load Camera Info).")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }

            Button("Format Camera MicroSD Card...", role: .destructive) {
                self.confirmFormatStep1 = true
            }
            .buttonStyle(.bordered)
            .alert("Format MicroSD Card?", isPresented: self.$confirmFormatStep1) {
                Button("Continue to Final Confirmation", role: .destructive) {
                    self.confirmFormatStep2 = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently erases all video recordings on the camera's MicroSD card.")
            }
            .alert("Final Confirmation: Erase MicroSD?", isPresented: self.$confirmFormatStep2) {
                Button("Erase & Format Now", role: .destructive) {
                    Task { await self.appState.formatMicroSD(for: camera) }
                }
                Button("Cancel", role: .cancel) {}
            }

            Divider().overlay(Theme.border)

            if let net = self.appState.dvripNetworkInfo {
                Text("LAN IP: \(net.hostIP) · Gateway: \(net.gateway) · MAC: \(net.mac)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
            }

            Toggle("Enable Xiongmai / iCSee Cloud P2P (NatEnable)", isOn: self.$cloudP2PEnabled)
            HStack(spacing: 10) {
                Button("Disable Cloud P2P (LAN-Only Lockdown)") {
                    self.cloudP2PEnabled = false
                    Task { await self.appState.setCloudP2PEnabled(false, for: camera) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)

                Button("Apply P2P Toggle") {
                    Task { await self.appState.setCloudP2PEnabled(self.cloudP2PEnabled, for: camera) }
                }
                .buttonStyle(.bordered)
            }

            Divider().overlay(Theme.border)

            HStack {
                SecureField("New camera password", text: self.$newPassword)
                    .textFieldStyle(.roundedBorder)
                Button("Change Password") {
                    let pwd = self.newPassword
                    guard !pwd.isEmpty else { return }
                    Task {
                        await self.appState.changeCameraPassword(for: camera, newPassword: pwd)
                        self.newPassword = ""
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int(value.wrappedValue))").font(.caption.monospaced())
            }
            Slider(value: value, in: 0...100, step: 1)
        }
    }
}
