import Fluent
import Vapor
import struct Foundation.UUID
import struct Foundation.Date

/// Property wrappers interact poorly with `Sendable` checking, causing a warning for the `@ID` property
/// It is recommended you write your model with sendability checking on and then suppress the warning
/// afterwards with `@unchecked Sendable`.
final class User: Model, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    /// Bcrypt hash of the password. Never serialized to the client. `nil`
    /// for an account created via Sign in with Apple that has never set one.
    @OptionalField(key: "password_hash")
    var passwordHash: String?

    /// Gates login (see R-Auth). `/auth/register` always creates this as
    /// `false`; the default of `true` here is for code that constructs a
    /// `User` directly (tests, migrations) without going through the
    /// verification flow.
    @Field(key: "email_verified")
    var emailVerified: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$user)
    var refreshTokens: [RefreshToken]

    init() { }

    init(id: UUID? = nil, email: String, passwordHash: String?, emailVerified: Bool = true) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.emailVerified = emailVerified
    }

    func toResponse() throws -> UserResponse {
        .init(
            id: try self.requireID(),
            email: self.email,
            emailVerified: self.emailVerified,
            createdAt: self.createdAt
        )
    }
}
