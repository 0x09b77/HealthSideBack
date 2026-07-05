import Fluent
import Vapor

/// A document in the processing/extraction feed: the uploaded file plus its
/// extraction status and — once parsed — the envelope summary.
///
/// Keyed by the lab-result id (== `document_id` returned at upload). Envelope
/// fields are `nil` until extraction produces a `Document` row.
struct DocumentView: Content {
    let id: UUID
    let status: ParseStatus
    let originalFilename: String
    let mimeType: String
    let fileSize: Int
    let label: String?
    let documentType: DocumentType?
    let reportDate: Date?
    let provider: String?
    let summary: String?
    let diagnosis: String?
    let payloadJson: JSONValue?
    let uploadedAt: Date?

    init(labResult: LabResult, document: Document?) throws {
        self.id = try labResult.requireID()
        self.status = labResult.parseStatus
        self.originalFilename = labResult.originalFilename
        self.mimeType = labResult.mimeType
        self.fileSize = labResult.fileSize
        self.label = labResult.label
        self.uploadedAt = labResult.uploadedAt
        self.documentType = document?.documentType
        self.reportDate = document?.reportDate
        self.provider = document?.provider
        self.summary = document?.summary
        self.diagnosis = document?.diagnosis
        self.payloadJson = document?.payloadJson
    }
}
