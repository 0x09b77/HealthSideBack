import Vapor

/// Multipart body of `POST /lab-results`.
struct UploadRequest: Content {
    var file: File
    var label: String?
}

/// Returned by `POST /lab-results` (202): the file is accepted and queued for
/// background extraction. `documentId` is the lab-result id (1─1 with documents).
struct UploadAcceptedResponse: Content {
    let documentId: UUID
    let status: ParseStatus
}

/// Safe metadata view of a lab result returned to the client.
/// Never exposes the internal `storageKey` or owner id.
struct LabResultResponse: Content {
    let id: UUID
    let originalFilename: String
    let mimeType: String
    let fileSize: Int
    let checksumSha256: String
    let label: String?
    let parseStatus: ParseStatus
    let uploadedAt: Date?
}
