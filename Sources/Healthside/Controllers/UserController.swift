import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(AccessTokenAuthenticator())
        protected.get("me", use: self.me)
    }

    /// `GET /me` — profile of the currently authenticated user.
    @Sendable
    func me(req: Request) async throws -> UserResponse {
        let user = try req.auth.require(User.self)
        return try user.toResponse()
    }
}
