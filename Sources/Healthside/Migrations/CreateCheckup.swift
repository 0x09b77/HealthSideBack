import Fluent
import SQLKit

struct CreateCheckup: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("checkups")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("report_json", .json, .required)
            .field("model", .string, .required)
            .field("prompt_version", .string, .required)
            .field("schema_version", .string, .required)
            .field("source_document_ids", .array(of: .uuid), .required)
            .field("input_fingerprint", .string, .required)
            .field("created_at", .datetime)
            .create()

        // Fetching a user's checkup history / latest snapshot.
        try await (database as? any SQLDatabase)?
            .create(index: "idx_checkups_user_id").on("checkups").column("user_id").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("checkups").delete()
    }
}
