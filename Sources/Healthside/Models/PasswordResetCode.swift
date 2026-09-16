import Crypto
import Fluent
import Foundation
import Vapor

/// A short-lived 6-digit password-reset code.
///
/// Deliberately a separate table from `EmailVerificationCode` — mixing the
/// two purposes in one table risks a code minted for one flow being usable
/// in the other. Same storage pattern otherwise: only the SHA-256 hash is
/// kept, protection against brute force rests on `maxAttempts`, the short
/// lifetime, and per-IP rate limiting on the reset endpoint.
final class PasswordResetCode: Model, @unchecked Sendable {
    static let schema = "password_reset_codes"

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

extension PasswordResetCode {
    static let lifetime: TimeInterval = 60 * 15
    static let maxAttempts = 5

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
