import Fluent
import Foundation
import Vapor

/// Runs one file through the LLM into a structured `Document` (+ `Biomarker`
/// rows for lab panels). The raw file is sent to the model as vision (image or
/// PDF) — the model does the reading, we don't extract a text layer ourselves
/// (see R-Extraction: text layers misalign units/references).
struct ExtractionService {
    let provider: any LLMProvider
    let db: any Database
    let storage: FileStorage
    let logger: Logger

    /// Extracts a lab result. Sets `parse_status` on the way and returns the
    /// created `Document`. Re-running replaces any previous extraction.
    @discardableResult
    func extract(labResult: LabResult) async throws -> Document {
        let labResultID = try labResult.requireID()
        let userID = labResult.$user.id

        labResult.parseStatus = .processing
        try await labResult.save(on: db)

        do {
            let document = try await runExtraction(labResult: labResult, labResultID: labResultID, userID: userID)
            labResult.parseStatus = .done
            try await labResult.save(on: db)
            return document
        } catch {
            logger.error("Extraction failed for lab_result \(labResultID): \(String(reflecting: error))")
            labResult.parseStatus = .failed
            try? await labResult.save(on: db)
            throw error
        }
    }

    private func runExtraction(labResult: LabResult, labResultID: UUID, userID: UUID) async throws -> Document {
        let content = try buildContent(for: labResult)

        let result = try await provider.complete(
            system: ExtractionPrompt.system,
            content: content,
            // Real lab panels run to dozens of biomarkers, and each one costs
            // ~90 tokens in the strict schema — 2048 truncated them mid-JSON.
            // This is a ceiling, not a spend: we're billed for what's generated.
            maxTokens: 16_000,
            jsonSchema: ExtractionSchema.schema
        )
        logger.info("Extraction tokens in=\(result.inputTokens) out=\(result.outputTokens) model=\(result.model)")

        let rawEnvelope = try parseEnvelope(result.text)

        // De-identify before anything is written to the DB. The model is told to
        // omit PII, but scrub as a backstop so no PII lands at rest (R-Compliance).
        if rawEnvelope["contains_pii"]?.boolValue == true {
            logger.warning("Extraction reported PII present in lab_result \(labResultID); scrubbing before storage")
        }
        let envelope = Deidentifier.scrub(rawEnvelope)

        // Replace any previous extraction (documents 1─1 lab_results; biomarkers cascade).
        try await Document.query(on: db).filter(\.$labResult.$id == labResultID).delete()

        let documentType = envelope["document_type"].flatMap { DocumentType(rawValue: $0.stringValue ?? "") } ?? .other
        if documentType == .unrelated {
            logger.info("lab_result \(labResultID) flagged as unrelated (not a medical document)")
        }
        let reportDate = envelope["report_date"].flatMap { Self.parseDate($0.stringValue) }

        let document = Document(
            userID: userID,
            labResultID: labResultID,
            documentType: documentType,
            payloadJson: envelope,
            promptVersion: ExtractionPrompt.version,
            extractionModel: result.model,
            reportDate: reportDate,
            provider: envelope["provider"]?.stringValue,
            summary: envelope["summary"]?.stringValue,
            diagnosis: envelope["diagnosis"]?.stringValue
        )
        try await document.save(on: db)

        if documentType == .labPanel {
            try await saveBiomarkers(from: envelope, document: document, userID: userID, fallbackDate: reportDate ?? labResult.uploadedAt ?? Date())
        }

        return document
    }

    // MARK: - Content

    private func buildContent(for labResult: LabResult) throws -> [LLMContent] {
        let data = try storage.read(key: labResult.storageKey)
        let instruction = LLMContent.text("Extract this document into the required JSON. Output JSON only.")

        guard let type = AllowedFileType(mimeType: labResult.mimeType) else {
            throw Abort(.unsupportedMediaType, reason: "Unknown type for extraction: \(labResult.mimeType)")
        }

        switch type {
        case .pdf:
            return [.pdf(base64: data.base64EncodedString()), instruction]
        case .jpeg, .png:
            return [.image(base64: data.base64EncodedString(), mediaType: labResult.mimeType), instruction]
        case .txt, .docx:
            guard let text = try DocumentText.plainText(from: data, type: type), !text.isEmpty else {
                throw Abort(.unsupportedMediaType, reason: "No text could be read from the document")
            }
            return [.text("Document text:\n\n\(text)"), instruction]
        case .doc:
            // Legacy OLE2 Word — can't extract reliably without a heavy converter.
            throw Abort(.unsupportedMediaType, reason: "Legacy .doc isn't supported for extraction; upload PDF, DOCX or TXT")
        case .heic:
            // Not accepted by the vision API — expect client-side conversion (R-Files §HEIC).
            throw Abort(.unsupportedMediaType, reason: "HEIC isn't supported for extraction; convert to JPEG or PDF")
        }
    }

    // MARK: - Parsing

    private func parseEnvelope(_ text: String) throws -> JSONValue {
        // Tolerate accidental ```json fences despite the "JSON only" instruction.
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "Extraction output was not valid text")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            logger.warning("Extraction JSON parse failed; first 200 chars: \(cleaned.prefix(200))")
            throw Abort(.internalServerError, reason: "Extraction output was not valid JSON")
        }
    }

    private func saveBiomarkers(from envelope: JSONValue, document: Document, userID: UUID, fallbackDate: Date) async throws {
        guard let rows = envelope["biomarkers"]?.arrayValue else { return }
        let documentID = try document.requireID()

        for row in rows {
            let originalName = row["original_name"]?.stringValue
            let name = row["name"]?.stringValue ?? originalName ?? "unknown"
            let unit = row["unit"]?.stringValue ?? ""
            let status = BiomarkerStatus(rawValue: row["status"]?.stringValue ?? "") ?? .unknown
            let measuredAt = row["measured_at"].flatMap { Self.parseDate($0.stringValue) } ?? fallbackDate

            let refRange = row["reference_range"]
            let biomarker = Biomarker(
                userID: userID,
                documentID: documentID,
                name: name,
                originalName: originalName ?? name,
                unit: unit,
                status: status,
                measuredAt: measuredAt,
                value: row["value"]?.doubleValue,
                valueOperator: ValueOperator(rawValue: row["value_operator"]?.stringValue ?? ""),
                code: row["code"]?.stringValue,
                refLow: refRange?["low"]?.doubleValue,
                refHigh: refRange?["high"]?.doubleValue,
                refText: refRange?["text"]?.stringValue
            )
            try await biomarker.save(on: db)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return dateFormatter.date(from: String(string.prefix(10)))
    }
}
