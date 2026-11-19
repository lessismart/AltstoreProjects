import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScannedPayload: (String) -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var manualCode = ""
    @State private var errorMessage: String?
    @State private var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        cameraSection
                    } else {
                        infoBanner("Camera hardware is unavailable in this environment (such as Simulator). Choose a QR label image or enter the box code below.")
                    }

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Choose QR Image from Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or Enter Box Code")
                            .font(.headline)
                        HStack {
                            TextField("e.g. BX-0001", text: $manualCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Button("Open") {
                                let trimmed = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                onScannedPayload(trimmed)
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding()
                    .background(BoxFinderTheme.cardBackground)
                    .cornerRadius(14)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
            .background(BoxFinderTheme.pageBackground)
            .navigationTitle("Scan Box QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: selectedPhotoItem) { newItem in
                guard let newItem else { return }
                Task {
                    do {
                        guard let data = try await newItem.loadTransferable(type: Data.self) else {
                            errorMessage = QRScanError.unreadableImage.localizedDescription
                            return
                        }
                        let payload = try QRCodeService.decodeQRPayload(fromImageData: data)
                        onScannedPayload(payload)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        switch cameraStatus {
        case .authorized:
            LiveCameraQRView { code in
                onScannedPayload(code)
                dismiss()
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(BoxFinderTheme.accent, lineWidth: 2)
            )
        case .notDetermined:
            VStack(spacing: 12) {
                Text("Box Finder needs camera access to scan printed QR labels directly.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Enable Camera Scanner") {
                    Task {
                        let granted = await AVCaptureDevice.requestAccess(for: .video)
                        await MainActor.run {
                            cameraStatus = granted ? .authorized : .denied
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(BoxFinderTheme.cardBackground)
            .cornerRadius(14)
        case .denied, .restricted:
            VStack(spacing: 10) {
                Text("Camera access is disabled. You can allow Camera in Settings or choose a QR image below.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open iOS Settings", destination: settingsURL)
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(BoxFinderTheme.cardBackground)
            .cornerRadius(14)
        @unknown default:
            EmptyView()
        }
    }

    private func infoBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(BoxFinderTheme.cardBackground)
            .cornerRadius(14)
    }
}

private struct LiveCameraQRView: UIViewControllerRepresentable {
    let onDetected: (String) -> Void

    func makeUIViewController(context: Context) -> LiveCameraQRController {
        let controller = LiveCameraQRController()
        controller.onDetected = onDetected
        return controller
    }

    func updateUIViewController(_ uiViewController: LiveCameraQRController, context: Context) {}
}

private final class LiveCameraQRController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onDetected: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDelivered = false
    private let sessionQueue = DispatchQueue(label: "com.lessy.boxfinder.qr-camera")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        self.previewLayer = layer
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDelivered,
              let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = readable.stringValue,
              !value.isEmpty else {
            return
        }
        hasDelivered = true
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        onDetected?(value)
    }
}
