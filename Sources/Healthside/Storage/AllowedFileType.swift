import Vapor

/// File types accepted for lab-result uploads.
///
/// The real type is determined from the file's magic bytes (or, for plain text,
/// a content heuristic), never from the client's filename or `Content-Type`
/// header (doc §5: don't trust either).
enum AllowedFileType: String, CaseIterable {
    case pdf
    case jpeg
    case png
    case heic
    case txt
    case docx
    case doc

    var mimeType: String {
        switch self {
        case .pdf:  return "application/pdf"
        case .jpeg: return "image/jpeg"
        case .png:  return "image/png"
        case .heic: return "image/heic"
        case .txt:  return "text/plain"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .doc:  return "application/msword"
        }
    }

    var isImage: Bool {
        switch self {
        case .jpeg, .png, .heic: return true
        case .pdf, .txt, .docx, .doc: return false
        }
    }

    var httpMediaType: HTTPMediaType {
        let parts = mimeType.split(separator: "/", maxSplits: 1)
        return HTTPMediaType(type: String(parts[0]), subType: String(parts[1]))
    }

    /// Reverse lookup from a stored MIME type.
    init?(mimeType: String) {
        guard let match = Self.allCases.first(where: { $0.mimeType == mimeType }) else { return nil }
        self = match
    }

    /// Maximum accepted upload size, in bytes (doc §7: 20 MB).
    static let maxFileSize = 20 * 1024 * 1024

    /// Detects the type from the leading bytes of a file, or `nil` if it's not
    /// in the whitelist. Pass a generous prefix (e.g. 512 bytes) so the plain-text
    /// heuristic has enough to look at.
    static func detect(from bytes: [UInt8]) -> AllowedFileType? {
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {            // "%PDF"
            return .pdf
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {                  // JPEG SOI
            return .jpeg
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {  // PNG
            return .png
        }
        // ZIP container "PK\x03\x04" — for our whitelist that means .docx.
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return .docx
        }
        // OLE2 compound file — legacy .doc (also .xls/.ppt; we accept as .doc).
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return .doc
        }
        // ISO-BMFF (HEIC): "ftyp" box at offset 4, brand at offset 8.
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            let heicBrands: Set<String> = [
                "heic", "heix", "hevc", "heim", "heis", "hevm", "hevs", "mif1", "msf1"
            ]
            if heicBrands.contains(brand) {
                return .heic
            }
        }
        // No binary signature — treat as plain text if the bytes look textual.
        if looksLikeText(bytes) {
            return .txt
        }
        return nil
    }

    /// Heuristic: no NUL bytes and an overwhelmingly printable/whitespace body.
    /// Bytes ≥ 0x80 are allowed (UTF-8 multibyte), so non-Latin text passes.
    private static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        if bytes.contains(0) { return false }
        let textual = bytes.filter { $0 == 9 || $0 == 10 || $0 == 13 || $0 >= 32 }.count
        return Double(textual) / Double(bytes.count) > 0.9
    }
}
