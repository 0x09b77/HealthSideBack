import Fluent
import FluentSQL
import SQLKit

/// Additive migration: adds the extraction-pipeline fields to `lab_results`
/// (see R-Data-Model). New nullable columns plus `parse_status` defaulting to
/// `pending` so existing rows backfill safely.
struct AddExtractionFieldsToLabResults: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("lab_results")
            .field("parse_status", .string, .required, .sql(.default("pending")))
            .field("page_count", .int)
            .field("preview_key", .string)
            .field("normalized_key", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("lab_results")
            .deleteField("parse_status")
            .deleteField("page_count")
            .deleteField("preview_key")
            .deleteField("normalized_key")
            .update()
    }
}
