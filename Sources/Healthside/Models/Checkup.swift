import Fluent
import Foundation

/// A snapshot of a generated checkup report. Kept as history (never overwritten)
/// and cached — served for free until the underlying data changes
/// (`inputFingerprint`, see R-Checkup).
final class Checkup: Model, @unchecked Sendable {
    static let schema = "checkups"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// The report itself, in the fixed schema.
    @Field(key: "report_json")
    var reportJson: JSONValue

    @Field(key: "model")
    var model: String

    @Field(key: "prompt_version")
    var promptVersion: String

    @Field(key: "schema_version")
    var schemaVersion: String

    @Field(key: "source_document_ids")
    var sourceDocumentIds: [UUID]

    /// Hash of the biomarker set the report was built from — for invalidation.
    @Field(key: "input_fingerprint")
    var inputFingerprint: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        reportJson: JSONValue,
        model: String,
        promptVersion: String,
        schemaVersion: String,
        sourceDocumentIds: [UUID],
        inputFingerprint: String
    ) {
        self.id = id
        self.$user.id = userID
        self.reportJson = reportJson
        self.model = model
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.sourceDocumentIds = sourceDocumentIds
        self.inputFingerprint = inputFingerprint
    }
}
