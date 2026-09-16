import Fluent
import Foundation

/// Links a `User` to an identity at a third-party provider (Apple today,
/// Google potentially later). A separate table rather than columns on
/// `users` so a new provider is a new row, not a schema change.
final class OAuthIdentity: Model, @unchecked Sendable {
    static let schema = "oauth_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// e.g. "apple". A plain string, not a DB enum — adding a provider never
    /// needs a migration to widen it.
    @Field(key: "provider")
    var provider: String

    /// The provider's stable, opaque user id (Apple's `sub` claim).
    @Field(key: "provider_user_id")
    var providerUserId: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, userID: UUID, provider: String, providerUserId: String) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.providerUserId = providerUserId
    }
}
