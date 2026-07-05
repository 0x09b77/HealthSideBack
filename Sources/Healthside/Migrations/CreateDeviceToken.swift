import Fluent
import SQLKit

struct CreateDeviceToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("device_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("fcm_token", .string, .required)
            .field("platform", .string, .required)
            .field("created_at", .datetime)
            .field("last_seen_at", .datetime, .required)
            .unique(on: "fcm_token")
            .create()

        try await (database as? any SQLDatabase)?
            .create(index: "idx_device_tokens_user_id").on("device_tokens").column("user_id").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("device_tokens").delete()
    }
}
