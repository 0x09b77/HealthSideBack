import Foundation

/// Best-effort de-identification of extracted data before it is stored, so we
/// keep as little PII at rest as possible (HIPAA Safe Harbor posture).
///
/// Scope and limits (see R-Compliance and healthside-decisions):
/// - Account data (email, name, user_id) is never sent to the model or mixed
///   into extraction — we only send the file bytes. This is a structural
///   guarantee, not something this type enforces.
/// - This scrubs high-confidence PII patterns (emails, phone numbers, long
///   digit runs like MRN/SSN/passport/card) from stored free text. It is
///   deliberately conservative to avoid corrupting clinical values, units, or
///   reference ranges (which never contain 7+ consecutive digits).
/// - It does NOT catch names — regex can't reliably. Names rely on the model's
///   "omit PII" instruction plus the BAA with the LLM provider as backstop.
enum Deidentifier {
    static let redactionToken = "[REDACTED]"

    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // Email
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            // International phone: must start with '+' to avoid matching ranges
            #"\+\d[\d ()\-.]{6,}\d"#,
            // 7+ consecutive digits (MRN / SSN / passport / card / bare phone)
            #"\d{7,}"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Replaces high-confidence PII patterns in a string with the redaction token.
    static func scrub(_ text: String) -> String {
        var result = text
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: redactionToken
            )
        }
        return result
    }

    /// Recursively scrubs every string leaf of a JSON payload. Numbers, bools
    /// and structure are untouched, so biomarker values/units/ranges survive.
    static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(scrub(text))
        case .array(let items):
            return .array(items.map(scrub))
        case .object(let object):
            return .object(object.mapValues(scrub))
        case .null, .bool, .number:
            return value
        }
    }
}
