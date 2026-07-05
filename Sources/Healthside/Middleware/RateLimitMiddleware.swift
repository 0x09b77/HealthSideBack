import Vapor

/// Limits how often a single client may hit the routes it guards.
///
/// Keyed by client IP within a `scope`, so different route groups (login vs
/// register) have independent budgets. On exceed it returns `429 Too Many
/// Requests` with a `Retry-After` header.
struct RateLimitMiddleware: AsyncMiddleware {
    let limit: Int
    let window: TimeInterval
    let scope: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let key = "\(scope):\(Self.clientIdentifier(request))"
        let decision = await request.application.rateLimiter.record(key: key, limit: limit, window: window)

        switch decision {
        case .allow:
            return try await next.respond(to: request)
        case .deny(let retryAfter):
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .retryAfter, value: String(retryAfter))
            throw Abort(.tooManyRequests, headers: headers, reason: "Too many requests — try again later")
        }
    }

    /// Identifies the client. Behind a reverse proxy (Caddy) the real IP is in
    /// `X-Forwarded-For`; fall back to the socket peer for direct connections.
    static func clientIdentifier(_ request: Request) -> String {
        if let forwarded = request.headers.first(name: "X-Forwarded-For"),
           let first = forwarded.split(separator: ",").first {
            return first.trimmingCharacters(in: .whitespaces)
        }
        return request.remoteAddress?.ipAddress ?? "unknown"
    }
}
