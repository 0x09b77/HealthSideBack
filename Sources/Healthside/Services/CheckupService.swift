import Crypto
import Fluent
import Foundation
import Vapor

/// Builds a holistic checkup over a user's extracted biomarkers. Runs on the
/// compact structured data (not raw files), caches by `inputFingerprint`, and
/// keeps history — old checkups are never overwritten (see R-Checkup).
struct CheckupService {
    let provider: any LLMProvider
    let db: any Database
    let logger: Logger

    /// All of the user's biomarkers, stably ordered (for a deterministic fingerprint).
    func biomarkers(for userID: UUID) async throws -> [Biomarker] {
        try await Biomarker.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$name)
            .sort(\.$measuredAt)
            .all()
    }

    /// The most recent stored checkup, if any.
    func latest(for userID: UUID) async throws -> Checkup? {
        try await Checkup.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .first()
    }

    /// Deterministic hash of the biomarker set — changes when data changes,
    /// so a matching fingerprint means the cached checkup is still valid.
    func fingerprint(of biomarkers: [Biomarker]) -> String {
        let joined: String = biomarkers.map { (b: Biomarker) -> String in
            let value = b.value.map { String($0) } ?? ""
            let id = b.id?.uuidString ?? ""
            return "\(id)|\(b.name)|\(value)|\(b.unit)|\(b.status.rawValue)|\(Self.day.string(from: b.measuredAt))"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Generates and stores a fresh checkup by calling the LLM.
    func generate(for userID: UUID) async throws -> Checkup {
        let markers = try await biomarkers(for: userID)
        guard !markers.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "No biomarkers to analyze yet — upload and extract a lab result first")
        }

        let input = try Self.buildInput(markers)
        let result = try await provider.complete(
            system: CheckupPrompt.system,
            content: [.text("User biomarkers:\n\n\(input)")],
            maxTokens: 4096
        )
        logger.info("Checkup tokens in=\(result.inputTokens) out=\(result.outputTokens) model=\(result.model)")

        let report = try Self.parseJSON(result.text, logger: logger)
        let sourceDocumentIDs = Array(Set(markers.map { $0.$document.id }))

        let checkup = Checkup(
            userID: userID,
            reportJson: report,
            model: result.model,
            promptVersion: CheckupPrompt.version,
            schemaVersion: CheckupPrompt.schemaVersion,
            sourceDocumentIds: sourceDocumentIDs,
            inputFingerprint: fingerprint(of: markers)
        )
        try await checkup.save(on: db)
        return checkup
    }

    // MARK: - Input building

    private struct BiomarkerInput: Encodable {
        let name: String
        let value: Double?
        let unit: String
        let ref_low: Double?
        let ref_high: Double?
        let status: String
        let date: String
        let source_document_id: String
    }

    private static func buildInput(_ markers: [Biomarker]) throws -> String {
        let rows = markers.map { b in
            BiomarkerInput(
                name: b.name,
                value: b.value,
                unit: b.unit,
                ref_low: b.refLow,
                ref_high: b.refHigh,
                status: b.status.rawValue,
                date: day.string(from: b.measuredAt),
                source_document_id: b.$document.id.uuidString
            )
        }
        let data = try JSONEncoder().encode(rows)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    private static func parseJSON(_ text: String, logger: Logger) throws -> JSONValue {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            logger.warning("Checkup JSON parse failed; first 200 chars: \(cleaned.prefix(200))")
            throw Abort(.internalServerError, reason: "Checkup output was not valid JSON")
        }
        return value
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
