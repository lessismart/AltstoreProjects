import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

struct DecodedVideoFrame {
    var sampleBuffer: CMSampleBuffer
    var pixelBuffer: CVPixelBuffer?
    var dimensions: CGSize
    var isKeyFrame: Bool
}

private final class DecodeBox {
    var pixelBuffer: CVPixelBuffer?
}

final class VideoToolboxDecoder {
    private let codec: RTSPVideoCodec
    private let ciContext = CIContext(options: nil)
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var frameCounter: Int64 = 0

    init(codec: RTSPVideoCodec, vps: Data? = nil, sps: Data? = nil, pps: Data? = nil) {
        self.codec = codec
        self.vps = vps
        self.sps = sps
        self.pps = pps
        self.rebuildFormatIfReady()
    }

    deinit {
        if let session = self.decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func updateParameterSets(vps: Data?, sps: Data?, pps: Data?) {
        var changed = false
        if let vps, vps != self.vps { self.vps = vps; changed = true }
        if let sps, sps != self.sps { self.sps = sps; changed = true }
        if let pps, pps != self.pps { self.pps = pps; changed = true }
        if changed {
            self.rebuildFormatIfReady()
        }
    }

    func decode(unit: RTPVideoUnit) -> DecodedVideoFrame? {
        self.updateParameterSets(vps: unit.vps, sps: unit.sps, pps: unit.pps)
        guard let fmt = self.formatDescription, !unit.nalUnits.isEmpty else {
            return nil
        }

        let avccData = RTPVideoDepacketizer.avccLengthPrefixedData(from: unit.nalUnits)
        guard !avccData.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        let dataCount = avccData.count
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = avccData.withUnsafeBytes { rawPtr -> OSStatus in
            guard let base = rawPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let pts = CMTime(value: self.frameCounter * 1000, timescale: 30000)
        self.frameCounter += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1000, timescale: 30000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = dataCount
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return nil }

        let dim = CMVideoFormatDescriptionGetDimensions(fmt)
        var decodedPixelBuffer: CVPixelBuffer?

        if let session = self.decompressionSession {
            let box = DecodeBox()
            let boxPtr = Unmanaged.passRetained(box).toOpaque()
            var infoFlags = VTDecodeInfoFlags()
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                frameRefcon: boxPtr,
                infoFlagsOut: &infoFlags
            )
            if decodeStatus == noErr {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                decodedPixelBuffer = box.pixelBuffer
            } else {
                Unmanaged<DecodeBox>.fromOpaque(boxPtr).release()
            }
        }

        return DecodedVideoFrame(
            sampleBuffer: sampleBuffer,
            pixelBuffer: decodedPixelBuffer,
            dimensions: CGSize(width: Int(dim.width), height: Int(dim.height)),
            isKeyFrame: unit.isKeyFrame
        )
    }

    func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }

    private func rebuildFormatIfReady() {
        var newFormat: CMVideoFormatDescription?
        switch self.codec {
        case .hevc:
            guard let vps = self.vps, let sps = self.sps, let pps = self.pps else { return }
            let paramArrays = [vps, sps, pps]
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            for d in paramArrays {
                let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
                d.copyBytes(to: ptr, count: d.count)
                pointers.append(UnsafePointer(ptr))
                sizes.append(d.count)
            }
            defer { pointers.forEach { $0.deallocate() } }
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 3,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &newFormat
            )
        case .h264:
            guard let sps = self.sps, let pps = self.pps else { return }
            let paramArrays = [sps, pps]
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            for d in paramArrays {
                let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
                d.copyBytes(to: ptr, count: d.count)
                pointers.append(UnsafePointer(ptr))
                sizes.append(d.count)
            }
            defer { pointers.forEach { $0.deallocate() } }
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &newFormat
            )
        }

        guard let newFormat else { return }
        if let existing = self.formatDescription, CMFormatDescriptionEqual(existing, otherFormatDescription: newFormat) {
            return
        }
        self.formatDescription = newFormat
        if let oldSession = self.decompressionSession {
            VTDecompressionSessionInvalidate(oldSession)
            self.decompressionSession = nil
        }

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { _, sourceFrameRefCon, status, _, imageBuffer, _, _ in
                guard let sourceFrameRefCon else { return }
                let box = Unmanaged<DecodeBox>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
                if status == noErr, let imageBuffer {
                    box.pixelBuffer = imageBuffer
                }
            },
            decompressionOutputRefCon: nil
        )
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        if status == noErr {
            self.decompressionSession = session
        }
    }
}
