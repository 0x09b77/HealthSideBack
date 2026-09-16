import JWT
import JWTKit
import Vapor

/// Verifies a Sign in with Apple identity token, decoupled from the real
/// Apple network call so tests can substitute a stub (see `AuthController`,
/// which never talks to `AppleIdentityVerifier` directly).
protocol AppleIdentityVerifying: Sendable {
    func verify(_ identityToken: String) async throws -> AppleIdentityToken
}

private struct AppleIdentityVerifierKey: StorageKey {
    typealias Value = any AppleIdentityVerifying
}

extension Application {
    /// `nil` until `configure.swift` sets one (requires `APPLE_BUNDLE_ID`) —
    /// Sign in with Apple is unavailable until then.
    var appleIdentityVerifier: (any AppleIdentityVerifying)? {
        get { self.storage[AppleIdentityVerifierKey.self] }
        set { self.storage[AppleIdentityVerifierKey.self] = newValue }
    }
}

enum AppleSignInError: Error, CustomStringConvertible {
    case wrongAudience
    case keysFetchFailed(status: UInt, body: String)

    var description: String {
        switch self {
        case .wrongAudience: return "Identity token was not issued for this app"
        case .keysFetchFailed(let status, let body): return "Failed to fetch Apple's signing keys (\(status)): \(body)"
        }
    }
}

/// Verifies a Sign in with Apple identity token against Apple's current
/// public keys. Keys are fetched fresh on every call rather than cached —
/// sign-ins are infrequent enough that this isn't worth the staleness risk.
///
/// Issuer and expiry are checked by `AppleIdentityToken.verify(using:)`
/// itself (part of JWTKit) as `keys.verify` decodes it; only the audience
/// (our own bundle ID) is app-specific and checked here.
struct AppleIdentityVerifier: AppleIdentityVerifying {
    let client: any Client
    /// The app's bundle ID (native iOS) — must match the token's `aud` claim.
    let expectedAudience: String

    private static let keysURL = "https://appleid.apple.com/auth/keys"

    func verify(_ identityToken: String) async throws -> AppleIdentityToken {
        let response = try await client.send(ClientRequest(method: .GET, url: URI(string: Self.keysURL)))
        guard response.status == .ok else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            throw AppleSignInError.keysFetchFailed(status: response.status.code, body: body)
        }
        let jwksJSON = response.body.map { String(buffer: $0) } ?? "{}"

        let keys = try await JWTKeyCollection().add(jwksJSON: jwksJSON)
        let payload = try await keys.verify(identityToken, as: AppleIdentityToken.self)

        try payload.audience.verifyIntendedAudience(includes: expectedAudience)
        return payload
    }
}
