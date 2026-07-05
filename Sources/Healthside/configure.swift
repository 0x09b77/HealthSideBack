import NIOSSL
import Fluent
import FluentPostgresDriver
import Foundation
import JWT
import Vapor

/// configures your application
func configure(_ app: Application) async throws {
    // Security headers on every response — added first so it wraps even error
    // responses produced by ErrorMiddleware.
    app.middleware.use(SecurityHeadersMiddleware(), at: .beginning)

    // Serve static files from /Public — hosts the OpenAPI spec and Swagger UI.
    // `defaultFile` lets a directory URL like /docs/ resolve to its index.html.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))

    // Tests run against a dedicated database so `autoRevert()` never wipes the
    // dev schema. The test DB name is independent of DATABASE_NAME on purpose.
    let databaseName: String
    if app.environment == .testing {
        databaseName = Environment.get("DATABASE_NAME_TEST") ?? "vapor_test"
    } else {
        databaseName = Environment.get("DATABASE_NAME") ?? "vapor_database"
    }

    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: databaseName,
        tls: .prefer(try .init(configuration: .clientDefault)))
    ), as: .psql)

    // JWT signing key. The secret only ever comes from the environment —
    // never hardcoded or committed. A leaked secret lets anyone forge tokens.
    let jwtSecret: String
    if let secret = Environment.get("JWT_SECRET") {
        jwtSecret = secret
    } else if app.environment == .production {
        fatalError("JWT_SECRET environment variable must be set in production")
    } else {
        app.logger.warning("JWT_SECRET not set — using an insecure development secret")
        jwtSecret = "insecure-dev-secret-do-not-use-in-production"
    }
    await app.jwt.keys.add(hmac: .init(from: Data(jwtSecret.utf8)), digestAlgorithm: .sha256)

    // Order respects foreign keys (parent before child) — see R-Data-Model.
    app.migrations.add(CreateUser())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateDeviceToken())
    app.migrations.add(CreateLabResult())
    app.migrations.add(AddExtractionFieldsToLabResults())
    app.migrations.add(CreateDocument())
    app.migrations.add(CreateBiomarker())
    app.migrations.add(CreateCheckup())

    // Ensure the local file-storage directory exists before serving uploads.
    try FileStorage(for: app).ensureDirectoryExists()

    // register routes
    try routes(app)
}
