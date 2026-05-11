import Foundation

/// Parses E352-format wavetable WAVs. Audio payload is a power-of-two
/// count of 256-sample mono PCM16 frames concatenated end-to-end.
/// Standard frame counts: 32, 64, 128, 256. Sample rate isn't enforced
/// (44.1k is common); what matters is the 256-sample frame layout.
///
/// Port of inet.modular's wavetable-parser.ts. Throws on malformed
/// RIFF/WAVE, non-PCM, non-mono, non-16-bit, or audio length not a
/// multiple of 256 samples.
enum E352WavetableParser {
    static let frameSize = 256

    struct ParsedTable {
        let frames: [[Float]]   // [frameCount][256] in -1..+1
        let sampleRate: Int
        let bitsPerSample: Int
    }

    enum ParseError: Error, CustomStringConvertible {
        case tooShort
        case missingRIFF, missingWAVE, missingDATA
        case unsupportedFormat(code: Int)
        case unsupportedChannels(Int)
        case unsupportedDepth(Int)
        case sampleCountNotFrameAligned(samples: Int)
        case empty

        var description: String {
            switch self {
            case .tooShort: return "WAV too short"
            case .missingRIFF: return "missing RIFF header"
            case .missingWAVE: return "missing WAVE header"
            case .missingDATA: return "missing data chunk"
            case .unsupportedFormat(let code): return "expected PCM (1), got format \(code)"
            case .unsupportedChannels(let n): return "expected mono, got \(n) channels"
            case .unsupportedDepth(let bits): return "expected 16-bit PCM, got \(bits)-bit"
            case .sampleCountNotFrameAligned(let s): return "sample count \(s) not divisible by 256"
            case .empty: return "empty data chunk"
            }
        }
    }

    static func parse(data: Data) throws -> ParsedTable {
        guard data.count >= 44 else { throw ParseError.tooShort }
        try checkAscii(data, offset: 0, expected: "RIFF") { ParseError.missingRIFF }
        try checkAscii(data, offset: 8, expected: "WAVE") { ParseError.missingWAVE }

        var audioFormat: Int = 0
        var channels: Int = 0
        var sampleRate: Int = 0
        var bitsPerSample: Int = 0
        var dataOffset: Int = -1
        var dataLength: Int = -1

        var off = 12
        while off + 8 <= data.count {
            let id = ascii(data, offset: off, length: 4)
            let size = Int(le32(data, offset: off + 4))
            if id == "fmt " {
                audioFormat = Int(le16(data, offset: off + 8))
                channels = Int(le16(data, offset: off + 10))
                sampleRate = Int(le32(data, offset: off + 12))
                bitsPerSample = Int(le16(data, offset: off + 22))
            } else if id == "data" {
                dataOffset = off + 8
                dataLength = size
                break
            }
            off += 8 + size + (size & 1)
        }

        guard dataOffset >= 0 else { throw ParseError.missingDATA }
        guard audioFormat == 1 else { throw ParseError.unsupportedFormat(code: audioFormat) }
        guard channels == 1 else { throw ParseError.unsupportedChannels(channels) }
        guard bitsPerSample == 16 else { throw ParseError.unsupportedDepth(bitsPerSample) }

        let bytesPerSample = bitsPerSample / 8
        let totalSamples = dataLength / bytesPerSample
        guard totalSamples > 0 else { throw ParseError.empty }
        guard totalSamples % frameSize == 0 else {
            throw ParseError.sampleCountNotFrameAligned(samples: totalSamples)
        }

        let frameCount = totalSamples / frameSize
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)
        for f in 0..<frameCount {
            var frame = [Float](repeating: 0, count: frameSize)
            for s in 0..<frameSize {
                let byteOff = dataOffset + (f * frameSize + s) * bytesPerSample
                let raw = Int16(bitPattern: le16(data, offset: byteOff))
                frame[s] = raw < 0 ? Float(raw) / 32768.0 : Float(raw) / 32767.0
            }
            frames.append(frame)
        }

        return ParsedTable(frames: frames, sampleRate: sampleRate, bitsPerSample: bitsPerSample)
    }

    // MARK: - Helpers

    private static func ascii(_ data: Data, offset: Int, length: Int) -> String {
        let slice = data[offset..<(offset + length)]
        return String(bytes: slice, encoding: .ascii) ?? ""
    }

    private static func checkAscii(_ data: Data, offset: Int, expected: String,
                                   error: () -> ParseError) throws {
        if ascii(data, offset: offset, length: expected.count) != expected {
            throw error()
        }
    }

    private static func le16(_ data: Data, offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private static func le32(_ data: Data, offset: Int) -> UInt32 {
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
