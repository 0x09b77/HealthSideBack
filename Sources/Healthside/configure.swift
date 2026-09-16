import NIOSSL
import Fluent
import FluentPostgresDriver
import Foundation
import JWT
import Queues
import QueuesRedisDriver
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

    // Managed Postgres (e.g. Railway's private network) presents a
    // self-signed/internal certificate that isn't in the image's trusted CA
    // store — full verification fails the handshake there. The connection is
    // already confined to the host's private network, so skip verification
    // rather than pin a provider-specific CA.
    var dbTLSConfig = TLSConfiguration.makeClientConfiguration()
    dbTLSConfig.certificateVerification = .none

    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: databaseName,
        tls: .prefer(try .init(configuration: dbTLSConfig)))
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
    app.migrations.add(AddEmailVerifiedToUsers())
    app.migrations.add(CreateEmailVerificationCode())
    app.migrations.add(CreatePasswordResetCode())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateDeviceToken())
    app.migrations.add(CreateLabResult())
    app.migrations.add(AddExtractionFieldsToLabResults())
    app.migrations.add(CreateDocument())
    app.migrations.add(CreateBiomarker())
    app.migrations.add(CreateCheckup())

    // Verification emails (see R-Auth). Without a key, `emailProvider`
    // defaults to logging instead of sending — registration still works, the
    // code just never leaves the server (fine for local dev/tests).
    if let resendKey = Environment.get("RESEND_API_KEY") {
        let from = Environment.get("MAIL_FROM") ?? "Healthside <onboarding@resend.dev>"
        app.emailProvider = ResendProvider(client: app.client, apiKey: resendKey, from: from, logger: app.logger)
    } else if app.environment != .testing {
        app.logger.warning("RESEND_API_KEY not set — verification emails will only be logged")
    }

    // Ensure the local file-storage directory exists before serving uploads.
    try FileStorage(for: app).ensureDirectoryExists()

    // Background jobs (extraction/checkup) run on Redis via Vapor Queues.
    // Configured only when REDIS_URL is set — without it, uploads still succeed
    // but stay `pending` (the /extract endpoint remains as a manual fallback).
    if let redisURL = Environment.get("REDIS_URL") {
        // Explicit pool: the driver's default is only 2 connections per event
        // loop, so the worker's blocking queue-poll can starve job execution of
        // a connection ("timedOutWaitingForConnection"). Give it headroom.
        let redisConfig = try RedisConfiguration(
            url: redisURL,
            pool: .init(
                maximumConnectionCount: .maximumActiveConnections(8),
                connectionRetryTimeout: .seconds(10)
            )
        )
        app.queues.use(.redis(redisConfig))
        app.queues.add(ExtractionJob())
    }

    // register routes
    try routes(app)
}
