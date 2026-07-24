import Fluent
import Queues
import Vapor

struct DocumentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(AccessTokenAuthenticator())
            .grouped("documents")

        protected.get(use: self.list)
        protected.get(":id", use: self.get)
        // Synchronous extraction trigger — for testing the LLM pipeline before
        // the async queue/worker exists. Owner-checked; spends real API tokens.
        protected.on(.POST, ":id", "extract", body: .collect(maxSize: "1mb"), use: self.extract)
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

    /// `POST /documents/:id/extract` — re-run extraction for a document the user
    /// already uploaded (the "Retry" button on a failed document).
    ///
    /// Re-uploading the same file can't work — dedup rejects it with 409 — so this
    /// is the only retry path. Mirrors the upload contract: queues the job and
    /// answers `202 pending`, so the client polls exactly as it does after upload.
    /// `?sync=true` runs it inline instead (debugging aid; blocks on the LLM).
    @Sendable
    func extract(req: Request) async throws -> Response {
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
        // Don't stack a second run on top of one already in flight — that would
        // call the model (and bill) twice for the same document.
        guard labResult.parseStatus != .pending, labResult.parseStatus != .processing else {
            throw Abort(.conflict, reason: "Extraction is already in progress for this document")
        }
        guard let apiKey = Environment.get("LLM_API_KEY") else {
            throw Abort(.serviceUnavailable, reason: "LLM_API_KEY is not set")
        }

        let runInline = (try? req.query.get(Bool.self, at: "sync")) ?? false
        let queueAvailable = Environment.get("REDIS_URL") != nil

        // Default path: hand it to the worker and return immediately.
        if queueAvailable && !runInline {
            labResult.parseStatus = .pending
            try await labResult.save(on: req.db)
            try await req.queue.dispatch(ExtractionJob.self, .init(labResultID: id), maxRetryCount: 3)

            let accepted = UploadAcceptedResponse(documentId: id, status: .pending)
            return try await accepted.encodeResponse(status: .accepted, for: req)
        }

        // Inline path: `?sync=true`, or no queue configured at all.
        let provider = AnthropicProvider(
            client: req.client,
            apiKey: apiKey,
            modelName: "claude-haiku-4-5",
            logger: req.logger
        )
        let service = ExtractionService(
            provider: provider,
            db: req.db,
            storage: req.fileStorage,
            logger: req.logger
        )

        let document = try await service.extract(labResult: labResult)
        let view = try DocumentView(labResult: labResult, document: document)
        return try await view.encodeResponse(status: .ok, for: req)
    }
}
