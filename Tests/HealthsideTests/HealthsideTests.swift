@testable import Healthside
import VaporTesting
import Testing
import Fluent
import JWTKit

@Suite("App Tests with DB", .serialized)
struct HealthsideTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            // Real sending is never exercised in tests — capture instead.
            app.emailProvider = CapturingEmailProvider()
            // Never hits Apple's real endpoint — tests configure the stub's
            // response per case via `.set(_:)`.
            app.appleIdentityVerifier = StubAppleIdentityVerifier()
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Hello world route works")
    func helloWorld() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Register creates a user and never leaks the password hash")
    func register() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "Alice@Example.com", password: "supersecret"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let body = res.body.string
                #expect(!body.contains("password"))
                #expect(!body.contains("hash"))

                // Email is normalized to lowercase before storage.
                let user = try await User.query(on: app.db).filter(\.$email == "alice@example.com").first()
                let foundUser = try #require(user)
                let hash = try #require(foundUser.passwordHash)
                #expect(try Bcrypt.verify("supersecret", created: hash))
            })
        }
    }

    @Test("Register rejects a duplicate email")
    func registerDuplicate() async throws {
        try await withApp { app in
            let user = User(email: "bob@example.com", passwordHash: try Bcrypt.hash("supersecret"))
            try await user.save(on: app.db)

            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "bob@example.com", password: "anotherpass"))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Register rejects a short password")
    func registerShortPassword() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "carol@example.com", password: "short"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Login with valid credentials returns an access token")
    func loginSuccess() async throws {
        try await withApp { app in
            let user = User(email: "dave@example.com", passwordHash: try Bcrypt.hash("supersecret"))
            try await user.save(on: app.db)

            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "dave@example.com", password: "supersecret"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let token = try res.content.decode(TokenResponse.self)
                #expect(!token.accessToken.isEmpty)
            })
        }
    }

    @Test("Login is rate limited after too many attempts")
    func loginRateLimited() async throws {
        try await withApp { app in
            let user = User(email: "flood@example.com", passwordHash: try Bcrypt.hash("supersecret"))
            try await user.save(on: app.db)

            // Default limit is 10/min per IP; the 11th attempt must be throttled.
            var statuses: [HTTPStatus] = []
            for _ in 0..<11 {
                try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                    try req.content.encode(AuthRequest(email: "flood@example.com", password: "supersecret"))
                }, afterResponse: { res async in
                    statuses.append(res.status)
                })
            }

            #expect(statuses.first == .ok)
            #expect(statuses.last == .tooManyRequests)
            #expect(statuses.filter { $0 == .tooManyRequests }.count == 1)
        }
    }

    @Test("Login is rate limited per account even when attempts are spread across different IPs")
    func loginRateLimitedPerAccountAcrossIPs() async throws {
        try await withApp { app in
            let user = User(email: "spread@example.com", passwordHash: try Bcrypt.hash("supersecret"))
            try await user.save(on: app.db)

            // Each request comes from a distinct IP — the per-IP limit never
            // trips, but the per-account limit (same target email every
            // time) must still throttle the 11th attempt.
            var statuses: [HTTPStatus] = []
            for i in 0..<11 {
                try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                    req.headers.replaceOrAdd(name: "X-Forwarded-For", value: "203.0.113.\(i)")
                    try req.content.encode(AuthRequest(email: "spread@example.com", password: "wrongpass"))
                }, afterResponse: { res async in
                    statuses.append(res.status)
                })
            }

            #expect(statuses[0..<10].allSatisfy { $0 == .unauthorized })
            #expect(statuses.last == .tooManyRequests)
        }
    }

    @Test("Change password: revokes old sessions, keeps the caller signed in")
    func changePassword() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "chpw@example.com")

            var newTokens: TokenResponse!
            try await app.testing().test(.POST, "auth/change-password", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
                try req.content.encode(ChangePasswordRequest(currentPassword: "supersecret", newPassword: "brandnewpass"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                newTokens = try res.content.decode(TokenResponse.self)
            })
            #expect(!newTokens.refreshToken.isEmpty)

            // The old refresh token is dead — other devices are logged out.
            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: tokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
            // The freshly issued one works — this device stayed signed in.
            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: newTokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // New password logs in; the old one no longer does.
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "chpw@example.com", password: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "chpw@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Change password rejects a wrong current password, a short or unchanged new one, and anonymous callers")
    func changePasswordRejections() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "chpw-bad@example.com")

            // Wrong current password.
            try await app.testing().test(.POST, "auth/change-password", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
                try req.content.encode(ChangePasswordRequest(currentPassword: "notmypassword", newPassword: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
            // New password too short.
            try await app.testing().test(.POST, "auth/change-password", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
                try req.content.encode(ChangePasswordRequest(currentPassword: "supersecret", newPassword: "short"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            // New password identical to the current one.
            try await app.testing().test(.POST, "auth/change-password", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
                try req.content.encode(ChangePasswordRequest(currentPassword: "supersecret", newPassword: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            // No token at all.
            try await app.testing().test(.POST, "auth/change-password", beforeRequest: { req in
                try req.content.encode(ChangePasswordRequest(currentPassword: "supersecret", newPassword: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Login with a wrong password is rejected")
    func loginWrongPassword() async throws {
        try await withApp { app in
            let user = User(email: "erin@example.com", passwordHash: try Bcrypt.hash("supersecret"))
            try await user.save(on: app.db)

            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "erin@example.com", password: "wrongpass"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Email verification

    @Test("Register creates an unverified account; login is blocked until verified")
    func registerBlocksLoginUntilVerified() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "unverified@example.com", password: "supersecret"))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let profile = try res.content.decode(UserResponse.self)
                #expect(profile.emailVerified == false)
            })

            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "unverified@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("Verify-email with the correct code verifies the account and logs in")
    func verifyEmailSuccess() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "verify-ok@example.com")
            #expect(!tokens.accessToken.isEmpty)

            // Now verified — a normal /auth/login also works.
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "verify-ok@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Verify-email rejects a wrong code and leaves the account unverified")
    func verifyEmailWrongCode() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "verify-wrong@example.com", password: "supersecret"))
            })

            try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
                try req.content.encode(VerifyEmailRequest(email: "verify-wrong@example.com", code: "000000"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "verify-wrong@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("Verify-email locks out after 5 wrong attempts, even with the right code")
    func verifyEmailLockout() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "verify-lock@example.com", password: "supersecret"))
            })

            for _ in 0..<EmailVerificationCode.maxAttempts {
                try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
                    try req.content.encode(VerifyEmailRequest(email: "verify-lock@example.com", code: "000000"))
                }, afterResponse: { res async in
                    #expect(res.status == .badRequest)
                })
            }

            let capture = try #require(app.emailProvider as? CapturingEmailProvider)
            let code = try #require(await capture.lastCode(to: "verify-lock@example.com"))
            try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
                try req.content.encode(VerifyEmailRequest(email: "verify-lock@example.com", code: code))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Verify-email rejects an expired code")
    func verifyEmailExpired() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "verify-expired@example.com", password: "supersecret"))
            })

            let user = try #require(await User.query(on: app.db).filter(\.$email == "verify-expired@example.com").first())
            let storedCode = try #require(await EmailVerificationCode.query(on: app.db)
                .filter(\.$user.$id == user.requireID())
                .first())
            storedCode.expiresAt = Date().addingTimeInterval(-60)
            try await storedCode.save(on: app.db)

            let capture = try #require(app.emailProvider as? CapturingEmailProvider)
            let rawCode = try #require(await capture.lastCode(to: "verify-expired@example.com"))
            try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
                try req.content.encode(VerifyEmailRequest(email: "verify-expired@example.com", code: rawCode))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Resend-verification issues a fresh code and invalidates the old one")
    func resendVerification() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "resend@example.com", password: "supersecret"))
            })
            let capture = try #require(app.emailProvider as? CapturingEmailProvider)
            let firstCode = try #require(await capture.lastCode(to: "resend@example.com"))

            try await app.testing().test(.POST, "auth/resend-verification", beforeRequest: { req in
                try req.content.encode(ResendVerificationRequest(email: "resend@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let secondCode = try #require(await capture.lastCode(to: "resend@example.com"))
            #expect(firstCode != secondCode)

            // The old code no longer works — it was invalidated by the resend.
            try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
                try req.content.encode(VerifyEmailRequest(email: "resend@example.com", code: firstCode))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            // The new one works.
            try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
                try req.content.encode(VerifyEmailRequest(email: "resend@example.com", code: secondCode))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Resend-verification always responds 204, whether the email exists, is unknown, or is already verified")
    func resendVerificationDoesNotLeak() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/resend-verification", beforeRequest: { req in
                try req.content.encode(ResendVerificationRequest(email: "nobody@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            _ = try await authenticate(app, email: "already-verified@example.com")
            try await app.testing().test(.POST, "auth/resend-verification", beforeRequest: { req in
                try req.content.encode(ResendVerificationRequest(email: "already-verified@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
        }
    }

    // MARK: - Password reset

    @Test("Reset-password with the correct code sets the new password, logs in, and revokes old sessions")
    func resetPasswordSuccess() async throws {
        try await withApp { app in
            let oldTokens = try await authenticate(app, email: "reset-ok@example.com")

            try await app.testing().test(.POST, "auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: "reset-ok@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let capture = try #require(app.emailProvider as? CapturingEmailProvider)
            let code = try #require(await capture.lastCode(to: "reset-ok@example.com"))

            var newTokens: TokenResponse!
            try await app.testing().test(.POST, "auth/reset-password", beforeRequest: { req in
                try req.content.encode(ResetPasswordRequest(email: "reset-ok@example.com", code: code, newPassword: "brandnewpass"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                newTokens = try res.content.decode(TokenResponse.self)
            })
            #expect(!newTokens.accessToken.isEmpty)

            // The pre-reset refresh token is dead — resetting ends other sessions.
            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: oldTokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            // New password logs in; the old one no longer does.
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "reset-ok@example.com", password: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "reset-ok@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Reset-password rejects a wrong code")
    func resetPasswordWrongCode() async throws {
        try await withApp { app in
            _ = try await authenticate(app, email: "reset-wrong@example.com")

            try await app.testing().test(.POST, "auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: "reset-wrong@example.com"))
            })
            try await app.testing().test(.POST, "auth/reset-password", beforeRequest: { req in
                try req.content.encode(ResetPasswordRequest(email: "reset-wrong@example.com", code: "000000", newPassword: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            // Password is untouched.
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "reset-wrong@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Reset-password locks out after 5 wrong attempts, even with the right code")
    func resetPasswordLockout() async throws {
        try await withApp { app in
            _ = try await authenticate(app, email: "reset-lock@example.com")
            try await app.testing().test(.POST, "auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: "reset-lock@example.com"))
            })

            for _ in 0..<PasswordResetCode.maxAttempts {
                try await app.testing().test(.POST, "auth/reset-password", beforeRequest: { req in
                    try req.content.encode(ResetPasswordRequest(email: "reset-lock@example.com", code: "000000", newPassword: "brandnewpass"))
                }, afterResponse: { res async in
                    #expect(res.status == .badRequest)
                })
            }

            let capture = try #require(app.emailProvider as? CapturingEmailProvider)
            let code = try #require(await capture.lastCode(to: "reset-lock@example.com"))
            try await app.testing().test(.POST, "auth/reset-password", beforeRequest: { req in
                try req.content.encode(ResetPasswordRequest(email: "reset-lock@example.com", code: code, newPassword: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Reset-password rejects an expired code")
    func resetPasswordExpired() async throws {
        try await withApp { app in
            _ = try await authenticate(app, email: "reset-expired@example.com")
            try await app.testing().test(.POST, "auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: "reset-expired@example.com"))
            })

            let dbUser = try #require(await User.query(on: app.db).filter(\.$email == "reset-expired@example.com").first())
            let storedCode = try #require(await PasswordResetCode.query(on: app.db)
                .filter(\.$user.$id == dbUser.requireID())
                .first())
            storedCode.expiresAt = Date().addingTimeInterval(-60)
            try await storedCode.save(on: app.db)

            let capture = try #require(app.emailProvider as? CapturingEmailProvider)
            let code = try #require(await capture.lastCode(to: "reset-expired@example.com"))
            try await app.testing().test(.POST, "auth/reset-password", beforeRequest: { req in
                try req.content.encode(ResetPasswordRequest(email: "reset-expired@example.com", code: code, newPassword: "brandnewpass"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Forgot-password always responds 204, whether or not the email is registered")
    func forgotPasswordDoesNotLeak() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/forgot-password", beforeRequest: { req in
                try req.content.encode(ForgotPasswordRequest(email: "nobody-reset@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
        }
    }

    // MARK: - Sign in with Apple

    @Test("Apple sign-in creates a verified, passwordless account on first authorization")
    func appleSignInCreatesAccount() async throws {
        try await withApp { app in
            let stub = try #require(app.appleIdentityVerifier as? StubAppleIdentityVerifier)
            await stub.set(.success(subject: "apple-subject-1", email: "apple-new@example.com"))

            var tokens: TokenResponse!
            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "whatever"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                tokens = try res.content.decode(TokenResponse.self)
            })
            #expect(!tokens.accessToken.isEmpty)

            let user = try #require(await User.query(on: app.db).filter(\.$email == "apple-new@example.com").first())
            #expect(user.emailVerified)
            #expect(user.passwordHash == nil)

            let link = try #require(await OAuthIdentity.query(on: app.db)
                .filter(\.$providerUserId == "apple-subject-1")
                .first())
            #expect(link.provider == "apple")
        }
    }

    @Test("Apple sign-in logs an already-linked user back in without needing the email again")
    func appleSignInExistingLink() async throws {
        try await withApp { app in
            let stub = try #require(app.appleIdentityVerifier as? StubAppleIdentityVerifier)
            await stub.set(.success(subject: "apple-subject-2", email: "apple-repeat@example.com"))
            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "first"))
            })

            // Apple omits the email on subsequent authorizations — must
            // still work purely off the existing link.
            await stub.set(.success(subject: "apple-subject-2", email: nil))
            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "second"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let userCount = try await User.query(on: app.db).filter(\.$email == "apple-repeat@example.com").count()
            #expect(userCount == 1)
        }
    }

    @Test("Apple sign-in auto-links to an existing password account with the same email")
    func appleSignInLinksExistingPasswordAccount() async throws {
        try await withApp { app in
            _ = try await authenticate(app, email: "hybrid@example.com")

            let stub = try #require(app.appleIdentityVerifier as? StubAppleIdentityVerifier)
            await stub.set(.success(subject: "apple-subject-3", email: "hybrid@example.com"))
            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "whatever"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            // Still exactly one user — Apple linked to the existing account,
            // it didn't create a duplicate.
            let userCount = try await User.query(on: app.db).filter(\.$email == "hybrid@example.com").count()
            #expect(userCount == 1)

            // Password login still works — linking didn't touch the password.
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthRequest(email: "hybrid@example.com", password: "supersecret"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Apple sign-in rejects an invalid identity token")
    func appleSignInInvalidToken() async throws {
        try await withApp { app in
            let stub = try #require(app.appleIdentityVerifier as? StubAppleIdentityVerifier)
            await stub.set(.failure(AppleSignInError.wrongAudience))

            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "garbage"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Apple sign-in for a brand-new user without an email is rejected")
    func appleSignInMissingEmail() async throws {
        try await withApp { app in
            let stub = try #require(app.appleIdentityVerifier as? StubAppleIdentityVerifier)
            await stub.set(.success(subject: "apple-subject-no-email", email: nil))

            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "whatever"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Helpers

    /// Registers, verifies (via the captured code) and returns the issued
    /// token pair — login itself is blocked until verification, so this
    /// replaces the old register→login helper for every other test.
    private func authenticate(
        _ app: Application,
        email: String,
        password: String = "supersecret"
    ) async throws -> TokenResponse {
        try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(AuthRequest(email: email, password: password))
        })

        let capture = try #require(app.emailProvider as? CapturingEmailProvider)
        let code = try #require(await capture.lastCode(to: email.lowercased()))

        var tokens: TokenResponse!
        try await app.testing().test(.POST, "auth/verify-email", beforeRequest: { req in
            try req.content.encode(VerifyEmailRequest(email: email, code: code))
        }, afterResponse: { res async throws in
            tokens = try res.content.decode(TokenResponse.self)
        })
        return tokens
    }

    // MARK: - Refresh & logout

    @Test("Login returns both an access and a refresh token")
    func loginReturnsTokenPair() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "fred@example.com")
            #expect(!tokens.accessToken.isEmpty)
            #expect(!tokens.refreshToken.isEmpty)
        }
    }

    @Test("Refresh issues a new pair and rotates the old refresh token")
    func refreshRotates() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "gina@example.com")

            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: tokens.refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let refreshed = try res.content.decode(TokenResponse.self)
                #expect(!refreshed.refreshToken.isEmpty)
                #expect(refreshed.refreshToken != tokens.refreshToken)
            })

            // The old refresh token is rotated out and no longer accepted.
            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: tokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Logout revokes the refresh token")
    func logoutRevokes() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "hank@example.com")

            try await app.testing().test(.POST, "auth/logout", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: tokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: tokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Protected /me

    @Test("/me returns the profile with a valid access token")
    func meWithValidToken() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "ivy@example.com")

            try await app.testing().test(.GET, "me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let profile = try res.content.decode(UserResponse.self)
                #expect(profile.email == "ivy@example.com")
            })
        }
    }

    @Test("/me is rejected without a token")
    func meWithoutToken() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "me", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Every response carries baseline security headers")
    func securityHeaders() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
                #expect(res.headers.first(name: "Referrer-Policy") == "no-referrer")
            })
        }
    }

    @Test("De-identifier scrubs contact info and IDs but keeps clinical data")
    func deidentifier() {
        // PII is redacted…
        #expect(Deidentifier.scrub("email dr@clinic.com now") == "email \(Deidentifier.redactionToken) now")
        #expect(Deidentifier.scrub("MRN 12345678").contains(Deidentifier.redactionToken))
        #expect(Deidentifier.scrub("+1 (415) 555-1234").contains(Deidentifier.redactionToken))
        // …while clinical values, units and reference ranges are untouched.
        #expect(Deidentifier.scrub("130 - 170") == "130 - 170")
        #expect(Deidentifier.scrub("145 g/L") == "145 g/L")

        // Recursive scrub over a payload: numbers/ranges preserved, string PII gone.
        let envelope: JSONValue = .object([
            "provider": .string("City Lab, dr@lab.com"),
            "value": .number(145),
            "reference_range": .object(["text": .string("130 - 170")]),
        ])
        let scrubbed = Deidentifier.scrub(envelope)
        #expect(scrubbed["provider"]?.stringValue == "City Lab, \(Deidentifier.redactionToken)")
        #expect(scrubbed["value"]?.doubleValue == 145)
        #expect(scrubbed["reference_range"]?["text"]?.stringValue == "130 - 170")
    }

    // MARK: - Lab results

    /// Minimal valid file bytes per type (correct magic bytes).
    private static let pdfBytes: [UInt8] = Array("%PDF-1.4\n%fake pdf body".utf8)
    private static let jpegBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array("JFIF jpeg body".utf8)
    private static let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("png body".utf8)
    // ISO-BMFF header: 4-byte box size, "ftyp", brand "heic", then filler.
    private static let heicBytes: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63] + Array("heic body".utf8)

    // JPEG carrying an APP1 EXIF segment with recognizable "GPS" payload.
    private static let exifJpegBytes: [UInt8] =
        [0xFF, 0xD8]
        + [0xFF, 0xE1, 0x00, 0x10] + Array("Exif\u{0}\u{0}".utf8) + Array("GPSHERE!".utf8)
        + [0xFF, 0xDA, 0x00, 0x08] + Array("SCAN12".utf8)
        + [0xFF, 0xD9]

    // PNG whose IHDR declares 65535×65535 (~4.3 GP) — a decompression bomb.
    private static let hugePngBytes: [UInt8] =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        + [0x00, 0x00, 0x00, 0x0D] + [0x49, 0x48, 0x44, 0x52]
        + [0x00, 0x00, 0xFF, 0xFF] + [0x00, 0x00, 0xFF, 0xFF]
        + [0x08, 0x06, 0x00, 0x00, 0x00] + [0x00, 0x00, 0x00, 0x00]

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        Data(haystack).range(of: Data(needle)) != nil
    }

    private func upload(
        _ app: Application,
        token: String,
        bytes: [UInt8],
        filename: String,
        label: String? = nil
    ) async throws -> (status: HTTPStatus, body: UploadAcceptedResponse?) {
        var status: HTTPStatus = .internalServerError
        var decoded: UploadAcceptedResponse?
        let file = File(data: ByteBuffer(bytes: bytes), filename: filename)
        try await app.testing().test(.POST, "lab-results", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(UploadRequest(file: file, label: label), as: .formData)
        }, afterResponse: { res async throws in
            status = res.status
            if res.status == .accepted {
                decoded = try res.content.decode(UploadAcceptedResponse.self)
            }
        })
        return (status, decoded)
    }

    /// Fetches the document view (status + envelope) for a lab-result id.
    private func documentView(_ app: Application, token: String, id: UUID) async throws -> DocumentView {
        var view: DocumentView!
        try await app.testing().test(.GET, "documents/\(id)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            view = try res.content.decode(DocumentView.self)
        })
        return view
    }

    @Test("Upload a valid PDF (202 pending), list it, download it, delete it")
    func labResultLifecycle() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "jane@example.com")

            let uploaded = try await upload(app, token: tokens.accessToken, bytes: Self.pdfBytes, filename: "analiz.pdf", label: "Helix")
            #expect(uploaded.status == .accepted)
            let documentId = try #require(uploaded.body).documentId
            #expect(try #require(uploaded.body).status == .pending)

            // Document view reflects the pending status and file metadata.
            let view = try await documentView(app, token: tokens.accessToken, id: documentId)
            #expect(view.status == .pending)
            #expect(view.mimeType == "application/pdf")
            #expect(view.fileSize == Self.pdfBytes.count)
            #expect(view.label == "Helix")
            #expect(view.payloadJson == nil)  // no extraction yet

            // List shows exactly the one result, with its status.
            try await app.testing().test(.GET, "lab-results", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let list = try res.content.decode([LabResultResponse].self)
                #expect(list.count == 1)
                #expect(list.first?.id == documentId)
                #expect(list.first?.parseStatus == .pending)
            })

            // Download returns the original bytes as an attachment.
            try await app.testing().test(.GET, "lab-results/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .init(type: "application", subType: "pdf"))
                #expect(res.headers.contentDisposition?.value == .attachment)
                #expect(res.headers.first(name: "Content-Security-Policy") == "default-src 'none'")
                #expect(res.headers.first(name: "Cache-Control") == "no-store")
                #expect(Array(res.body.readableBytesView) == Self.pdfBytes)
            })

            // Delete, then it's gone.
            try await app.testing().test(.DELETE, "lab-results/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            try await app.testing().test(.GET, "lab-results/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Re-uploading the same file is rejected as a duplicate")
    func uploadDedup() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "dup@example.com")
            let first = try await upload(app, token: tokens.accessToken, bytes: Self.pdfBytes, filename: "a.pdf")
            #expect(first.status == .accepted)
            let second = try await upload(app, token: tokens.accessToken, bytes: Self.pdfBytes, filename: "a-again.pdf")
            #expect(second.status == .conflict)
        }
    }

    @Test("Retry on a document already being processed is rejected")
    func retryWhileInFlightIsRejected() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "retry@example.com")
            let uploaded = try await upload(app, token: tokens.accessToken, bytes: Self.pdfBytes, filename: "a.pdf")
            let documentId = try #require(uploaded.body).documentId

            // Fresh upload sits at `pending`, so a retry must not stack a second
            // run (which would call — and bill — the model twice).
            try await app.testing().test(.POST, "documents/\(documentId)/extract", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Retry requires ownership")
    func retryOwnerIsolation() async throws {
        try await withApp { app in
            let owner = try await authenticate(app, email: "r-owner@example.com")
            let attacker = try await authenticate(app, email: "r-attacker@example.com")
            let uploaded = try await upload(app, token: owner.accessToken, bytes: Self.pdfBytes, filename: "a.pdf")
            let documentId = try #require(uploaded.body).documentId

            try await app.testing().test(.POST, "documents/\(documentId)/extract", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: attacker.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("Upload rejects a disallowed file type by its magic bytes")
    func uploadRejectsBadType() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "kyle@example.com")
            // Binary garbage (NUL bytes, no signature) with a .pdf name — rejected.
            let result = try await upload(app, token: tokens.accessToken, bytes: [0x00, 0x01, 0x02, 0xFF, 0x00, 0x99, 0x00], filename: "fake.pdf")
            #expect(result.status == .unsupportedMediaType)
        }
    }

    @Test(
        "Upload accepts each allowed format, detected by magic bytes",
        arguments: [
            (Self.pdfBytes, "doc.pdf", "application/pdf"),
            (Self.jpegBytes, "photo.jpg", "image/jpeg"),
            (Self.pngBytes, "screenshot.png", "image/png"),
            (Self.heicBytes, "iphone.heic", "image/heic"),
            (Array("HEALTHSIDE LAB\nHemoglobin 145 g/L\n".utf8), "report.txt", "text/plain"),
            ([0x50, 0x4B, 0x03, 0x04] + Array("docx zip body".utf8), "report.docx",
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
            ([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array("ole body".utf8), "report.doc",
             "application/msword"),
        ]
    )
    func uploadAcceptsFormat(bytes: [UInt8], filename: String, expectedMime: String) async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "fmt-\(filename)@example.com")
            let result = try await upload(app, token: tokens.accessToken, bytes: bytes, filename: filename)
            #expect(result.status == .accepted)
            let view = try await documentView(app, token: tokens.accessToken, id: #require(result.body).documentId)
            #expect(view.mimeType == expectedMime)
        }
    }

    @Test("Type is taken from bytes, not the filename extension")
    func typeFromBytesNotExtension() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "spoof@example.com")
            // JPEG bytes but a .pdf name — must be stored as image/jpeg.
            let result = try await upload(app, token: tokens.accessToken, bytes: Self.jpegBytes, filename: "totally.pdf")
            #expect(result.status == .accepted)
            let view = try await documentView(app, token: tokens.accessToken, id: #require(result.body).documentId)
            #expect(view.mimeType == "image/jpeg")
        }
    }

    @Test("Upload rejects an image with excessive declared resolution")
    func uploadRejectsHugeResolution() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "bomb@example.com")
            let result = try await upload(app, token: tokens.accessToken, bytes: Self.hugePngBytes, filename: "bomb.png")
            #expect(result.status == .payloadTooLarge)
        }
    }

    @Test("EXIF/GPS metadata is stripped from uploaded images")
    func stripsExif() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "exif@example.com")
            let uploaded = try await upload(app, token: tokens.accessToken, bytes: Self.exifJpegBytes, filename: "photo.jpg")
            let documentId = try #require(uploaded.body).documentId
            let view = try await documentView(app, token: tokens.accessToken, id: documentId)
            #expect(view.mimeType == "image/jpeg")
            // Stored file is smaller than the original — the EXIF block is gone.
            #expect(view.fileSize < Self.exifJpegBytes.count)

            try await app.testing().test(.GET, "lab-results/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                let body = Array(res.body.readableBytesView)
                #expect(!Self.contains(body, Array("GPSHERE!".utf8)))  // GPS payload gone
                #expect(!Self.contains(body, Array("Exif".utf8)))      // EXIF marker gone
                #expect(Self.contains(body, Array("SCAN12".utf8)))     // image data preserved
            })
        }
    }

    @Test("Upload requires authentication")
    func uploadRequiresAuth() async throws {
        try await withApp { app in
            let file = File(data: ByteBuffer(bytes: Self.pdfBytes), filename: "analiz.pdf")
            try await app.testing().test(.POST, "lab-results", beforeRequest: { req in
                try req.content.encode(UploadRequest(file: file, label: nil), as: .formData)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("A user cannot access another user's result")
    func ownerIsolation() async throws {
        try await withApp { app in
            let owner = try await authenticate(app, email: "owner@example.com")
            let attacker = try await authenticate(app, email: "attacker@example.com")

            let uploaded = try await upload(app, token: owner.accessToken, bytes: Self.pngBytes, filename: "scan.png")
            let documentId = try #require(uploaded.body).documentId

            // Attacker can't download it (403, not 404 — the resource exists).
            try await app.testing().test(.GET, "lab-results/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: attacker.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            // Attacker can't delete it.
            try await app.testing().test(.DELETE, "lab-results/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: attacker.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            // Attacker can't see it via the document feed either.
            try await app.testing().test(.GET, "documents/\(documentId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: attacker.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            // Attacker's own list is empty.
            try await app.testing().test(.GET, "lab-results", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: attacker.accessToken)
            }, afterResponse: { res async throws in
                let list = try res.content.decode([LabResultResponse].self)
                #expect(list.isEmpty)
            })
        }
    }
}

/// Captures outgoing verification emails instead of hitting the real Resend
/// API — tests read the code back via `lastCode(to:)`.
actor CapturingEmailProvider: EmailProvider {
    private var sent: [String: [String]] = [:]

    func send(to: String, subject: String, text: String, html: String) async throws {
        sent[to, default: []].append(text)
    }

    /// The 6-digit code from the most recently sent email to `to`.
    func lastCode(to: String) -> String? {
        guard let text = sent[to]?.last else { return nil }
        return text.range(of: #"\d{6}"#, options: .regularExpression).map { String(text[$0]) }
    }
}

/// Stands in for a real Sign in with Apple verification (which would hit
/// Apple's network) — tests configure what the "verified" token looks like,
/// or make it throw, via `set(_:)`.
actor StubAppleIdentityVerifier: AppleIdentityVerifying {
    enum Behavior {
        case success(subject: String, email: String?)
        case failure(any Error)
    }

    private var behavior: Behavior = .failure(AppleSignInError.wrongAudience)

    func set(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func verify(_ identityToken: String) async throws -> AppleIdentityToken {
        switch behavior {
        case .success(let subject, let email):
            return AppleIdentityToken(
                issuer: .init(value: "https://appleid.apple.com"),
                audience: .init(value: "test.healthside.bundle"),
                expires: .init(value: Date().addingTimeInterval(300)),
                issuedAt: .init(value: Date()),
                subject: .init(value: subject),
                email: email
            )
        case .failure(let error):
            throw error
        }
    }
}
