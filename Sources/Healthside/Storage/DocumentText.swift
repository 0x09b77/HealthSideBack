import Foundation
import Vapor
import ZIPFoundation

/// Extracts plain text from document formats the model can't read as vision
/// (`.txt`, `.docx`). PDFs and images go to the model directly; legacy `.doc`
/// (OLE2 binary) can't be read without a heavy converter and is unsupported.
enum DocumentText {
    /// Returns text for `.txt`/`.docx`, or `nil` for formats handled elsewhere.
    static func plainText(from data: Data, type: AllowedFileType) throws -> String? {
        switch type {
        case .txt:
            guard let text = String(data: data, encoding: .utf8) else {
                throw Abort(.unsupportedMediaType, reason: "Text file is not valid UTF-8")
            }
            return text
        case .docx:
            return try docxText(data)
        default:
            return nil
        }
    }

    /// Reads `word/document.xml` from the .docx zip and strips XML tags. We only
    /// read the document body — macros (`vbaProject.bin`) are never touched.
    private static func docxText(_ data: Data) throws -> String {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw Abort(.unsupportedMediaType, reason: "Not a readable .docx file")
        }
        guard let entry = archive["word/document.xml"] else {
            throw Abort(.unsupportedMediaType, reason: "Not a valid .docx (no word/document.xml)")
        }

        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }
        guard let xml = String(data: xmlData, encoding: .utf8) else {
            throw Abort(.unsupportedMediaType, reason: "Could not decode .docx contents")
        }

        // Paragraph and tab boundaries → whitespace, then drop all tags.
        var text = xml
            .replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "<w:tab/>", with: "\t")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode the handful of XML entities Word emits.
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
