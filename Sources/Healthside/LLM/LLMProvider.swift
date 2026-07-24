import Vapor

/// A piece of user content sent to the model.
enum LLMContent: Sendable {
    case text(String)
    /// Base64-encoded image; `mediaType` is `image/jpeg` or `image/png`.
    case image(base64: String, mediaType: String)
    /// Base64-encoded PDF (`application/pdf`) — read natively by the model.
    case pdf(base64: String)
}

/// Result of a completion, including token usage for cost tracking.
struct LLMResult: Sendable {
    let text: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// Why generation stopped — `max_tokens` means the output was cut off.
    let stopReason: String?
}

/// Provider-agnostic LLM interface. Implementations live behind this so the
/// backing model/provider is a config choice (see R-LLM-Providers).
protocol LLMProvider: Sendable {
    var modelName: String { get }
    /// When `jsonSchema` is provided, the provider constrains the model to emit
    /// JSON matching that schema (structured outputs); otherwise it's free text.
    func complete(system: String, content: [LLMContent], maxTokens: Int, jsonSchema: JSONValue?) async throws -> LLMResult
}

extension LLMProvider {
    func complete(system: String, content: [LLMContent], maxTokens: Int) async throws -> LLMResult {
        try await complete(system: system, content: content, maxTokens: maxTokens, jsonSchema: nil)
    }
}

enum LLMError: Error, CustomStringConvertible {
    case notConfigured
    case requestFailed(status: UInt, body: String)
    case emptyResponse
    /// Generation hit `max_tokens`, so the payload is cut off mid-structure.
    /// Retrying is pointless — the limit has to go up.
    case outputTruncated(outputTokens: Int)

    var description: String {
        switch self {
        case .notConfigured: return "LLM provider is not configured (missing API key)"
        case .requestFailed(let status, let body): return "LLM request failed (\(status)): \(body)"
        case .emptyResponse: return "LLM returned no text content"
        case .outputTruncated(let tokens):
            return "LLM output was truncated at the \(tokens)-token limit; raise max_tokens for this document"
        }
    }
}
