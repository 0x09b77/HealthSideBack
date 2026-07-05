import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    // Convenience redirect so /docs (no trailing slash) reaches the Swagger UI.
    app.get("docs") { req async -> Response in
        req.redirect(to: "/docs/")
    }

    try app.register(collection: AuthController())
    try app.register(collection: UserController())
    try app.register(collection: LabResultController())
    try app.register(collection: DocumentController())
}
