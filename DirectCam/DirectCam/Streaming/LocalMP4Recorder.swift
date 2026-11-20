import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class LocalMP4Recorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedSession = false
    private var frameIndex: Int64 = 0
    private(set) var outputURL: URL?
    private(set) var isRecording = false

    func start(outputURL: URL, width: Int, height: Int, realTime: Bool = true) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let w = max(64, width)
        let h = max(64, height)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = realTime
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttrs
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "DirectCam.Recorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot attach H.264 video writer input."
            ])
        }
        writer.add(input)
        writer.startWriting()

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.startedSession = false
        self.frameIndex = 0
        self.outputURL = outputURL
        self.isRecording = true
    }

    func append(pixelBuffer: CVPixelBuffer, fps: Int = 15) {
        guard self.isRecording, let writer = self.writer, let input = self.input, let adaptor = self.adaptor else {
            return
        }
        if !self.startedSession {
            writer.startSession(atSourceTime: .zero)
            self.startedSession = true
        }
        guard input.isReadyForMoreMediaData else { return }
        let pts = CMTime(value: self.frameIndex * 1000, timescale: CMTimeScale(max(1, fps) * 1000))
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            self.frameIndex += 1
        }
    }

    func finish() async -> URL? {
        guard self.isRecording, let writer = self.writer else { return nil }
        self.isRecording = false
        let out = self.outputURL
        self.input?.markAsFinished()
        await writer.finishWriting()
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        return writer.status == .completed ? out : nil
    }

    /// Converts downloaded Xiongmai raw Annex-B video frames into a playable `.mp4` file.
    static func remuxAnnexBToMP4(annexBData: Data, isHEVC: Bool, outputURL: URL) async throws -> URL {
        let nalUnits = RTPVideoDepacketizer.splitAnnexBNALUnits(annexBData)
        guard !nalUnits.isEmpty else {
            throw NSError(domain: "DirectCam.Recorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded camera recording contained no video NAL units."
            ])
        }
        let codec: RTSPVideoCodec = isHEVC ? .hevc : .h264
        let decoder = VideoToolboxDecoder(codec: codec)
        let recorder = LocalMP4Recorder()
        var started = false

        var batch: [Data] = []
        var pendingVPS: Data?
        var pendingSPS: Data?
        var pendingPPS: Data?
        var isKey = false

        func flushAccessUnit() throws {
            guard !batch.isEmpty else { return }
            let unit = RTPVideoUnit(nalUnits: batch, vps: pendingVPS, sps: pendingSPS, pps: pendingPPS, isKeyFrame: isKey, timestamp: 0)
            batch.removeAll()
            isKey = false
            guard let frame = decoder.decode(unit: unit), let pb = frame.pixelBuffer else { return }
            if !started {
                try recorder.start(
                    outputURL: outputURL,
                    width: CVPixelBufferGetWidth(pb),
                    height: CVPixelBufferGetHeight(pb),
                    realTime: false
                )
                started = true
            }
            recorder.append(pixelBuffer: pb, fps: 15)
        }

        for nalu in nalUnits where !nalu.isEmpty {
            if codec == .hevc {
                let t = (nalu[0] >> 1) & 0x3F
                if t == 32 { pendingVPS = nalu; continue }
                if t == 33 { pendingSPS = nalu; continue }
                if t == 34 { pendingPPS = nalu; continue }
                if (16...21).contains(t) { isKey = true }
                batch.append(nalu)
                try flushAccessUnit()
            } else {
                let t = nalu[0] & 0x1F
                if t == 7 { pendingSPS = nalu; continue }
                if t == 8 { pendingPPS = nalu; continue }
                if t == 5 { isKey = true }
                batch.append(nalu)
                try flushAccessUnit()
            }
        }
        try flushAccessUnit()

        if let finishedURL = await recorder.finish(), started {
            return finishedURL
        }
        throw NSError(domain: "DirectCam.Recorder", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Could not convert camera stream into MP4."
        ])
    }
}
