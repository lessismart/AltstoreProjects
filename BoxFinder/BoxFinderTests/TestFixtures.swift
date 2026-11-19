import UIKit

enum TestFixtures {
    static func makeSolidJPEGData(color: UIColor = .systemTeal, size: CGSize = CGSize(width: 240, height: 180)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 20, y: 20, width: size.width * 0.4, height: size.height * 0.4))
        }
        return image.jpegData(compressionQuality: 0.85)!
    }

    static func makeTempDir(name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoxFinderTests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
