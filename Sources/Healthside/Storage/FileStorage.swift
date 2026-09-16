import Foundation
import Vapor

/// Local-filesystem file storage, keyed by an opaque storage key.
///
/// Deliberately a thin abstraction over "write/read/delete bytes by key" so the
/// backing store can later be swapped for MinIO/S3 without touching the
/// controllers (doc §3, §10).
struct FileStorage {
    /// Absolute base directory the files live under (always ends with `/`).
    let directory: String

    /// Resolves storage location from `STORAGE_PATH` or a default under the
    /// app's working directory.
    static func resolveDirectory(for app: Application) -> String {
        let raw = Environment.get("STORAGE_PATH")
            ?? app.directory.workingDirectory + "storage/lab-results"
        return raw.hasSuffix("/") ? raw : raw + "/"
    }

    init(for app: Application) {
        self.directory = Self.resolveDirectory(for: app)
    }

    /// Creates the storage directory if it doesn't exist yet.
    func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }

    func path(for key: String) -> String {
        directory + key
    }

    func exists(key: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: key))
    }

    func write(_ buffer: ByteBuffer, key: String, on req: Request) async throws {
        try await req.fileio.writeFile(buffer, at: path(for: key))
    }

    /// Reads a stored file's bytes. Small files only (lab results ≤ 20 MB).
    func read(key: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path(for: key)))
    }

    func delete(key: String) throws {
        let filePath = path(for: key)
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        try FileManager.default.removeItem(atPath: filePath)
    }
}

extension Request {
    /// File storage configured for this application.
    var fileStorage: FileStorage {
        FileStorage(for: self.application)
    }
}
