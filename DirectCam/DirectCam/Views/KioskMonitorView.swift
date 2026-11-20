import SwiftUI

struct KioskMonitorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        if let camera = self.appState.selectedCamera {
                            let session = self.appState.session(for: camera)
                            ZStack(alignment: .topLeading) {
                                LiveVideoCanvas(session: session, showDetections: true)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(self.appState.kioskMonitoringActive ? Theme.green : Theme.border, lineWidth: 2)
                                    )

                                HStack(spacing: 8) {
                                    StatusChip(
                                        text: self.appState.kioskMonitoringActive ? "VISION MONITOR ACTIVE" : "STANDBY",
                                        color: self.appState.kioskMonitoringActive ? Theme.green : Theme.muted
                                    )
                                    if !session.detections.isEmpty {
                                        StatusChip(text: "\(session.detections.count) Target(s)", color: Theme.amber)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                            }
                        }

                        ControlCard("On-Device Apple Vision Kiosk Controls", accent: Theme.green) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(self.appState.kioskMonitoringActive ? "Monitoring Running (On-Device Neural Engine)" : "Monitor Paused")
                                        .font(.headline)
                                        .foregroundStyle(Theme.text)
                                    Text("Analyzes decoded video locally on this iPad/iPhone — no Raspberry Pi or cloud AI.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button {
                                    self.appState.toggleKioskMonitoring()
                                } label: {
                                    Label(self.appState.kioskMonitoringActive ? "Stop" : "Start Monitor",
                                          systemImage: self.appState.kioskMonitoringActive ? "pause.fill" : "shield.checkerboard")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.appState.kioskMonitoringActive ? Theme.rose : Theme.green)
                            }

                            Divider().overlay(Theme.border)

                            Toggle("Detect People (VNDetectHumanRectangles)", isOn: self.$appState.monitorSettings.detectHumans)
                                .onChange(of: self.appState.monitorSettings.detectHumans) { _ in self.appState.saveMonitorSettings() }
                            Toggle("Detect Pets & Animals (VNRecognizeAnimals)", isOn: self.$appState.monitorSettings.detectPets)
                                .onChange(of: self.appState.monitorSettings.detectPets) { _ in self.appState.saveMonitorSettings() }
                            Toggle("Keep Screen Awake in Kiosk Mode", isOn: self.$appState.monitorSettings.keepScreenAwakeInKiosk)
                                .onChange(of: self.appState.monitorSettings.keepScreenAwakeInKiosk) { _ in self.appState.saveMonitorSettings() }
                            Toggle("Play Alert Chime", isOn: self.$appState.monitorSettings.playChime)
                                .onChange(of: self.appState.monitorSettings.playChime) { _ in self.appState.saveMonitorSettings() }
                            Toggle("Send Local Notification Banner", isOn: self.$appState.monitorSettings.sendNotification)
                                .onChange(of: self.appState.monitorSettings.sendNotification) { _ in self.appState.saveMonitorSettings() }
                            Toggle("Auto-Record Local MP4 Clip on Alert", isOn: self.$appState.monitorSettings.autoRecordClip)
                                .onChange(of: self.appState.monitorSettings.autoRecordClip) { _ in self.appState.saveMonitorSettings() }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Min Confidence")
                                    Spacer()
                                    Text("\(Int(self.appState.monitorSettings.minConfidence * 100))%").monospacedDigit()
                                }
                                Slider(value: self.$appState.monitorSettings.minConfidence, in: 0.4...0.95, step: 0.05) { _ in
                                    self.appState.saveMonitorSettings()
                                }
                            }

                            Stepper("Cooldown: \(self.appState.monitorSettings.cooldownSeconds)s",
                                    value: self.$appState.monitorSettings.cooldownSeconds, in: 5...120, step: 5)
                                .onChange(of: self.appState.monitorSettings.cooldownSeconds) { _ in self.appState.saveMonitorSettings() }

                            Stepper("Auto-Clip Length: \(self.appState.monitorSettings.clipDurationSeconds)s",
                                    value: self.$appState.monitorSettings.clipDurationSeconds, in: 5...30, step: 5)
                                .onChange(of: self.appState.monitorSettings.clipDurationSeconds) { _ in self.appState.saveMonitorSettings() }
                        }

                        ControlCard("Alert Timeline (\(self.appState.alertEvents.count))", accent: Theme.amber) {
                            if self.appState.alertEvents.isEmpty {
                                Text("No local Vision alerts recorded yet.")
                                    .foregroundStyle(Theme.muted)
                            } else {
                                HStack {
                                    Spacer()
                                    Button("Clear History", role: .destructive) {
                                        self.appState.clearAlerts()
                                    }
                                    .font(.caption.bold())
                                }
                                ForEach(self.appState.alertEvents) { ev in
                                    HStack(spacing: 12) {
                                        if let rel = ev.snapshotRelativePath,
                                           let img = UIImage(contentsOfFile: self.appState.mediaStore.fileURL(forRelativePath: rel).path) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 84, height: 52)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(ev.kind.label) (\(Int(ev.confidence * 100))%)")
                                                .font(.subheadline.bold())
                                                .foregroundStyle(Theme.text)
                                            Text("\(ev.cameraName) · \(ev.timestamp.formatted(date: .abbreviated, time: .standard))")
                                                .font(.caption)
                                                .foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Smart Monitor")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
