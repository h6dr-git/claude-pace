import Foundation

struct CodexRateLimitWindow: Codable {
    let usedPercent: Double?
    let windowDurationMins: Double?
    let resetsAt: Double?
}

struct CodexCreditsSnapshot: Codable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct CodexRateLimitSnapshot: Codable {
    let limitId: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let credits: CodexCreditsSnapshot?
    let planType: String?
    let rateLimitReachedType: String?
}

struct CodexRateLimitResetCredits: Codable {
    let availableCount: Int?
}

struct CodexAccountUsageSummary: Codable {
    let lifetimeTokens: Int?
    let peakDailyTokens: Int?
    let longestRunningTurnSec: Int?
    let currentStreakDays: Int?
    let longestStreakDays: Int?
}

struct CodexDailyUsageBucket: Codable {
    let startDate: String
    let tokens: Int
}

struct CodexAccountUsage: Codable {
    let summary: CodexAccountUsageSummary?
    let dailyUsageBuckets: [CodexDailyUsageBucket]?
}

struct CodexUsageSnapshot: Codable {
    let schema: String?
    let source: String?
    let capturedAt: Double?
    let rateLimits: CodexRateLimitSnapshot?
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
    let rateLimitResetCredits: CodexRateLimitResetCredits?
    let accountUsage: CodexAccountUsage?
    let accountUsageCapturedAt: Double?
}
