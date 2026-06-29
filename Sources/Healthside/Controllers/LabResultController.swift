import Crypto
import Fluent
import Foundation
import Vapor

struct LabResultController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(AccessTokenAuthenticator())
            .grouped("lab-results")

        // Allow a body large enough for the 20 MB file limit (plus multipart overhead).
        protected.on(.POST, body: .collect(maxSize: "25mb"), use: self.upload)
        protected.get(use: self.list)
        protected.get(":id", use: self.download)
        protected.delete(":id", use: self.delete)
    }

    /// `POST /lab-results` — upload a file (multipart) with an optional label.
    @Sendable
    func upload(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let payload = try req.content.decode(UploadRequest.self)
        let file = payload.file

        let data = Data(file.data.readableBytesView)
        guard !data.isEmpty else {
            throw Abort(.badRequest, reason: "Empty file")
        }
        guard data.count <= AllowedFileType.maxFileSize else {
            throw Abort(.payloadTooLarge, reason: "File exceeds the 20 MB limit")
        }

        // Trust the bytes, not the client's filename or Content-Type.
        guard let type = AllowedFileType.detect(from: Array(data.prefix(16))) else {
            throw Abort(.unsupportedMediaType, reason: "Only PDF, JPEG, PNG and HEIC are accepted")
        }

        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let storageKey = UUID().uuidString

        let storage = req.fileStorage
        try await storage.write(ByteBuffer(bytes: data), key: storageKey, on: req)

        let result = LabResult(
            userID: try user.requireID(),
            originalFilename: Self.sanitizeFilename(file.filename),
            storageKey: storageKey,
            mimeType: type.mimeType,
            fileSize: data.count,
            checksumSha256: checksum,
            label: payload.label
        )

        do {
            try await result.save(on: req.db)
        } catch {
            // Don't leave an orphaned file if the metadata write fails.
            try? storage.delete(key: storageKey)
            throw error
        }

        return try await result.toResponse().encodeResponse(status: .created, for: req)
    }

    /// `GET /lab-results` — metadata of the current user's own results, newest first.
    @Sendable
    func list(req: Request) async throws -> [LabResultResponse] {
        let user = try req.auth.require(User.self)
        let results = try await LabResult.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .sort(\.$uploadedAt, .descending)
            .all()
        return try results.map { try $0.toResponse() }
    }

    /// `GET /lab-results/:id` — stream the file back to its owner.
    @Sendable
    func download(req: Request) async throws -> Response {
        let result = try await self.ownedResult(req: req)

        let storage = req.fileStorage
        guard storage.exists(key: result.storageKey) else {
            throw Abort(.notFound)
        }

        let response = try await req.fileio.asyncStreamFile(
            at: storage.path(for: result.storageKey),
            mediaType: Self.mediaType(for: result.mimeType)
        )

        // Force download instead of in-browser rendering — a defense against
        // active content (PDF JS, etc.) running in our origin.
        response.headers.contentDisposition = .init(.attachment, filename: result.originalFilename)
        return response
    }

    /// `DELETE /lab-results/:id` — remove the file and its metadata.
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let result = try await self.ownedResult(req: req)
        try? req.fileStorage.delete(key: result.storageKey)
        try await result.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    /// Loads a lab result by `:id` and enforces that it belongs to the caller.
    ///
    /// This owner check is the single most important rule for medical data —
    /// every handler that touches a result goes through here (doc §7.3).
    private func ownedResult(req: Request) async throws -> LabResult {
        let user = try req.auth.require(User.self)
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        guard let result = try await LabResult.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        guard result.$user.id == (try user.requireID()) else {
            throw Abort(.forbidden)
        }
        return result
    }

    private static func mediaType(for mime: String) -> HTTPMediaType {
        let parts = mime.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return .binary }
        return HTTPMediaType(type: String(parts[0]), subType: String(parts[1]))
    }

    /// Strips path components and control characters so the original filename is
    /// safe to echo back in a header and to display.
    private static func sanitizeFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "file" : cleaned
    }
}
