import Fluent
import Foundation
import Vapor

/// Metadata for an uploaded lab result. The file bytes themselves live in file
/// storage under `storageKey`; the DB only holds metadata and the key.
final class LabResult: Model, @unchecked Sendable {
    static let schema = "lab_results"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// Name the user's file had on their device. Display-only — never used as a
    /// filesystem path.
    @Field(key: "original_filename")
    var originalFilename: String

    /// Server-generated key (UUID) the file is stored under. We never trust the
    /// client's filename for storage (path traversal / collisions).
    @Field(key: "storage_key")
    var storageKey: String

    @Field(key: "mime_type")
    var mimeType: String

    @Field(key: "file_size")
    var fileSize: Int

    /// SHA-256 of the file bytes — integrity check and future dedup.
    @Field(key: "checksum_sha256")
    var checksumSha256: String

    @OptionalField(key: "label")
    var label: String?

    @Timestamp(key: "uploaded_at", on: .create)
    var uploadedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        originalFilename: String,
        storageKey: String,
        mimeType: String,
        fileSize: Int,
        checksumSha256: String,
        label: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.originalFilename = originalFilename
        self.storageKey = storageKey
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.checksumSha256 = checksumSha256
        self.label = label
    }

    func toResponse() throws -> LabResultResponse {
        .init(
            id: try self.requireID(),
            originalFilename: self.originalFilename,
            mimeType: self.mimeType,
            fileSize: self.fileSize,
            checksumSha256: self.checksumSha256,
            label: self.label,
            uploadedAt: self.uploadedAt
        )
    }
}
