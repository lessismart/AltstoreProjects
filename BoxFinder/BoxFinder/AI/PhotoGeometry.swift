import CoreGraphics
import Foundation

struct ImageFitTransform: Equatable, Sendable {
    var scale: CGFloat
    var left: CGFloat
    var top: CGFloat
}

enum PhotoGeometry {
    static func fit(imageSize: CGSize, viewSize: CGSize) -> ImageFitTransform {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return ImageFitTransform(scale: 1, left: 0, top: 0)
        }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let left = (viewSize.width - imageSize.width * scale) / 2
        let top = (viewSize.height - imageSize.height * scale) / 2
        return ImageFitTransform(scale: scale, left: left, top: top)
    }

    /// Converts normalized [ymin, xmin, ymax, xmax] (0...1000) into view coordinates under `transform`.
    static func screenBox(
        box2d: [Double],
        imageSize: CGSize,
        transform: ImageFitTransform
    ) -> CGRect {
        guard box2d.count == 4 else { return .zero }
        let x1 = transform.left + CGFloat(box2d[1]) / 1000.0 * imageSize.width * transform.scale
        let y1 = transform.top + CGFloat(box2d[0]) / 1000.0 * imageSize.height * transform.scale
        let x2 = transform.left + CGFloat(box2d[3]) / 1000.0 * imageSize.width * transform.scale
        let y2 = transform.top + CGFloat(box2d[2]) / 1000.0 * imageSize.height * transform.scale
        return CGRect(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1))
    }

    static func zoom(
        current: ImageFitTransform,
        newScale: CGFloat,
        focus: CGPoint
    ) -> ImageFitTransform {
        guard current.scale > 0 else { return current }
        let ratio = newScale / current.scale
        let newLeft = focus.x - (focus.x - current.left) * ratio
        let newTop = focus.y - (focus.y - current.top) * ratio
        return ImageFitTransform(scale: newScale, left: newLeft, top: newTop)
    }

    static func clamp(
        transform: ImageFitTransform,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> ImageFitTransform {
        let width = imageSize.width * transform.scale
        let height = imageSize.height * transform.scale
        let clampedLeft: CGFloat = width <= viewSize.width
            ? (viewSize.width - width) / 2
            : max(viewSize.width - width, min(0, transform.left))
        let clampedTop: CGFloat = height <= viewSize.height
            ? (viewSize.height - height) / 2
            : max(viewSize.height - height, min(0, transform.top))
        return ImageFitTransform(scale: transform.scale, left: clampedLeft, top: clampedTop)
    }

    static func focusTransform(
        box2d: [Double],
        imageSize: CGSize,
        viewSize: CGSize,
        fitScale: CGFloat,
        maxZoomMultiplier: CGFloat = 8.0
    ) -> ImageFitTransform {
        guard box2d.count == 4, imageSize.width > 0, imageSize.height > 0 else {
            return fit(imageSize: imageSize, viewSize: viewSize)
        }
        let boxWidth = max(1, CGFloat(box2d[3] - box2d[1]) / 1000.0 * imageSize.width)
        let boxHeight = max(1, CGFloat(box2d[2] - box2d[0]) / 1000.0 * imageSize.height)
        let targetScale = max(
            fitScale,
            min(fitScale * maxZoomMultiplier, min(viewSize.width * 0.7 / boxWidth, viewSize.height * 0.7 / boxHeight))
        )
        let centerXNorm = CGFloat(box2d[1] + box2d[3]) / 2000.0
        let centerYNorm = CGFloat(box2d[0] + box2d[2]) / 2000.0
        let raw = ImageFitTransform(
            scale: targetScale,
            left: viewSize.width / 2.0 - centerXNorm * imageSize.width * targetScale,
            top: viewSize.height / 2.0 - centerYNorm * imageSize.height * targetScale
        )
        return clamp(transform: raw, imageSize: imageSize, viewSize: viewSize)
    }

    /// Returns index of the smallest-area box containing `point` in view coordinates.
    static func hitTest(
        point: CGPoint,
        objects: [DetectedObject],
        imageSize: CGSize,
        transform: ImageFitTransform
    ) -> Int? {
        var bestIndex: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (idx, object) in objects.enumerated() {
            let rect = screenBox(box2d: object.box2d, imageSize: imageSize, transform: transform)
            if rect.contains(point) {
                let area = rect.width * rect.height
                if area < bestArea {
                    bestArea = area
                    bestIndex = idx
                }
            }
        }
        return bestIndex
    }
}
