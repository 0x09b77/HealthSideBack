import NIOSSL
import Fluent
import FluentPostgresDriver
import Foundation
import JWT
import Vapor

/// configures your application
func configure(_ app: Application) async throws {
    // Serve static files from /Public — hosts the OpenAPI spec and Swagger UI.
    // `defaultFile` lets a directory URL like /docs/ resolve to its index.html.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))

    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: Environment.get("DATABASE_NAME") ?? "vapor_database",
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

    app.migrations.add(CreateUser())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateLabResult())

    // Ensure the local file-storage directory exists before serving uploads.
    try FileStorage(for: app).ensureDirectoryExists()

    // register routes
    try routes(app)
}
