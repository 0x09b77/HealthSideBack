import Fluent
import Vapor

struct CheckupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(AccessTokenAuthenticator())
            .grouped("checkup")

        protected.get(use: self.get)
        protected.post("refresh", use: self.refresh)
    }

    /// `GET /checkup` — the latest saved report (cached, 0 API cost). `isFresh`
    /// is false if the user's biomarkers changed since it was generated.
    @Sendable
    func get(req: Request) async throws -> CheckupResponse {
        let userID = try req.auth.require(User.self).requireID()
        let service = try Self.makeService(req)

        guard let latest = try await service.latest(for: userID) else {
            throw Abort(.notFound, reason: "No checkup yet — call POST /checkup/refresh")
        }
        let currentFingerprint = service.fingerprint(of: try await service.biomarkers(for: userID))
        return try CheckupResponse(latest, isFresh: latest.inputFingerprint == currentFingerprint)
    }

    /// `POST /checkup/refresh` — recompute if the data changed (or none exists);
    /// otherwise return the still-valid cached report without spending tokens.
    @Sendable
    func refresh(req: Request) async throws -> CheckupResponse {
        let userID = try req.auth.require(User.self).requireID()
        let service = try Self.makeService(req)

        let currentFingerprint = service.fingerprint(of: try await service.biomarkers(for: userID))
        if let latest = try await service.latest(for: userID), latest.inputFingerprint == currentFingerprint {
            return try CheckupResponse(latest, isFresh: true)  // cache hit — no API call
        }

        let checkup = try await service.generate(for: userID)
        return try CheckupResponse(checkup, isFresh: true)
    }

    private static func makeService(_ req: Request) throws -> CheckupService {
        guard let apiKey = Environment.get("LLM_API_KEY") else {
            throw Abort(.serviceUnavailable, reason: "LLM_API_KEY is not set")
        }
        let model = Environment.get("CHECKUP_MODEL") ?? "claude-haiku-4-5"
        let provider = AnthropicProvider(
            client: req.client,
            apiKey: apiKey,
            modelName: model,
            logger: req.logger
        )
        return CheckupService(provider: provider, db: req.db, logger: req.logger)
    }
}
