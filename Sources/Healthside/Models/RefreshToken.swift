import Crypto
import Fluent
import Foundation
import Vapor

/// A long-lived (≈30 days) opaque refresh token.
///
/// The raw token is given to the client once and never stored — only its
/// SHA-256 hash lives in the DB, so a database leak can't be replayed and the
/// token stays revocable (delete the row = revoke).
final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, userID: UUID, tokenHash: String, expiresAt: Date) {
        self.id = id
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}

extension RefreshToken {
    /// Lifetime of a refresh token.
    static let lifetime: TimeInterval = 60 * 60 * 24 * 30

    /// Generates a fresh random token, returning the raw value (for the client)
    /// and its hash (for storage).
    static func generate() -> (raw: String, hash: String) {
        let raw = Data([UInt8].random(count: 32)).base64EncodedString()
        return (raw, hash(of: raw))
    }

    /// Deterministic SHA-256 hash used both to store and to look up a token.
    /// SHA-256 (not Bcrypt) is fine here: the token is high-entropy and random,
    /// and we need a stable value to query by.
    static func hash(of raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isExpired: Bool {
        expiresAt < Date()
    }
}
