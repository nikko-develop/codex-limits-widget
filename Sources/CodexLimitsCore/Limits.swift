import Foundation

public struct LimitWindow: Codable, Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    public var title: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Окно лимита" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) дн." }
        if minutes % 60 == 0 { return "\(minutes / 60) ч" }
        return "\(minutes) мин"
    }

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct LimitBucket: Codable, Sendable, Equatable {
    public let limitId: String?
    public let limitName: String?
    public let primary: LimitWindow?
    public let secondary: LimitWindow?
    public let planType: String?

    public var windows: [LimitWindow] { [primary, secondary].compactMap { $0 } }
    public var minimumRemaining: Double? { windows.map(\.remainingPercent).min() }

    public init(limitId: String?, limitName: String?, primary: LimitWindow?, secondary: LimitWindow?, planType: String?) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

public struct LimitsResponse: Codable, Sendable {
    public let rateLimits: LimitBucket?
    public let rateLimitsByLimitId: [String: LimitBucket]?

    // Prefer the explicit Codex bucket; do not mistake a model-specific quota for it.
    public var codex: LimitBucket? {
        if let bucket = rateLimitsByLimitId?["codex"] { return bucket }
        if let bucket = rateLimits, bucket.limitId == nil || bucket.limitId == "codex" { return bucket }
        return nil
    }
}

public struct LimitsSnapshot: Codable, Sendable {
    public let bucket: LimitBucket
    public let fetchedAt: Date

    public init(bucket: LimitBucket, fetchedAt: Date = Date()) {
        self.bucket = bucket
        self.fetchedAt = fetchedAt
    }

    public func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(fetchedAt) > 10 * 60 || bucket.windows.contains {
            guard let reset = $0.resetDate else { return false }
            return reset <= date
        }
    }

    public static var demo: LimitsSnapshot {
        LimitsSnapshot(bucket: LimitBucket(
            limitId: "codex", limitName: nil,
            primary: LimitWindow(usedPercent: 28, windowDurationMins: 300,
                                 resetsAt: Date().addingTimeInterval(7200).timeIntervalSince1970),
            secondary: LimitWindow(usedPercent: 57, windowDurationMins: 10080,
                                   resetsAt: Date().addingTimeInterval(172800).timeIntervalSince1970),
            planType: "plus"
        ))
    }
}
