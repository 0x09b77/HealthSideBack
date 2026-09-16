import Foundation

/// Dependency-free image inspection: reads dimensions from header bytes and
/// strips metadata, without decoding the image or pulling in a native image
/// library (libheif/ImageMagick had a poor CVE history — doc §4/§5).
///
/// Header parsing covers PNG and JPEG. HEIC is left untouched (its boxes are
/// awkward to parse safely without a library); per doc §4 the iOS client is
/// expected to convert HEIC → JPEG before upload, and the 20 MB size cap still
/// applies as a backstop.
enum ImageInspector {
    /// Reject images whose declared resolution exceeds this, to stop
    /// decompression bombs (a tiny file claiming huge dimensions).
    static let maxPixels = 50_000_000  // 50 megapixels

    /// Declared (width, height) read from the header, or `nil` if unknown.
    static func dimensions(of data: Data, type: AllowedFileType) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        switch type {
        case .png:  return pngDimensions(bytes)
        case .jpeg: return jpegDimensions(bytes)
        case .heic, .pdf, .txt, .docx, .doc: return nil
        }
    }

    /// Returns a copy of the image with embedded metadata removed (EXIF/XMP for
    /// JPEG, ancillary text/EXIF chunks for PNG). Returns the input unchanged
    /// for HEIC/PDF or if the bytes look malformed (never corrupts the file).
    static func stripMetadata(from data: Data, type: AllowedFileType) -> Data {
        switch type {
        case .jpeg: return stripJPEG(data)
        case .png:  return stripPNG(data)
        case .heic, .pdf, .txt, .docx, .doc: return data
        }
    }

    // MARK: - PNG

    private static func pngDimensions(_ bytes: [UInt8]) -> (Int, Int)? {
        // 8-byte signature, then IHDR: [len 4][type 4][width 4][height 4]
        guard bytes.count >= 24 else { return nil }
        let width = beUInt32(bytes, 16)
        let height = beUInt32(bytes, 20)
        return (Int(width), Int(height))
    }

    /// Drops non-essential PNG chunks that may carry metadata, copying the rest
    /// (including their CRCs) verbatim — no re-encoding needed.
    private static func stripPNG(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return data }

        let stripChunks: Set<String> = ["eXIf", "tEXt", "iTXt", "zTXt", "tIME"]
        var out: [UInt8] = signature
        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(beUInt32(bytes, i))
            let typeStart = i + 4
            let chunkType = String(decoding: bytes[typeStart..<typeStart + 4], as: UTF8.self)
            let chunkEnd = i + 12 + length  // len(4) + type(4) + data(length) + crc(4)
            guard chunkEnd <= bytes.count else { return data }  // malformed → keep original

            if !stripChunks.contains(chunkType) {
                out.append(contentsOf: bytes[i..<chunkEnd])
            }
            if chunkType == "IEND" { break }
            i = chunkEnd
        }
        return Data(out)
    }

    // MARK: - JPEG

    private static func jpegDimensions(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count > 3, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 1 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = bytes[i + 1]
            // Standalone markers (no length payload).
            if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
                i += 2
                continue
            }
            guard i + 3 < bytes.count else { return nil }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            // SOF markers carry the frame dimensions (skip DHT/JPG/DAC).
            if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                guard i + 8 < bytes.count else { return nil }
                let height = Int(bytes[i + 5]) << 8 | Int(bytes[i + 6])
                let width = Int(bytes[i + 7]) << 8 | Int(bytes[i + 8])
                return (width, height)
            }
            i += 2 + length
        }
        return nil
    }

    /// Rebuilds the JPEG without APP1 (EXIF/XMP) segments, copying everything
    /// from the start-of-scan onward verbatim.
    private static func stripJPEG(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return data }

        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        while i + 1 < bytes.count {
            guard bytes[i] == 0xFF else { return data }  // malformed → keep original
            let marker = bytes[i + 1]

            // Start of scan or end of image: copy the remainder as-is.
            if marker == 0xDA || marker == 0xD9 {
                out.append(contentsOf: bytes[i...])
                return Data(out)
            }

            guard i + 3 < bytes.count else { return data }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let segmentEnd = i + 2 + length
            guard segmentEnd <= bytes.count else { return data }

            // APP1 holds EXIF ("Exif") or XMP ("http"…); drop those segments.
            let isApp1 = marker == 0xE1
            let payloadOK = i + 7 < bytes.count
            let isExif = isApp1 && payloadOK
                && bytes[i + 4] == 0x45 && bytes[i + 5] == 0x78
                && bytes[i + 6] == 0x69 && bytes[i + 7] == 0x66  // "Exif"
            let isXmp = isApp1 && payloadOK
                && bytes[i + 4] == 0x68 && bytes[i + 5] == 0x74
                && bytes[i + 6] == 0x74 && bytes[i + 7] == 0x70  // "http"

            if !(isExif || isXmp) {
                out.append(contentsOf: bytes[i..<segmentEnd])
            }
            i = segmentEnd
        }
        return Data(out)
    }

    // MARK: - Helpers

    private static func beUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
