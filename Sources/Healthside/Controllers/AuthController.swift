import Fluent
import JWT
import Vapor

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")

        // Throttle credential endpoints to blunt brute-force / enumeration.
        // Limits are per client IP per minute; tune via env.
        let window: TimeInterval = 60
        let loginLimit = Environment.get("RATE_LIMIT_LOGIN").flatMap(Int.init) ?? 10
        let registerLimit = Environment.get("RATE_LIMIT_REGISTER").flatMap(Int.init) ?? 10

        auth.grouped(RateLimitMiddleware(limit: registerLimit, window: window, scope: "auth-register"))
            .post("register", use: self.register)
        auth.grouped(RateLimitMiddleware(limit: loginLimit, window: window, scope: "auth-login"))
            .post("login", use: self.login)
        auth.post("refresh", use: self.refresh)
        auth.post("logout", use: self.logout)

        // Changing a password needs a live session AND the current password.
        // Throttled too: a stolen access token could otherwise brute-force the
        // old password here.
        auth.grouped(AccessTokenAuthenticator())
            .grouped(RateLimitMiddleware(limit: loginLimit, window: window, scope: "auth-change-password"))
            .post("change-password", use: self.changePassword)
    }

    /// `POST /auth/register` — create an account.
    @Sendable
    func register(req: Request) async throws -> Response {
        try AuthRequest.validate(content: req)
        let payload = try req.content.decode(AuthRequest.self)
        let email = Self.normalize(payload.email)

        let existing = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first()
        guard existing == nil else {
            throw Abort(.conflict, reason: "Email already registered")
        }

        let user = User(email: email, passwordHash: try Bcrypt.hash(payload.password))
        try await user.save(on: req.db)

        return try await user.toResponse().encodeResponse(status: .created, for: req)
    }

    /// `POST /auth/login` — verify credentials and issue an access token.
    @Sendable
    func login(req: Request) async throws -> TokenResponse {
        let payload = try req.content.decode(AuthRequest.self)
        let email = Self.normalize(payload.email)

        // Same generic error whether the user is missing or the password is
        // wrong — don't reveal which emails are registered.
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first(),
            try Bcrypt.verify(payload.password, created: user.passwordHash)
        else {
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }

        return try await self.issueTokens(for: user, on: req)
    }

    /// `POST /auth/refresh` — exchange a valid refresh token for a new token pair.
    ///
    /// The presented refresh token is rotated: it's deleted and a fresh one is
    /// issued, so a stolen-and-used token can't keep working alongside the real one.
    @Sendable
    func refresh(req: Request) async throws -> TokenResponse {
        let payload = try req.content.decode(RefreshRequest.self)
        let hash = RefreshToken.hash(of: payload.refreshToken)

        guard let stored = try await RefreshToken.query(on: req.db)
            .filter(\.$tokenHash == hash)
            .with(\.$user)
            .first()
        else {
            throw Abort(.unauthorized, reason: "Invalid refresh token")
        }

        // Expired tokens are useless — drop them and reject.
        guard !stored.isExpired else {
            try await stored.delete(on: req.db)
            throw Abort(.unauthorized, reason: "Refresh token expired")
        }

        let user = stored.user
        try await stored.delete(on: req.db)
        return try await self.issueTokens(for: user, on: req)
    }

    /// `POST /auth/logout` — revoke a refresh token.
    ///
    /// Idempotent: returns 204 whether or not the token existed, so it can't be
    /// used to probe which tokens are valid. The short-lived access token isn't
    /// revoked — it expires on its own within minutes.
    @Sendable
    func logout(req: Request) async throws -> HTTPStatus {
        let payload = try req.content.decode(RefreshRequest.self)
        let hash = RefreshToken.hash(of: payload.refreshToken)

        try await RefreshToken.query(on: req.db)
            .filter(\.$tokenHash == hash)
            .delete()

        return .noContent
    }

    /// `POST /auth/change-password` — set a new password for the signed-in user.
    ///
    /// Every existing refresh token is revoked so a password change actually ends
    /// other sessions (otherwise a stolen refresh token would survive it). A fresh
    /// pair is returned so the calling device stays signed in.
    @Sendable
    func changePassword(req: Request) async throws -> TokenResponse {
        let user = try req.auth.require(User.self)
        try ChangePasswordRequest.validate(content: req)
        let payload = try req.content.decode(ChangePasswordRequest.self)

        guard try Bcrypt.verify(payload.currentPassword, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Current password is incorrect")
        }
        guard payload.newPassword != payload.currentPassword else {
            throw Abort(.badRequest, reason: "New password must differ from the current one")
        }

        user.passwordHash = try Bcrypt.hash(payload.newPassword)
        try await user.save(on: req.db)

        try await RefreshToken.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .delete()

        return try await self.issueTokens(for: user, on: req)
    }

    /// Issues a new access token plus a stored refresh token for the user.
    private func issueTokens(for user: User, on req: Request) async throws -> TokenResponse {
        let accessToken = try await req.jwt.sign(UserToken.make(for: user))

        let (rawRefresh, hash) = RefreshToken.generate()
        let refreshToken = RefreshToken(
            userID: try user.requireID(),
            tokenHash: hash,
            expiresAt: Date().addingTimeInterval(RefreshToken.lifetime)
        )
        try await refreshToken.save(on: req.db)

        return TokenResponse(accessToken: accessToken, refreshToken: rawRefresh)
    }

    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
