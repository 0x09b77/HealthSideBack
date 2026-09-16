import Fluent
import FluentSQL
import SQLKit

struct CreatePasswordResetCode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("password_reset_codes")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("attempts", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("password_reset_codes").delete()
    }
}
