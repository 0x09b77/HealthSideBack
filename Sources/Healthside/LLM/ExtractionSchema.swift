import Foundation

/// JSON Schema for structured-output extraction (Anthropic `output_config.format`).
///
/// Strict-mode rules: every object sets `additionalProperties: false` and lists
/// all its properties in `required`; optionality is expressed as a nullable type
/// (no `minLength`/`minimum`/etc., which structured outputs reject).
enum ExtractionSchema {
    /// Decoded once from the literal below (a compile-time constant we control).
    static let schema: JSONValue = {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }()

    private static let json = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["document_type","report_date","provider","summary","diagnosis","biomarkers","measurements","uncertain_or_unparsed","contains_pii"],
      "properties": {
        "document_type": {"type": "string", "enum": ["lab_panel","imaging_report","consult_note","other","unrelated"]},
        "report_date": {"type": ["string","null"]},
        "provider": {"type": ["string","null"]},
        "summary": {"type": ["string","null"]},
        "diagnosis": {"type": ["string","null"]},
        "biomarkers": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name","original_name","value","value_operator","value_type","unit","original_unit","reference_range","status","measured_at","confidence","notes"],
            "properties": {
              "name": {"type": "string"},
              "original_name": {"type": "string"},
              "value": {"type": ["number","string","null"]},
              "value_operator": {"enum": ["<",">","=",null]},
              "value_type": {"type": "string", "enum": ["numeric","qualitative","semiquantitative"]},
              "unit": {"type": ["string","null"]},
              "original_unit": {"type": ["string","null"]},
              "reference_range": {
                "type": "object",
                "additionalProperties": false,
                "required": ["low","high","text"],
                "properties": {
                  "low": {"type": ["number","null"]},
                  "high": {"type": ["number","null"]},
                  "text": {"type": ["string","null"]}
                }
              },
              "status": {"type": "string", "enum": ["normal","low","high","critical","unknown"]},
              "measured_at": {"type": ["string","null"]},
              "confidence": {"type": "number"},
              "notes": {"type": ["string","null"]}
            }
          }
        },
        "measurements": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name","value","unit"],
            "properties": {
              "name": {"type": "string"},
              "value": {"type": ["string","null"]},
              "unit": {"type": ["string","null"]}
            }
          }
        },
        "uncertain_or_unparsed": {"type": "array", "items": {"type": "string"}},
        "contains_pii": {"type": "boolean"}
      }
    }
    """
}
