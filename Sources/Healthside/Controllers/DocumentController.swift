import Fluent
import Vapor

struct DocumentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(AccessTokenAuthenticator())
            .grouped("documents")

        protected.get(use: self.list)
        protected.get(":id", use: self.get)
    }

    /// `GET /documents` — the user's processing/extraction feed, newest first.
    @Sendable
    func list(req: Request) async throws -> [DocumentView] {
        let userID = try req.auth.require(User.self).requireID()

        let labResults = try await LabResult.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$uploadedAt, .descending)
            .all()

        let documents = try await Document.query(on: req.db)
            .filter(\.$user.$id == userID)
            .all()
        let documentByLabResult = Dictionary(
            documents.map { ($0.$labResult.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return try labResults.map { labResult in
            try DocumentView(labResult: labResult, document: documentByLabResult[labResult.requireID()])
        }
    }

    /// `GET /documents/:id` — status and (when done) the extracted envelope.
    /// `:id` is the lab-result id returned at upload.
    @Sendable
    func get(req: Request) async throws -> DocumentView {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        guard let labResult = try await LabResult.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        guard labResult.$user.id == userID else {
            throw Abort(.forbidden)
        }

        let document = try await Document.query(on: req.db)
            .filter(\.$labResult.$id == id)
            .first()

        return try DocumentView(labResult: labResult, document: document)
    }
}
