// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "Healthside",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 🔑 JSON Web Token signing and verification.
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.0"),
        // 🗃 Background job queues.
        .package(url: "https://github.com/vapor/queues.git", from: "1.13.0"),
        // 🔴 Redis driver for Queues.
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.1"),
        // 🗜 Read text out of .docx (zip) files.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: [
        .executableTarget(
            name: "Healthside",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HealthsideTests",
            dependencies: [
                .target(name: "Healthside"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
] }
