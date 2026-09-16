import Crypto
import Fluent
import Foundation
import Vapor

/// A short-lived 6-digit email verification code.
///
/// Same storage pattern as `RefreshToken`: only the SHA-256 hash is kept, so
/// a DB leak doesn't hand out usable codes. The real protection against
/// brute-forcing a 6-digit space is `maxAttempts` plus the short lifetime and
/// per-IP rate limiting on the verify endpoint, not the hash itself.
final class EmailVerificationCode: Model, @unchecked Sendable {
    static let schema = "email_verification_codes"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "attempts")
    var attempts: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, userID: UUID, codeHash: String, expiresAt: Date) {
        self.id = id
        self.$user.id = userID
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.attempts = 0
    }
}

extension EmailVerificationCode {
    static let lifetime: TimeInterval = 60 * 15
    static let maxAttempts = 5

    /// Generates a fresh 6-digit code, returning the raw value (to email) and
    /// its hash (to store).
    static func generate() -> (raw: String, hash: String) {
        let raw = String(format: "%06d", Int.random(in: 0...999_999))
        return (raw, hash(of: raw))
    }

    static func hash(of raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isExpired: Bool {
        expiresAt < Date()
    }

    var isLocked: Bool {
        attempts >= Self.maxAttempts
    }
}
