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
        // A 6-digit code is a small search space — keep this tighter than login.
        let verifyLimit = Environment.get("RATE_LIMIT_VERIFY_EMAIL").flatMap(Int.init) ?? 10
        // Each hit sends a real email — throttle harder than everything else so
        // this can't be used to spam a victim's inbox.
        let resendLimit = Environment.get("RATE_LIMIT_RESEND_VERIFICATION").flatMap(Int.init) ?? 5
        let forgotPasswordLimit = Environment.get("RATE_LIMIT_FORGOT_PASSWORD").flatMap(Int.init) ?? 5
        let resetPasswordLimit = Environment.get("RATE_LIMIT_RESET_PASSWORD").flatMap(Int.init) ?? 10
        let appleSignInLimit = Environment.get("RATE_LIMIT_APPLE_SIGNIN").flatMap(Int.init) ?? 10

        auth.grouped(RateLimitMiddleware(limit: registerLimit, window: window, scope: "auth-register"))
            .post("register", use: self.register)
        auth.grouped(RateLimitMiddleware(limit: loginLimit, window: window, scope: "auth-login"))
            .post("login", use: self.login)
        auth.grouped(RateLimitMiddleware(limit: verifyLimit, window: window, scope: "auth-verify-email"))
            .post("verify-email", use: self.verifyEmail)
        auth.grouped(RateLimitMiddleware(limit: resendLimit, window: window, scope: "auth-resend-verification"))
            .post("resend-verification", use: self.resendVerification)
        auth.grouped(RateLimitMiddleware(limit: forgotPasswordLimit, window: window, scope: "auth-forgot-password"))
            .post("forgot-password", use: self.forgotPassword)
        auth.grouped(RateLimitMiddleware(limit: resetPasswordLimit, window: window, scope: "auth-reset-password"))
            .post("reset-password", use: self.resetPassword)
        auth.grouped(RateLimitMiddleware(limit: appleSignInLimit, window: window, scope: "auth-apple"))
            .post("apple", use: self.appleSignIn)
        auth.post("refresh", use: self.refresh)
        auth.post("logout", use: self.logout)

        // Changing a password needs a live session AND the current password.
        // Throttled too: a stolen access token could otherwise brute-force the
        // old password here.
        auth.grouped(AccessTokenAuthenticator())
            .grouped(RateLimitMiddleware(limit: loginLimit, window: window, scope: "auth-change-password"))
            .post("change-password", use: self.changePassword)
    }

    /// `POST /auth/register` — create an account. Unverified until the code
    /// emailed here is confirmed via `/auth/verify-email` (see R-Auth).
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

        let user = User(email: email, passwordHash: try Bcrypt.hash(payload.password), emailVerified: false)
        try await user.save(on: req.db)

        // Best-effort: a flaky email provider shouldn't fail registration —
        // the client falls back to `/auth/resend-verification`.
        do {
            try await self.sendVerificationCode(to: user, on: req)
        } catch {
            req.logger.warning("Failed to send verification email to \(email): \(error)")
        }

        return try await user.toResponse().encodeResponse(status: .created, for: req)
    }

    /// `POST /auth/login` — verify credentials and issue an access token.
    @Sendable
    func login(req: Request) async throws -> TokenResponse {
        let payload = try req.content.decode(AuthRequest.self)
        let email = Self.normalize(payload.email)

        // In addition to the per-IP limit on this route: without this, an
        // attacker spreading guesses across many IPs could brute-force one
        // known email's password with no effective limit at all.
        try await RateLimitMiddleware.enforce(
            key: "auth-login-account:\(email)",
            limit: Self.rateLimit("RATE_LIMIT_LOGIN_PER_ACCOUNT", default: 10),
            window: 60,
            on: req
        )

        // Same generic error whether the user is missing, has no password
        // (Apple-only account), or the password is wrong — don't reveal
        // which emails are registered or how they authenticate.
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first(),
            let hash = user.passwordHash,
            try Bcrypt.verify(payload.password, created: hash)
        else {
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }
        guard user.emailVerified else {
            throw Abort(.forbidden, reason: "Email not verified")
        }

        return try await self.issueTokens(for: user, on: req)
    }

    /// `POST /auth/verify-email` — confirm the code and log the user in.
    @Sendable
    func verifyEmail(req: Request) async throws -> TokenResponse {
        try VerifyEmailRequest.validate(content: req)
        let payload = try req.content.decode(VerifyEmailRequest.self)
        let email = Self.normalize(payload.email)

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first()
        else {
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        guard let code = try await EmailVerificationCode.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        guard !code.isExpired, !code.isLocked else {
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        guard code.codeHash == EmailVerificationCode.hash(of: payload.code) else {
            code.attempts += 1
            try await code.save(on: req.db)
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        user.emailVerified = true
        try await user.save(on: req.db)
        try await EmailVerificationCode.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .delete()

        return try await self.issueTokens(for: user, on: req)
    }

    /// `POST /auth/resend-verification` — issue a fresh code, invalidating
    /// any previous one. Always responds `204`, whether or not the email is
    /// registered or already verified — doesn't reveal which.
    @Sendable
    func resendVerification(req: Request) async throws -> HTTPStatus {
        try ResendVerificationRequest.validate(content: req)
        let payload = try req.content.decode(ResendVerificationRequest.self)
        let email = Self.normalize(payload.email)

        // Per-email, on top of the per-IP limit — otherwise many IPs could
        // still spam one inbox with codes.
        try await RateLimitMiddleware.enforce(
            key: "auth-resend-verification-account:\(email)",
            limit: Self.rateLimit("RATE_LIMIT_RESEND_VERIFICATION", default: 5),
            window: 60,
            on: req
        )

        if let user = try await User.query(on: req.db).filter(\.$email == email).first(),
           !user.emailVerified {
            do {
                try await self.sendVerificationCode(to: user, on: req)
            } catch {
                req.logger.warning("Failed to resend verification email to \(email): \(error)")
            }
        }

        return .noContent
    }

    /// `POST /auth/forgot-password` — issue a password-reset code. Always
    /// responds `204`, whether or not the email is registered — doesn't
    /// reveal which.
    @Sendable
    func forgotPassword(req: Request) async throws -> HTTPStatus {
        try ForgotPasswordRequest.validate(content: req)
        let payload = try req.content.decode(ForgotPasswordRequest.self)
        let email = Self.normalize(payload.email)

        // Per-email, on top of the per-IP limit — otherwise many IPs could
        // still spam one inbox with reset codes.
        try await RateLimitMiddleware.enforce(
            key: "auth-forgot-password-account:\(email)",
            limit: Self.rateLimit("RATE_LIMIT_FORGOT_PASSWORD", default: 5),
            window: 60,
            on: req
        )

        if let user = try await User.query(on: req.db).filter(\.$email == email).first() {
            do {
                try await self.sendPasswordResetCode(to: user, on: req)
            } catch {
                req.logger.warning("Failed to send password-reset email to \(email): \(error)")
            }
        }

        return .noContent
    }

    /// `POST /auth/reset-password` — confirm the code, set the new password,
    /// and log in. Revokes every existing refresh token (same reasoning as
    /// `change-password`: a reset often means the account was at risk) and,
    /// since receiving the code proves inbox ownership, marks the email
    /// verified as a side effect.
    @Sendable
    func resetPassword(req: Request) async throws -> TokenResponse {
        try ResetPasswordRequest.validate(content: req)
        let payload = try req.content.decode(ResetPasswordRequest.self)
        let email = Self.normalize(payload.email)

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first()
        else {
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        guard let code = try await PasswordResetCode.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        guard !code.isExpired, !code.isLocked else {
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        guard code.codeHash == PasswordResetCode.hash(of: payload.code) else {
            code.attempts += 1
            try await code.save(on: req.db)
            throw Abort(.badRequest, reason: "Invalid or expired code")
        }

        user.passwordHash = try Bcrypt.hash(payload.newPassword)
        user.emailVerified = true
        try await user.save(on: req.db)

        try await PasswordResetCode.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .delete()
        try await RefreshToken.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .delete()

        return try await self.issueTokens(for: user, on: req)
    }

    /// `POST /auth/apple` — sign in (or sign up) with a Sign in with Apple
    /// identity token. Apple-only for now (see R-Auth); Google slots in
    /// later behind the same `OAuthIdentity` table.
    @Sendable
    func appleSignIn(req: Request) async throws -> TokenResponse {
        guard let verifier = req.application.appleIdentityVerifier else {
            throw Abort(.serviceUnavailable, reason: "Sign in with Apple is not configured")
        }
        let payload = try req.content.decode(AppleSignInRequest.self)

        let identity: AppleIdentityToken
        do {
            identity = try await verifier.verify(payload.identityToken)
        } catch {
            req.logger.warning("Apple identity token verification failed: \(error)")
            throw Abort(.unauthorized, reason: "Invalid Apple identity token")
        }
        let appleUserID = identity.subject.value

        // Already linked from a previous sign-in — nothing else to do.
        if let link = try await OAuthIdentity.query(on: req.db)
            .filter(\.$provider == "apple")
            .filter(\.$providerUserId == appleUserID)
            .with(\.$user)
            .first()
        {
            return try await self.issueTokens(for: link.user, on: req)
        }

        // First time we've seen this Apple user. Apple only sends the email
        // on the very first authorization for this app — without an
        // existing link and without an email now, there's nothing to
        // identify or create the account by.
        guard let rawEmail = identity.email else {
            throw Abort(.badRequest, reason: "Missing email from Apple — sign in again from the original device")
        }
        let email = Self.normalize(rawEmail)

        // Auto-link to an existing password account with the same email —
        // Apple has already verified it, so this is safe to do silently.
        let user: User
        if let existing = try await User.query(on: req.db).filter(\.$email == email).first() {
            user = existing
            if !user.emailVerified {
                user.emailVerified = true
                try await user.save(on: req.db)
            }
        } else {
            user = User(email: email, passwordHash: nil, emailVerified: true)
            try await user.save(on: req.db)
        }

        let link = OAuthIdentity(userID: try user.requireID(), provider: "apple", providerUserId: appleUserID)
        try await link.save(on: req.db)

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

        // Per-account, on top of the per-IP limit — a stolen access token
        // used from many IPs shouldn't get more guesses at the old password.
        try await RateLimitMiddleware.enforce(
            key: "auth-change-password-account:\(user.email)",
            limit: Self.rateLimit("RATE_LIMIT_LOGIN_PER_ACCOUNT", default: 10),
            window: 60,
            on: req
        )

        // An Apple-only account has no password to change — same message as
        // a wrong one, no need to special-case it for the caller.
        guard let hash = user.passwordHash, try Bcrypt.verify(payload.currentPassword, created: hash) else {
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

    /// Replaces any existing codes for the user with a fresh one and emails it.
    private func sendVerificationCode(to user: User, on req: Request) async throws {
        try await EmailVerificationCode.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .delete()

        let (raw, hash) = EmailVerificationCode.generate()
        let code = EmailVerificationCode(
            userID: try user.requireID(),
            codeHash: hash,
            expiresAt: Date().addingTimeInterval(EmailVerificationCode.lifetime)
        )
        try await code.save(on: req.db)

        try await req.application.emailProvider.send(
            to: user.email,
            subject: "Your Healthside verification code",
            text: "Your verification code is \(raw). It expires in 15 minutes.",
            html: "<p>Your verification code is <strong>\(raw)</strong>. It expires in 15 minutes.</p>"
        )
    }

    /// Replaces any existing reset codes for the user with a fresh one and emails it.
    private func sendPasswordResetCode(to user: User, on req: Request) async throws {
        try await PasswordResetCode.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .delete()

        let (raw, hash) = PasswordResetCode.generate()
        let code = PasswordResetCode(
            userID: try user.requireID(),
            codeHash: hash,
            expiresAt: Date().addingTimeInterval(PasswordResetCode.lifetime)
        )
        try await code.save(on: req.db)

        try await req.application.emailProvider.send(
            to: user.email,
            subject: "Your Healthside password reset code",
            text: "Your password reset code is \(raw). It expires in 15 minutes. If you didn't request this, you can ignore this email.",
            html: "<p>Your password reset code is <strong>\(raw)</strong>. It expires in 15 minutes.</p><p>If you didn't request this, you can ignore this email.</p>"
        )
    }

    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Reads a rate-limit env var the same way `boot(routes:)` does, so a
    /// handler's account-scoped check stays in sync with its route's
    /// IP-scoped one without hoisting shared state onto the struct.
    private static func rateLimit(_ key: String, default def: Int) -> Int {
        Environment.get(key).flatMap(Int.init) ?? def
    }
}
