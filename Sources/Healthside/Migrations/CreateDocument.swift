import Fluent
import SQLKit

struct CreateDocument: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("documents")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("lab_result_id", .uuid, .required, .references("lab_results", "id", onDelete: .cascade))
            .field("document_type", .string, .required)
            .field("report_date", .datetime)
            .field("provider", .string)
            .field("summary", .string)
            .field("diagnosis", .string)
            .field("payload_json", .json, .required)
            .field("prompt_version", .string, .required)
            .field("extraction_model", .string, .required)
            .field("created_at", .datetime)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "idx_documents_user_id").on("documents").column("user_id").run()
            try await sql.create(index: "idx_documents_lab_result_id").on("documents").column("lab_result_id").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("documents").delete()
    }
}
