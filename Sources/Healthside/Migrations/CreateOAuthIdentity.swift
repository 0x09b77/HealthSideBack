import Fluent

struct CreateOAuthIdentity: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_identities")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("provider_user_id", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "provider", "provider_user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_identities").delete()
    }
}
