import Foundation
import Vapor

/// Sends email via the Resend REST API (`POST /emails`). Resend has no
/// official Swift SDK, so this is raw HTTP — same approach as
/// `AnthropicProvider`.
///
/// Note: without a verified sending domain on the Resend account, `from`
/// must be the sandbox address (`onboarding@resend.dev`) and mail can only
/// reach the account's own verified address — fine for testing, not for
/// real users until a domain is verified.
struct ResendProvider: EmailProvider {
    let client: any Client
    let apiKey: String
    let from: String
    let logger: Logger

    private let endpoint = "https://api.resend.com/emails"

    func send(to: String, subject: String, text: String, html: String) async throws {
        let requestBody = Request(from: from, to: [to], subject: subject, text: text, html: html)

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: apiKey)
        headers.contentType = .json

        let bodyData = try JSONEncoder().encode(requestBody)
        let clientRequest = ClientRequest(
            method: .POST,
            url: URI(string: endpoint),
            headers: headers,
            body: ByteBuffer(bytes: bodyData)
        )

        let response = try await client.send(clientRequest)

        guard (200..<300).contains(response.status.code) else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            logger.warning("Resend request failed: \(response.status.code)")
            throw EmailError.requestFailed(status: response.status.code, body: body)
        }
    }

    private struct Request: Encodable {
        let from: String
        let to: [String]
        let subject: String
        let text: String
        let html: String
    }
}
