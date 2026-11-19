import Foundation
import zlib

enum GzipError: LocalizedError, Sendable {
    case compressionFailed(Int32)
    case decompressionFailed(Int32)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .compressionFailed(let code):
            return "Could not compress sync payload (zlib \(code))."
        case .decompressionFailed(let code):
            return "Could not decompress sync response (zlib \(code))."
        case .outputTooLarge:
            return "Sync data is too large."
        }
    }
}

enum GzipCodec {
    private static let chunkSize = 16_384

    static func compress(_ data: Data) throws -> Data {
        if data.isEmpty {
            var stream = z_stream()
            let initStatus = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                15 + 16,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw GzipError.compressionFailed(initStatus)
            }
            defer { deflateEnd(&stream) }
            var out = Data(count: 64)
            var finishStatus: Int32 = Z_OK
            let outCount = out.count
            out.withUnsafeMutableBytes { outPtr in
                stream.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outCount)
                finishStatus = deflate(&stream, Z_FINISH)
            }
            guard finishStatus == Z_STREAM_END else {
                throw GzipError.compressionFailed(finishStatus)
            }
            out.count = Int(stream.total_out)
            return out
        }

        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw GzipError.compressionFailed(initStatus)
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBytes { chunkPtr in
                    stream.next_out = chunkPtr.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: chunk[0..<produced])
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw GzipError.compressionFailed(status)
            }
        }
        return output
    }

    static func decompress(_ data: Data, maxBytes: Int = 70_000_000) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw GzipError.decompressionFailed(initStatus)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBytes { chunkPtr in
                    stream.next_out = chunkPtr.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    if output.count + produced > maxBytes {
                        throw GzipError.outputTooLarge
                    }
                    output.append(contentsOf: chunk[0..<produced])
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw GzipError.decompressionFailed(status)
            }
        }
        return output
    }
}
