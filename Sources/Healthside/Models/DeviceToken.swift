import Fluent
import Foundation

/// A device's Firebase (FCM) push token. Registered on login, pruned when
/// stale or on logout (see R-Flow/System-Flow).
final class DeviceToken: Model, @unchecked Sendable {
    static let schema = "device_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "fcm_token")
    var fcmToken: String

    @Field(key: "platform")
    var platform: DevicePlatform

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Field(key: "last_seen_at")
    var lastSeenAt: Date

    init() { }

    init(id: UUID? = nil, userID: UUID, fcmToken: String, platform: DevicePlatform) {
        self.id = id
        self.$user.id = userID
        self.fcmToken = fcmToken
        self.platform = platform
        self.lastSeenAt = Date()
    }
}
