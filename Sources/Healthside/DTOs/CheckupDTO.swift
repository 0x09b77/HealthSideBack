import Fluent
import Vapor

/// A checkup report returned to the client. `isFresh` tells whether the report
/// still reflects the user's current biomarker set (false = data changed since,
/// call POST /checkup/refresh).
struct CheckupResponse: Content {
    let id: UUID
    let report: JSONValue
    let model: String
    let promptVersion: String
    let schemaVersion: String
    let sourceDocumentIds: [UUID]
    let isFresh: Bool
    let createdAt: Date?

    init(_ checkup: Checkup, isFresh: Bool) throws {
        self.id = try checkup.requireID()
        self.report = checkup.reportJson
        self.model = checkup.model
        self.promptVersion = checkup.promptVersion
        self.schemaVersion = checkup.schemaVersion
        self.sourceDocumentIds = checkup.sourceDocumentIds
        self.isFresh = isFresh
        self.createdAt = checkup.createdAt
    }
}
