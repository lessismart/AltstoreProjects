import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("tapCount") private var tapCount = 0
    @AppStorage("selectedTheme") private var selectedTheme = 0
    @AppStorage("savedNote") private var savedNote = ""

    private let themes: [(name: String, color: Color)] = [
        ("Blue", .blue),
        ("Indigo", .indigo),
        ("Teal", .teal),
        ("Orange", .orange)
    ]

    private var activeColor: Color {
        themes.indices.contains(selectedTheme) ? themes[selectedTheme].color : .blue
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) (Build \(buildNumber))"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 20) {
                        verificationCard
                        diagnosticsCard(size: geometry.size)
                        persistenceCard
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("AltStore Test")
            .tint(activeColor)
        }
    }

    private var verificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text("AltStore Sideload Verified")
                        .font(.title3.weight(.bold))
                    Text("Running native SwiftUI build on iPadOS / iOS")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            diagnosticRow(label: "Bundle ID", value: bundleIdentifier)
            diagnosticRow(label: "Version", value: appVersion)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func diagnosticsCard(size: CGSize) -> some View {
        let device = UIDevice.current
        let viewport = "\(Int(size.width)) × \(Int(size.height)) pt"

        return VStack(alignment: .leading, spacing: 12) {
            Label("Device Diagnostics", systemImage: "ipad.and.iphone")
                .font(.headline)
                .foregroundColor(activeColor)

            Divider()

            diagnosticRow(label: "Device Name", value: device.name)
            diagnosticRow(label: "Model", value: device.model)
            diagnosticRow(label: "OS Version", value: "\(device.systemName) \(device.systemVersion)")
            diagnosticRow(label: "Live Viewport", value: viewport)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var persistenceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Interactive Persistence Test", systemImage: "externaldrive.badge.checkmark")
                .font(.headline)
                .foregroundColor(activeColor)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tap Counter")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(tapCount)")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(activeColor)
                }

                HStack(spacing: 10) {
                    Button {
                        tapCount += 1
                    } label: {
                        Text("+1")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        tapCount += 10
                    } label: {
                        Text("+10")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        tapCount = 0
                    } label: {
                        Text("Reset")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Accent Theme")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    ForEach(themes.indices, id: \.self) { index in
                        let theme = themes[index]
                        Button {
                            selectedTheme = index
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 12, height: 12)
                                Text(theme.name)
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedTheme == index
                                    ? theme.color.opacity(0.16)
                                    : Color(uiColor: .tertiarySystemGroupedBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        selectedTheme == index ? theme.color : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Persistent Note (AppStorage)")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)

                TextField("Type a note and relaunch the app to verify storage...", text: $savedNote)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func diagnosticRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
