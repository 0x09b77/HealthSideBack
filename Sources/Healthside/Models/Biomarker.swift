import Fluent
import Foundation

/// A single numeric, time-comparable marker extracted from a `lab_panel`
/// document. Feeds trends/charts via SQL without an LLM (see R-Data-Model).
///
/// Note: `value`/`ref_low`/`ref_high` use `Double` (Postgres double precision)
/// rather than `Decimal` — adequate precision for lab values and directly
/// SQL-comparable for trends.
final class Biomarker: Model, @unchecked Sendable {
    static let schema = "biomarkers"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "document_id")
    var document: Document

    /// Standardized (English) marker name.
    @Field(key: "name")
    var name: String

    /// As printed on the form, for cross-checking.
    @Field(key: "original_name")
    var originalName: String

    @OptionalField(key: "code")
    var code: String?

    @OptionalField(key: "value")
    var value: Double?

    @OptionalField(key: "value_operator")
    var valueOperator: ValueOperator?

    @Field(key: "unit")
    var unit: String

    @OptionalField(key: "ref_low")
    var refLow: Double?

    @OptionalField(key: "ref_high")
    var refHigh: Double?

    @OptionalField(key: "ref_text")
    var refText: String?

    @Field(key: "status")
    var status: BiomarkerStatus

    @Field(key: "measured_at")
    var measuredAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        documentID: UUID,
        name: String,
        originalName: String,
        unit: String,
        status: BiomarkerStatus,
        measuredAt: Date,
        value: Double? = nil,
        valueOperator: ValueOperator? = nil,
        code: String? = nil,
        refLow: Double? = nil,
        refHigh: Double? = nil,
        refText: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.$document.id = documentID
        self.name = name
        self.originalName = originalName
        self.unit = unit
        self.status = status
        self.measuredAt = measuredAt
        self.value = value
        self.valueOperator = valueOperator
        self.code = code
        self.refLow = refLow
        self.refHigh = refHigh
        self.refText = refText
    }
}
