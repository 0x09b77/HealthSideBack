import Fluent
import Foundation

/// The extraction "envelope": one row per parsed file, of any type (lab panel,
/// imaging report, consult note). `payloadJson` is the cheap structured summary
/// the checkup reads (see R-Extraction, R-Data-Model).
final class Document: Model, @unchecked Sendable {
    static let schema = "documents"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "lab_result_id")
    var labResult: LabResult

    @Field(key: "document_type")
    var documentType: DocumentType

    @OptionalField(key: "report_date")
    var reportDate: Date?

    @OptionalField(key: "provider")
    var provider: String?

    @OptionalField(key: "summary")
    var summary: String?

    @OptionalField(key: "diagnosis")
    var diagnosis: String?

    /// Full extraction envelope as returned by the model.
    @Field(key: "payload_json")
    var payloadJson: JSONValue

    @Field(key: "prompt_version")
    var promptVersion: String

    @Field(key: "extraction_model")
    var extractionModel: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        labResultID: UUID,
        documentType: DocumentType,
        payloadJson: JSONValue,
        promptVersion: String,
        extractionModel: String,
        reportDate: Date? = nil,
        provider: String? = nil,
        summary: String? = nil,
        diagnosis: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.$labResult.id = labResultID
        self.documentType = documentType
        self.payloadJson = payloadJson
        self.promptVersion = promptVersion
        self.extractionModel = extractionModel
        self.reportDate = reportDate
        self.provider = provider
        self.summary = summary
        self.diagnosis = diagnosis
    }
}
