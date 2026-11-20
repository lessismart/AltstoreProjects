import AVFoundation
import SwiftUI

private final class SampleBufferContainerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        self.backgroundColor = .black
        self.layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.displayLayer.frame = self.bounds
        CATransaction.commit()
    }
}

struct SampleBufferDisplayView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        SampleBufferContainerView(displayLayer: self.displayLayer)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct LiveVideoCanvas: View {
    @ObservedObject var session: RTSPStreamSession
    let showDetections: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if self.session.isConnected {
                    SampleBufferDisplayView(displayLayer: self.session.displayLayer)
                } else if let img = self.session.latestImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: self.session.isConnecting ? "antenna.radiowaves.left.and.right" : "video.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(self.session.isConnecting ? Theme.sky : Theme.muted)
                        Text(self.session.statusText)
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        if let err = self.session.lastError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(Theme.rose)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                }

                if self.showDetections && !self.session.detections.isEmpty {
                    ForEach(self.session.detections) { box in
                        let rect = box.normalizedRectTopLeft
                        let boxW = rect.width * geo.size.width
                        let boxH = rect.height * geo.size.height
                        let x = rect.x * geo.size.width + boxW / 2
                        let y = rect.y * geo.size.height + boxH / 2
                        let strokeColor = box.kind == .human ? Theme.green : Theme.amber

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(strokeColor, lineWidth: 2.5)
                                .frame(width: max(20, boxW), height: max(20, boxH))
                            Text("\(box.kind.label) \(Int(box.confidence * 100))%")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(strokeColor)
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .offset(y: -18)
                        }
                        .position(x: x, y: y)
                    }
                }
            }
            .scaleEffect(self.scale)
            .offset(self.offset)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        self.scale = max(1.0, min(5.0, self.lastScale * val))
                    }
                    .onEnded { _ in
                        self.lastScale = self.scale
                        if self.scale <= 1.02 {
                            self.scale = 1.0
                            self.lastScale = 1.0
                            self.offset = .zero
                            self.lastOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { val in
                        guard self.scale > 1.05 else { return }
                        self.offset = CGSize(
                            width: self.lastOffset.width + val.translation.width,
                            height: self.lastOffset.height + val.translation.height
                        )
                    }
                    .onEnded { _ in
                        self.lastOffset = self.offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.scale = 1.0
                    self.lastScale = 1.0
                    self.offset = .zero
                    self.lastOffset = .zero
                }
            }
        }
    }
}
