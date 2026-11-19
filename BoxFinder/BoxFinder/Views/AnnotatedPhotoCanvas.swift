import SwiftUI
import UIKit

struct AnnotatedPhotoCanvas: View {
    let image: UIImage
    let objects: [DetectedObject]
    let showBoxes: Bool
    @Binding var selectedIndex: Int?
    @Binding var resetTrigger: Int
    @Binding var focusRequest: FocusRequest?

    struct FocusRequest: Equatable {
        let id = UUID()
        let index: Int
    }

    @State private var viewSize: CGSize = .zero
    @State private var transform = ImageFitTransform(scale: 1, left: 0, top: 0)
    @State private var fitTransform = ImageFitTransform(scale: 1, left: 0, top: 0)

    @State private var pinchStartTransform: ImageFitTransform?
    @State private var dragStartTransform: ImageFitTransform?

    var body: some View {
        GeometryReader { geometry in
            let currentSize = geometry.size
            let imageSize = image.size
            let drawWidth = imageSize.width * transform.scale
            let drawHeight = imageSize.height * transform.scale

            ZStack(alignment: .topLeading) {
                Color(red: 10/255, green: 18/255, blue: 27/255)

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: max(1, drawWidth), height: max(1, drawHeight))
                    .position(
                        x: transform.left + drawWidth / 2,
                        y: transform.top + drawHeight / 2
                    )

                if showBoxes {
                    ForEach(Array(objects.enumerated()), id: \.element.id) { index, object in
                        let rect = PhotoGeometry.screenBox(
                            box2d: object.box2d,
                            imageSize: imageSize,
                            transform: transform
                        )
                        if rect.width > 0,
                           rect.height > 0,
                           rect.intersects(CGRect(origin: .zero, size: currentSize)) {
                            let isSelected = (selectedIndex == index)
                            let color = BoxFinderTheme.detectionColor(forIndex: index, isSelected: isSelected)
                            let labelText = object.label + (object.uncertain ? " ?" : "")

                            Rectangle()
                                .strokeBorder(
                                    color,
                                    style: StrokeStyle(
                                        lineWidth: isSelected ? 4.0 : 2.5,
                                        dash: object.uncertain ? [8, 4] : []
                                    )
                                )
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)

                            let tagX = max(4, min(currentSize.width - 140, rect.minX))
                            let tagY = max(4, min(currentSize.height - 28, rect.minY - 26))

                            Text(labelText)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .foregroundColor(Color(red: 8/255, green: 20/255, blue: 30/255))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(color)
                                .cornerRadius(5)
                                .fixedSize()
                                .offset(x: tagX, y: tagY)
                        }
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Large photo viewer. Pinch to zoom, drag to pan, double-tap to zoom, or tap a detection box for its label.")
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchStartTransform == nil {
                            pinchStartTransform = transform
                        }
                        guard let start = pinchStartTransform else { return }
                        let newScale = max(fitTransform.scale, min(fitTransform.scale * 8, start.scale * value))
                        let focus = CGPoint(x: currentSize.width / 2, y: currentSize.height / 2)
                        let zoomed = PhotoGeometry.zoom(current: start, newScale: newScale, focus: focus)
                        transform = PhotoGeometry.clamp(transform: zoomed, imageSize: imageSize, viewSize: currentSize)
                    }
                    .onEnded { _ in
                        pinchStartTransform = nil
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if dragStartTransform == nil {
                            dragStartTransform = transform
                        }
                        guard let start = dragStartTransform else { return }
                        let panned = ImageFitTransform(
                            scale: start.scale,
                            left: start.left + value.translation.width,
                            top: start.top + value.translation.height
                        )
                        transform = PhotoGeometry.clamp(transform: panned, imageSize: imageSize, viewSize: currentSize)
                    }
                    .onEnded { _ in
                        dragStartTransform = nil
                    }
            )
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { tap in
                        if transform.scale > fitTransform.scale * 1.1 {
                            reset(for: currentSize)
                        } else {
                            let zoomed = PhotoGeometry.zoom(
                                current: transform,
                                newScale: fitTransform.scale * 2.2,
                                focus: tap.location
                            )
                            withAnimation(.easeOut(duration: 0.2)) {
                                transform = PhotoGeometry.clamp(transform: zoomed, imageSize: imageSize, viewSize: currentSize)
                            }
                        }
                    }
                    .exclusively(before:
                        SpatialTapGesture(count: 1)
                            .onEnded { tap in
                                guard showBoxes else { return }
                                selectedIndex = PhotoGeometry.hitTest(
                                    point: tap.location,
                                    objects: objects,
                                    imageSize: imageSize,
                                    transform: transform
                                )
                            }
                    )
            )
            .onAppear {
                viewSize = currentSize
                reset(for: currentSize)
            }
            .onChange(of: currentSize) { updatedSize in
                viewSize = updatedSize
                reset(for: updatedSize)
            }
            .onChange(of: image) { _ in
                reset(for: viewSize)
            }
            .onChange(of: resetTrigger) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    reset(for: viewSize)
                }
            }
            .onChange(of: focusRequest) { request in
                guard let request, objects.indices.contains(request.index) else { return }
                selectedIndex = request.index
                let focused = PhotoGeometry.focusTransform(
                    box2d: objects[request.index].box2d,
                    imageSize: imageSize,
                    viewSize: viewSize,
                    fitScale: fitTransform.scale
                )
                withAnimation(.easeOut(duration: 0.25)) {
                    transform = focused
                }
            }
        }
    }

    private func reset(for size: CGSize) {
        let fit = PhotoGeometry.fit(imageSize: image.size, viewSize: size)
        fitTransform = fit
        transform = fit
    }
}
