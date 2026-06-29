import Fluent
import JWT
import Vapor

/// Middleware that protects routes with the access token (JWT).
///
/// It verifies the token's signature and expiry (stateless — no DB hit for the
/// check itself), then loads the owning user and authenticates the request.
/// Group protected routes under this middleware instead of repeating the check
/// in every handler.
struct AccessTokenAuthenticator: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let payload: UserToken
        do {
            payload = try await request.jwt.verify(as: UserToken.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired access token")
        }

        guard let userID = UUID(uuidString: payload.subject.value),
              let user = try await User.find(userID, on: request.db)
        else {
            throw Abort(.unauthorized, reason: "Invalid or expired access token")
        }

        request.auth.login(user)
        return try await next.respond(to: request)
    }
}
