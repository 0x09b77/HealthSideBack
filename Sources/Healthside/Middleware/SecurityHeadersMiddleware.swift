import Vapor

/// Adds baseline security headers to every response (including error responses).
///
/// Register at the beginning of the middleware chain so it wraps everything,
/// including Vapor's `ErrorMiddleware`. HSTS is intentionally omitted — it's set
/// by the TLS terminator (Caddy), which knows the connection is actually HTTPS.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        // Don't let browsers MIME-sniff a response into something executable.
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        // This is an API / file host — never meant to be framed.
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        // Don't leak URLs (which may reference resource ids) via the Referer header.
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        return response
    }
}
