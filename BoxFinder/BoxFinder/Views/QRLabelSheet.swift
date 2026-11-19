import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PNGImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct QRLabelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let box: BoxRecord

    @State private var labelImage: UIImage?
    @State private var pngDocument = PNGImageDocument()
    @State private var showExporter = false
    @State private var notice: AlertNotice?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let labelImage {
                        Image(uiImage: labelImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 340)
                            .cornerRadius(16)
                            .shadow(radius: 4)
                    }

                    Text("QR code stores exact box code \(box.code), compatible with Box Finder on iOS, Android and Raspberry Pi.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        if let labelImage {
                            ShareLink(
                                item: Image(uiImage: labelImage),
                                preview: SharePreview("\(box.code) QR Label", image: Image(uiImage: labelImage))
                            ) {
                                Label("Share Label Image", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button {
                            guard let data = labelImage?.pngData() else { return }
                            pngDocument = PNGImageDocument(data: data)
                            showExporter = true
                        } label: {
                            Label("Save PNG to Files", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            printLabel()
                        } label: {
                            Label("Print Label", systemImage: "printer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .background(BoxFinderTheme.pageBackground)
            .navigationTitle("\(box.code) · QR Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                labelImage = QRCodeService.renderPrintableLabelCard(for: box)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: pngDocument,
                contentType: .png,
                defaultFilename: "\(box.code)-qr.png"
            ) { result in
                if case .success = result {
                    notice = AlertNotice(title: "QR Saved", message: "The QR label PNG was saved.")
                }
            }
            .alert(item: $notice) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func printLabel() {
        guard let image = labelImage, UIPrintInteractionController.isPrintingAvailable else {
            notice = AlertNotice(title: "Printing unavailable", message: "No printer interface is available on this device.")
            return
        }
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.jobName = "\(box.code) QR Label"
        printInfo.outputType = .general

        let controller = UIPrintInteractionController.shared
        controller.printInfo = printInfo
        controller.printingItem = image
        controller.present(animated: true, completionHandler: nil)
    }
}
