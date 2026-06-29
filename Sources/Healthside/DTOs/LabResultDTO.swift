import Vapor

/// Multipart body of `POST /lab-results`.
struct UploadRequest: Content {
    var file: File
    var label: String?
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
    let uploadedAt: Date?
}
