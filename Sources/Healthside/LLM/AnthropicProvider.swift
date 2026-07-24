import Foundation
import Vapor

/// Calls the Claude Messages API (`POST /v1/messages`) directly over HTTP —
/// Anthropic has no official Swift SDK, so raw HTTP is the supported path.
/// The API key comes only from the environment (never logged).
struct AnthropicProvider: LLMProvider {
    let client: any Client
    let apiKey: String
    let modelName: String
    let logger: Logger

    private let endpoint = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"

    func complete(system: String, content: [LLMContent], maxTokens: Int, jsonSchema: JSONValue?) async throws -> LLMResult {
        let requestBody = Request(
            model: modelName,
            max_tokens: maxTokens,
            system: system,
            messages: [.init(role: "user", content: content.map(Block.init))],
            output_config: jsonSchema.map { Request.OutputConfig(format: .init(schema: $0)) }
        )

        var headers = HTTPHeaders()
        headers.add(name: "x-api-key", value: apiKey)
        headers.add(name: "anthropic-version", value: apiVersion)
        headers.contentType = .json

        let bodyData = try JSONEncoder().encode(requestBody)
        let clientRequest = ClientRequest(
            method: .POST,
            url: URI(string: endpoint),
            headers: headers,
            body: ByteBuffer(bytes: bodyData)
        )

        let response = try await client.send(clientRequest)

        guard response.status == .ok else {
            // Body may carry an error reason; the API key is never echoed back.
            let body = response.body.map { String(buffer: $0) } ?? ""
            logger.warning("Anthropic request failed: \(response.status.code)")
            throw LLMError.requestFailed(status: response.status.code, body: body)
        }

        let decoded = try response.content.decode(APIResponse.self)
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()

        guard !text.isEmpty else { throw LLMError.emptyResponse }

        // Hitting the ceiling truncates the payload mid-structure. Surface that
        // directly instead of letting it masquerade as a JSON parse failure.
        if decoded.stop_reason == "max_tokens" {
            logger.warning("LLM output truncated at max_tokens (\(decoded.usage.output_tokens))")
            throw LLMError.outputTruncated(outputTokens: decoded.usage.output_tokens)
        }

        return LLMResult(
            text: text,
            model: decoded.model,
            inputTokens: decoded.usage.input_tokens,
            outputTokens: decoded.usage.output_tokens,
            stopReason: decoded.stop_reason
        )
    }

    // MARK: - Wire types

    private struct Request: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        /// Structured outputs (json_schema). Omitted from the wire when nil.
        let output_config: OutputConfig?

        struct Message: Encodable {
            let role: String
            let content: [Block]
        }

        struct OutputConfig: Encodable {
            let format: Format
            struct Format: Encodable {
                let type = "json_schema"
                let schema: JSONValue
            }
        }
    }

    /// A content block, encoded to the Messages API shape.
    private enum Block: Encodable {
        case text(String)
        case image(mediaType: String, data: String)
        case document(data: String)

        init(_ content: LLMContent) {
            switch content {
            case .text(let value): self = .text(value)
            case .image(let base64, let mediaType): self = .image(mediaType: mediaType, data: base64)
            case .pdf(let base64): self = .document(data: base64)
            }
        }

        private enum CodingKeys: String, CodingKey { case type, text, source }
        private struct Source: Encodable { let type: String; let media_type: String; let data: String }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .text)
            case .image(let mediaType, let data):
                try container.encode("image", forKey: .type)
                try container.encode(Source(type: "base64", media_type: mediaType, data: data), forKey: .source)
            case .document(let data):
                try container.encode("document", forKey: .type)
                try container.encode(Source(type: "base64", media_type: "application/pdf", data: data), forKey: .source)
            }
        }
    }

    private struct APIResponse: Content {
        let model: String
        let stop_reason: String?
        let content: [ContentBlock]
        let usage: Usage

        struct ContentBlock: Content {
            let type: String
            let text: String?
        }
        struct Usage: Content {
            let input_tokens: Int
            let output_tokens: Int
        }
    }
}
