import Fluent
import FluentSQL
import SQLKit

/// Sign in with Apple accounts have no password (see R-Auth) — `password_hash`
/// must accept NULL. Fluent's schema builder has no nullability-toggle API,
/// so this drops the constraint directly.
struct MakePasswordHashOptionalOnUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL").run()
    }

    func revert(on database: any Database) async throws {
        // Deliberately not restoring NOT NULL: by design an Apple-only
        // account can have a NULL password_hash, which would make this fail
        // the moment one exists. The `users` table is dropped moments later
        // when `CreateUser` reverts, so there's nothing left to undo anyway.
    }
}
