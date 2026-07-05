import Vapor

/// In-memory sliding-window rate limiter.
///
/// Single-instance only — good enough for the self-hosted MVP. If the app is
/// ever scaled horizontally, this needs to move to a shared store (e.g. Redis),
/// since each process would otherwise track its own counts.
actor RateLimiter {
    /// Timestamps of recent hits, per key.
    private var hits: [String: [Date]] = [:]

    enum Decision: Equatable {
        case allow
        case deny(retryAfter: Int)
    }

    /// Records a hit for `key` and decides whether it's within `limit` per `window`.
    func record(key: String, limit: Int, window: TimeInterval) -> Decision {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)
        var times = (hits[key] ?? []).filter { $0 > cutoff }

        guard times.count < limit else {
            // Denied — report when the oldest hit leaves the window.
            let retryAfter = times[0].addingTimeInterval(window).timeIntervalSince(now)
            hits[key] = times
            return .deny(retryAfter: max(1, Int(retryAfter.rounded(.up))))
        }

        times.append(now)
        hits[key] = times
        return .allow
    }
}

extension Application {
    private struct RateLimiterKey: StorageKey {
        typealias Value = RateLimiter
    }

    /// Process-wide rate limiter, created on first access.
    var rateLimiter: RateLimiter {
        if let existing = storage[RateLimiterKey.self] {
            return existing
        }
        let limiter = RateLimiter()
        storage[RateLimiterKey.self] = limiter
        return limiter
    }
}
