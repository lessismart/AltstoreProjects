import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit
import Vision

enum QRScanError: LocalizedError, Sendable {
    case unreadableImage
    case noCodeFound
    case invalidCode(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Could not decode the selected image."
        case .noCodeFound:
            return "No QR code was found in this image."
        case .invalidCode(let raw):
            return "QR code '\(raw)' is not a Box Finder box label."
        }
    }
}

enum QRResolutionTarget: Equatable, Sendable {
    case boxCode(String)
    case boxID(Int64)
}

enum QRCodeService {
    /// Parses plain box codes (`BX-0001`) as well as Pi label URLs (`.../box-finder.php?box=12` or `box-finder-plus.php?box=12`).
    static func parsePayload(_ rawValue: String) -> QRResolutionTarget? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let regex = try? NSRegularExpression(pattern: "^BX-\\d{1,9}$", options: [.caseInsensitive]),
           regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            return .boxCode(trimmed.uppercased())
        }

        if let embeddedCodeRegex = try? NSRegularExpression(pattern: "BX-\\d{1,9}", options: [.caseInsensitive]),
           let match = embeddedCodeRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
           let range = Range(match.range, in: trimmed),
           URL(string: trimmed)?.scheme == nil {
            return .boxCode(String(trimmed[range]).uppercased())
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        let path = components.path.lowercased()
        guard path.hasSuffix("/box-finder.php") || path.hasSuffix("/box-finder-plus.php") || path == "box-finder.php" || path == "box-finder-plus.php" else {
            return nil
        }
        if let rawBox = components.queryItems?.first(where: { $0.name == "box" })?.value,
           let id = Int64(rawBox),
           id > 0 {
            return .boxID(id)
        }
        return nil
    }

    static func resolveBox(from payload: String, in boxes: [BoxRecord]) -> BoxRecord? {
        guard let target = parsePayload(payload) else { return nil }
        switch target {
        case .boxCode(let code):
            return boxes.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
        case .boxID(let id):
            let formatted = SQLiteBoxDatabase.formatBoxCode(for: id)
            return boxes.first { $0.code.caseInsensitiveCompare(formatted) == .orderedSame }
                ?? boxes.first { $0.id == id }
        }
    }

    static func generateQRImage(for content: String, size: CGFloat = 700) -> UIImage? {
        guard let data = content.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let moduleDimension = max(extent.width, extent.height)
        let scale = max(1, floor(size / (moduleDimension + 8)))
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }

        let quietZone = scale * 4
        let canvasSize = CGSize(width: scaled.extent.width + quietZone * 2, height: scaled.extent.height + quietZone * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            ctx.cgContext.interpolationQuality = .none
            UIImage(cgImage: cgImage).draw(in: CGRect(
                x: quietZone,
                y: quietZone,
                width: scaled.extent.width,
                height: scaled.extent.height
            ))
        }
    }

    static func renderPrintableLabelCard(for box: BoxRecord) -> UIImage? {
        guard let qr = generateQRImage(for: box.code, size: 520) else { return nil }
        let cardSize = CGSize(width: 760, height: 920)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: cardSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: cardSize))

            let borderRect = CGRect(x: 24, y: 24, width: cardSize.width - 48, height: cardSize.height - 48)
            let borderPath = UIBezierPath(roundedRect: borderRect, cornerRadius: 28)
            UIColor(red: 220/255, green: 229/255, blue: 234/255, alpha: 1).setStroke()
            borderPath.lineWidth = 4
            borderPath.stroke()

            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            let codeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor(red: 13/255, green: 111/255, blue: 120/255, alpha: 1),
                .paragraphStyle: titleStyle
            ]
            NSString(string: box.code).draw(in: CGRect(x: 48, y: 54, width: cardSize.width - 96, height: 56), withAttributes: codeAttrs)

            let qrSize: CGFloat = 520
            let qrRect = CGRect(x: (cardSize.width - qrSize) / 2, y: 128, width: qrSize, height: qrSize)
            ctx.cgContext.interpolationQuality = .none
            qr.draw(in: qrRect)

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: UIColor(red: 22/255, green: 40/255, blue: 60/255, alpha: 1),
                .paragraphStyle: titleStyle
            ]
            NSString(string: box.name).draw(in: CGRect(x: 52, y: 676, width: cardSize.width - 104, height: 96), withAttributes: nameAttrs)

            let locAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .regular),
                .foregroundColor: UIColor(red: 96/255, green: 115/255, blue: 132/255, alpha: 1),
                .paragraphStyle: titleStyle
            ]
            NSString(string: box.location).draw(in: CGRect(x: 52, y: 780, width: cardSize.width - 104, height: 72), withAttributes: locAttrs)
        }
    }

    static func decodeQRPayload(fromImageData data: Data) throws -> String {
        guard let image = UIImage(data: data) else {
            throw QRScanError.unreadableImage
        }
        return try decodeQRPayload(from: image)
    }

    static func decodeQRPayload(from image: UIImage) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 2400 ? 2400 / longest : 1.0
        let targetSize = CGSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        let upright = UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let cgImage = upright.cgImage else {
            throw QRScanError.unreadableImage
        }

        // Software CoreImage QR detector works deterministically on headless Simulators as well as devices.
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        if let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: ciContext,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) {
            let ciImage = CIImage(cgImage: cgImage)
            let features = detector.features(in: ciImage)
            if let payload = features
                .compactMap({ ($0 as? CIQRCodeFeature)?.messageString })
                .first(where: { !$0.isEmpty }) {
                return payload
            }
        }

        // Fallback to Vision for perspective-distorted or tilted camera captures.
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        if (try? handler.perform([request])) != nil,
           let match = request.results?.first(where: { !($0.payloadStringValue ?? "").isEmpty }),
           let payload = match.payloadStringValue {
            return payload
        }
        throw QRScanError.noCodeFound
    }
}
