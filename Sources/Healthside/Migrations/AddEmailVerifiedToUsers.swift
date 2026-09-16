import Fluent
import FluentSQL
import SQLKit

/// Additive migration: adds `email_verified` to `users` (see R-Auth).
/// The `true` default backfills existing rows — the app only ever writes
/// `false` explicitly from `/auth/register`, so this only relaxes accounts
/// that predate the verification flow.
struct AddEmailVerifiedToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("email_verified", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("email_verified")
            .update()
    }
}
