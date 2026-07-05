import Foundation

/// Extraction pipeline status of an uploaded file (see R-Flow/System-Flow).
/// `processing` marks that a worker has picked the job up.
enum ParseStatus: String, Codable, Sendable {
    case pending
    case processing
    case done
    case failed
}

/// Classifies a parsed document, deciding how its payload is routed
/// (only `labPanel` fans out into the `biomarkers` table).
enum DocumentType: String, Codable, Sendable {
    case labPanel = "lab_panel"
    case imagingReport = "imaging_report"
    case consultNote = "consult_note"
    case other
}

/// A biomarker's value versus its applicable reference range.
enum BiomarkerStatus: String, Codable, Sendable {
    case normal
    case low
    case high
    case critical
    case unknown
}

/// Operator for non-exact results like "<0.8" or ">120".
enum ValueOperator: String, Codable, Sendable {
    case lessThan = "<"
    case greaterThan = ">"
    case equal = "="
}

/// Client platform for a push (FCM) device token.
enum DevicePlatform: String, Codable, Sendable {
    case ios
    case android
    case web
}
