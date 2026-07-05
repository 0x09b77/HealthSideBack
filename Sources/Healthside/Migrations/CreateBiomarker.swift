import Fluent
import SQLKit

struct CreateBiomarker: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("biomarkers")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("document_id", .uuid, .required, .references("documents", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("original_name", .string, .required)
            .field("code", .string)
            .field("value", .double)
            .field("value_operator", .string)
            .field("unit", .string, .required)
            .field("ref_low", .double)
            .field("ref_high", .double)
            .field("ref_text", .string)
            .field("status", .string, .required)
            .field("measured_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()

        // Trend queries: a user's marker over time.
        try await (database as? any SQLDatabase)?
            .create(index: "idx_biomarkers_user_name_measured")
            .on("biomarkers")
            .column("user_id").column("name").column("measured_at")
            .run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("biomarkers").delete()
    }
}
