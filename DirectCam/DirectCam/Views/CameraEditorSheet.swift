import SwiftUI

struct CameraEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let existingProfile: CameraProfile?

    @State private var name: String
    @State private var host: String
    @State private var username: String
    @State private var password: String
    @State private var rtspPort: Int
    @State private var onvifPort: Int
    @State private var dvripPort: Int
    @State private var channel: Int
    @State private var pathStyle: RTSPPathStyle
    @State private var preferredStream: StreamQuality
    @State private var customMainPath: String
    @State private var customSubPath: String
    @State private var probeResult: PortProbeResult?
    @State private var isProbing = false

    init(existingProfile: CameraProfile?, initialPassword: String = "") {
        self.existingProfile = existingProfile
        let base = existingProfile ?? CameraProfile()
        _name = State(initialValue: base.name)
        _host = State(initialValue: base.host)
        _username = State(initialValue: base.username)
        _password = State(initialValue: initialPassword)
        _rtspPort = State(initialValue: base.rtspPort)
        _onvifPort = State(initialValue: base.onvifPort)
        _dvripPort = State(initialValue: base.dvripPort)
        _channel = State(initialValue: base.channel)
        _pathStyle = State(initialValue: base.rtspPathStyle)
        _preferredStream = State(initialValue: base.preferredStream)
        _customMainPath = State(initialValue: base.customMainPath)
        _customSubPath = State(initialValue: base.customSubPath)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("LAN Auto-Discovery (No Pi Required)") {
                    Button {
                        Task { await self.appState.discoverLAN() }
                    } label: {
                        HStack {
                            Label(self.appState.isDiscovering ? "Scanning Wi-Fi..." : "Discover ONVIF Cameras", systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if self.appState.isDiscovering { ProgressView() }
                        }
                    }

                    ForEach(self.appState.discoveredCameras) { found in
                        Button {
                            self.host = found.host
                            self.onvifPort = found.onvifPort
                            if !found.name.isEmpty { self.name = found.name }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.name).font(.headline)
                                Text("\(found.host):\(found.onvifPort) \(found.hardware)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }

                Section("Camera Identity & Credentials") {
                    TextField("Name", text: self.$name)
                    TextField("Camera IP / Hostname", text: self.$host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: self.$username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Device Password", text: self.$password)
                    if !self.password.isEmpty {
                        Label("Password entered (\(self.password.count) characters) — stored on device when saved.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(Theme.teal)
                    } else {
                        Label("No device password saved yet.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                    }
                }

                Section("Direct Protocol Ports") {
                    Stepper("RTSP Port: \(self.rtspPort)", value: self.$rtspPort, in: 1...65535)
                    Stepper("ONVIF Port: \(self.onvifPort)", value: self.$onvifPort, in: 1...65535)
                    Stepper("DVRIP Port: \(self.dvripPort)", value: self.$dvripPort, in: 1...65535)
                    Stepper("Channel Index: \(self.channel)", value: self.$channel, in: 0...16)

                    Button {
                        Task {
                            self.isProbing = true
                            self.probeResult = await NetworkScanner.probeCameraPorts(
                                host: self.host,
                                rtspPort: self.rtspPort,
                                onvifPort: self.onvifPort,
                                dvripPort: self.dvripPort
                            )
                            self.isProbing = false
                        }
                    } label: {
                        HStack {
                            Label(self.isProbing ? "Probing Ports..." : "Test Direct Port Reachability", systemImage: "network")
                            Spacer()
                            if self.isProbing { ProgressView() }
                        }
                    }

                    if let probe = self.probeResult {
                        HStack(spacing: 8) {
                            StatusChip(text: "RTSP :\(self.rtspPort)", color: probe.rtspOpen ? Theme.green : Theme.rose)
                            StatusChip(text: "ONVIF :\(self.onvifPort)", color: probe.onvifOpen ? Theme.green : Theme.amber)
                            StatusChip(text: "DVRIP :\(self.dvripPort)", color: probe.dvripOpen ? Theme.green : Theme.amber)
                        }
                    }
                }

                Section("RTSP Stream Format") {
                    Picker("Default Stream", selection: self.$preferredStream) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    Picker("RTSP URL Style", selection: self.$pathStyle) {
                        ForEach(RTSPPathStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    if self.pathStyle == .custom {
                        TextField("Main Path (/stream1)", text: self.$customMainPath)
                            .textInputAutocapitalization(.never)
                        TextField("Sub Path (/stream2)", text: self.$customSubPath)
                            .textInputAutocapitalization(.never)
                    }
                }

                if let existing = self.existingProfile, self.appState.cameras.count > 1 {
                    Section {
                        Button("Delete Camera", role: .destructive) {
                            self.appState.deleteCamera(existing)
                            self.dismiss()
                        }
                    }
                }
            }
            .navigationTitle(self.existingProfile == nil ? "Add Direct Camera" : "Edit Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        self.saveProfile()
                    }
                    .disabled(self.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveProfile() {
        var profile = self.existingProfile ?? CameraProfile()
        profile.name = self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.host : self.name
        profile.host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.rtspPort = self.rtspPort
        profile.onvifPort = self.onvifPort
        profile.dvripPort = self.dvripPort
        profile.channel = self.channel
        profile.rtspPathStyle = self.pathStyle
        profile.preferredStream = self.preferredStream
        profile.customMainPath = self.customMainPath
        profile.customSubPath = self.customSubPath

        self.appState.upsertCamera(profile, password: self.password)
        self.dismiss()
    }
}
