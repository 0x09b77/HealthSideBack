import Fluent
import JWT
import Vapor

/// Payload of the short-lived access token (≈15 minutes).
///
/// Carries only the user id (`sub`) and expiry (`exp`) — no passwords or
/// sensitive data, since a JWT payload is signed but readable.
struct UserToken: Content, Authenticatable, JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.expiration.verifyNotExpired()
    }
}

extension UserToken {
    /// Lifetime of the access token.
    static let accessTokenLifetime: TimeInterval = 60 * 15

    static func make(for user: User) throws -> UserToken {
        UserToken(
            subject: .init(value: try user.requireID().uuidString),
            expiration: .init(value: Date().addingTimeInterval(accessTokenLifetime))
        )
    }
}
