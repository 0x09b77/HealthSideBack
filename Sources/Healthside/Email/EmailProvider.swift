import Vapor

/// Provider-agnostic email interface, mirroring `LLMProvider` — the backing
/// service (Resend, SES, Postmark, …) is a config choice, not a code choice.
protocol EmailProvider: Sendable {
    func send(to: String, subject: String, text: String, html: String) async throws
}

enum EmailError: Error, CustomStringConvertible {
    case requestFailed(status: UInt, body: String)

    var description: String {
        switch self {
        case .requestFailed(let status, let body): return "Email request failed (\(status)): \(body)"
        }
    }
}

/// Fallback used when no provider is configured (no `RESEND_API_KEY`, e.g. in
/// local dev or tests). Logs instead of sending so registration still works —
/// the code just never leaves the server.
struct NullEmailProvider: EmailProvider {
    let logger: Logger

    func send(to: String, subject: String, text: String, html: String) async throws {
        logger.warning("Email provider not configured — not sending \"\(subject)\" to \(to)")
    }
}

private struct EmailProviderKey: StorageKey {
    typealias Value = any EmailProvider
}

extension Application {
    /// The configured email provider. Defaults to `NullEmailProvider` (logs
    /// only) until `configure.swift` sets a real one.
    var emailProvider: any EmailProvider {
        get { self.storage[EmailProviderKey.self] ?? NullEmailProvider(logger: self.logger) }
        set { self.storage[EmailProviderKey.self] = newValue }
    }
}
