import Fluent

struct CreateLabResult: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("lab_results")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("original_filename", .string, .required)
            .field("storage_key", .string, .required)
            .field("mime_type", .string, .required)
            .field("file_size", .int, .required)
            .field("checksum_sha256", .string, .required)
            .field("label", .string)
            .field("uploaded_at", .datetime)
            .unique(on: "storage_key")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("lab_results").delete()
    }
}
