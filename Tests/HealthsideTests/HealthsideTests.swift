@testable import Healthside
import VaporTesting
import Testing
import Fluent

@Suite("App Tests with DB", .serialized)
struct HealthsideTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
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
                #expect(user != nil)
                #expect(try Bcrypt.verify("supersecret", created: #require(user).passwordHash))
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

    // MARK: - Helpers

    /// Registers and logs in a user, returning the issued token pair.
    private func authenticate(
        _ app: Application,
        email: String,
        password: String = "supersecret"
    ) async throws -> TokenResponse {
        try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(AuthRequest(email: email, password: password))
        })
        var tokens: TokenResponse!
        try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
            try req.content.encode(AuthRequest(email: email, password: password))
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

    // MARK: - Lab results

    /// Minimal valid file bytes per type (correct magic bytes).
    private static let pdfBytes: [UInt8] = Array("%PDF-1.4\n%fake pdf body".utf8)
    private static let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("png body".utf8)

    private func upload(
        _ app: Application,
        token: String,
        bytes: [UInt8],
        filename: String,
        label: String? = nil
    ) async throws -> (status: HTTPStatus, body: LabResultResponse?) {
        var status: HTTPStatus = .internalServerError
        var decoded: LabResultResponse?
        let file = File(data: ByteBuffer(bytes: bytes), filename: filename)
        try await app.testing().test(.POST, "lab-results", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(UploadRequest(file: file, label: label), as: .formData)
        }, afterResponse: { res async throws in
            status = res.status
            if res.status == .created {
                decoded = try res.content.decode(LabResultResponse.self)
            }
        })
        return (status, decoded)
    }

    @Test("Upload a valid PDF, list it, download it, delete it")
    func labResultLifecycle() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "jane@example.com")

            let uploaded = try await upload(app, token: tokens.accessToken, bytes: Self.pdfBytes, filename: "analiz.pdf", label: "Helix")
            #expect(uploaded.status == .created)
            let meta = try #require(uploaded.body)
            #expect(meta.mimeType == "application/pdf")
            #expect(meta.fileSize == Self.pdfBytes.count)
            #expect(meta.label == "Helix")

            // List shows exactly the one result.
            try await app.testing().test(.GET, "lab-results", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let list = try res.content.decode([LabResultResponse].self)
                #expect(list.count == 1)
                #expect(list.first?.id == meta.id)
            })

            // Download returns the original bytes as an attachment.
            try await app.testing().test(.GET, "lab-results/\(meta.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .init(type: "application", subType: "pdf"))
                #expect(res.headers.contentDisposition?.value == .attachment)
                #expect(Array(res.body.readableBytesView) == Self.pdfBytes)
            })

            // Delete, then it's gone.
            try await app.testing().test(.DELETE, "lab-results/\(meta.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            try await app.testing().test(.GET, "lab-results/\(meta.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: tokens.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Upload rejects a disallowed file type by its magic bytes")
    func uploadRejectsBadType() async throws {
        try await withApp { app in
            let tokens = try await authenticate(app, email: "kyle@example.com")
            // A .pdf name but plain-text bytes — must be rejected on content.
            let result = try await upload(app, token: tokens.accessToken, bytes: Array("just text".utf8), filename: "fake.pdf")
            #expect(result.status == .unsupportedMediaType)
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
            let meta = try #require(uploaded.body)

            // Attacker can't download it (403, not 404 — the resource exists).
            try await app.testing().test(.GET, "lab-results/\(meta.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: attacker.accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            // Attacker can't delete it.
            try await app.testing().test(.DELETE, "lab-results/\(meta.id)", beforeRequest: { req in
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
