import Foundation

/// JSON Schema for structured-output checkup reports (Anthropic
/// `output_config.format`). Same shape as `checkup-schema-v1`, which the
/// prompt used to spell out inline — clients decode `report` against it.
///
/// Strict-mode rules as in `ExtractionSchema`: every object sets
/// `additionalProperties: false` and lists all its properties in `required`;
/// optionality is a nullable type.
enum CheckupSchema {
    /// Decoded once from the literal below (a compile-time constant we control).
    static let schema: JSONValue = {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }()

    private static let json = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["summary","biomarkers","categories","flags","recommendations","confidence","uncertain_or_unparsed","disclaimers"],
      "properties": {
        "summary": {
          "type": "object",
          "additionalProperties": false,
          "required": ["overall_status","headline","key_findings"],
          "properties": {
            "overall_status": {"type": "string", "enum": ["green","yellow","red"]},
            "headline": {"type": "string", "description": "One-sentence takeaway"},
            "key_findings": {"type": "array", "items": {"type": "string"}}
          }
        },
        "biomarkers": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name","value","unit","reference_range","status","trend","history","interpretation","source_document_id"],
            "properties": {
              "name": {"type": "string"},
              "value": {"type": ["number","null"], "description": "Latest value"},
              "unit": {"type": ["string","null"]},
              "reference_range": {
                "type": "object",
                "additionalProperties": false,
                "required": ["low","high"],
                "properties": {
                  "low": {"type": ["number","null"]},
                  "high": {"type": ["number","null"]}
                }
              },
              "status": {"type": "string", "enum": ["normal","low","high","critical"]},
              "trend": {"type": "string", "enum": ["up","down","stable","unknown"]},
              "history": {
                "type": "array",
                "items": {
                  "type": "object",
                  "additionalProperties": false,
                  "required": ["date","value"],
                  "properties": {
                    "date": {"type": "string", "description": "YYYY-MM-DD"},
                    "value": {"type": ["number","null"]}
                  }
                }
              },
              "interpretation": {"type": "string", "description": "Plain-language meaning for the user"},
              "source_document_id": {"type": "string"}
            }
          }
        },
        "categories": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name","status","marker_names","summary"],
            "properties": {
              "name": {"type": "string", "description": "Clinical category, e.g. Lipid panel"},
              "status": {"type": "string", "enum": ["green","yellow","red"]},
              "marker_names": {"type": "array", "items": {"type": "string"}},
              "summary": {"type": "string"}
            }
          }
        },
        "flags": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["severity","marker_name","message","recommendation"],
            "properties": {
              "severity": {"type": "string", "enum": ["high","medium","low"]},
              "marker_name": {"type": "string"},
              "message": {"type": "string"},
              "recommendation": {"type": "string"}
            }
          }
        },
        "recommendations": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["type","priority","text"],
            "properties": {
              "type": {"type": "string", "enum": ["consult","retest","lifestyle"]},
              "priority": {"type": "integer", "description": "1 = most important"},
              "text": {"type": "string"}
            }
          }
        },
        "confidence": {"type": "number", "description": "0.0-1.0 for the report as a whole"},
        "uncertain_or_unparsed": {"type": "array", "items": {"type": "string"}},
        "disclaimers": {"type": "array", "items": {"type": "string"}}
      }
    }
    """
}
