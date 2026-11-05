import Foundation

public struct TokenUsage: Sendable, Equatable {
    public var input = 0
    public var cachedInput = 0
    public var output = 0
    public var reasoning = 0
    public var total = 0

    public init(input: Int = 0, cachedInput: Int = 0, output: Int = 0, reasoning: Int = 0, total: Int? = nil) {
        self.input = max(0, input)
        self.cachedInput = max(0, min(input, cachedInput))
        self.output = max(0, output)
        self.reasoning = max(0, min(output, reasoning))
        self.total = max(0, total ?? (input + output))
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput,
             output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning,
             total: lhs.total + rhs.total)
    }

    func delta(since previous: Self) -> Self {
        Self(input: input - previous.input, cachedInput: cachedInput - previous.cachedInput,
             output: output - previous.output, reasoning: reasoning - previous.reasoning,
             total: total - previous.total)
    }

    init(_ fields: [String: Any]) {
        self.init(input: fields["input_tokens"] as? Int ?? 0,
                  cachedInput: fields["cached_input_tokens"] as? Int ?? 0,
                  output: fields["output_tokens"] as? Int ?? 0,
                  reasoning: fields["reasoning_output_tokens"] as? Int ?? 0,
                  total: fields["total_tokens"] as? Int)
    }
}

public struct UsageEvent: Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let turnID: String
    public let model: String
    public let tokens: TokenUsage
    public let isLegacy: Bool

    public init(id: String, date: Date, turnID: String, model: String, tokens: TokenUsage, isLegacy: Bool) {
        self.id = id
        self.date = date
        self.turnID = turnID
        self.model = model
        self.tokens = tokens
        self.isLegacy = isLegacy
    }
}

public struct UsageTurn: Identifiable, Sendable {
    public let id: String
    public let prompt: String
    public let startedAt: Date

    public init(id: String, prompt: String, startedAt: Date) {
        self.id = id
        self.prompt = prompt
        self.startedAt = startedAt
    }
}

public struct UsageSession: Identifiable, Sendable {
    public let id: String
    public var title: String
    public let project: String
    public let directory: String
    public let startedAt: Date
    public let isAgent: Bool
    public let parentID: String?
    public var isArchived: Bool
    public var events: [UsageEvent]
    public var turns: [UsageTurn]

    public init(id: String, title: String, project: String, directory: String, startedAt: Date,
                isAgent: Bool, parentID: String?, isArchived: Bool, events: [UsageEvent], turns: [UsageTurn]) {
        self.id = id
        self.title = title
        self.project = project
        self.directory = directory
        self.startedAt = startedAt
        self.isAgent = isAgent
        self.parentID = parentID
        self.isArchived = isArchived
        self.events = events
        self.turns = turns
    }
}

public struct UsageSnapshot: Sendable {
    public let sessions: [UsageSession]
    public let fetchedAt: Date
    public let fileCount: Int
    public let warningCount: Int
    public let historyDirectory: String

    public init(sessions: [UsageSession], fetchedAt: Date = Date(), fileCount: Int,
                warningCount: Int = 0, historyDirectory: String) {
        self.sessions = sessions
        self.fetchedAt = fetchedAt
        self.fileCount = fileCount
        self.warningCount = warningCount
        self.historyDirectory = historyDirectory
    }
}

public enum UsagePeriod: String, CaseIterable, Sendable {
    case today = "Сегодня", week = "7 дней", month = "30 дней", all = "Всё время"

    public func start(at now: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: now)
        switch self {
        case .today: return day
        case .week: return calendar.date(byAdding: .day, value: -6, to: day)
        case .month: return calendar.date(byAdding: .day, value: -29, to: day)
        case .all: return nil
        }
    }
}

public enum UsageSource: String, CaseIterable, Sendable {
    case all = "Все", chats = "Чаты", agents = "Агенты"
}

public struct UsageQuery: Sendable {
    public var period: UsagePeriod = .week
    public var model: String? = nil
    public var source: UsageSource = .all
    public var search = ""
    public init() {}
}

public struct SessionUsageSummary: Identifiable, Sendable {
    public let session: UsageSession
    public let events: [UsageEvent]
    public var id: String { session.id }
    public var tokens: TokenUsage { events.reduce(TokenUsage()) { $0 + $1.tokens } }
    public var lastActivity: Date { events.map(\.date).max() ?? session.startedAt }
    public var models: [String] { Set(events.map(\.model)).sorted() }
    public var turnCount: Int { Set(events.map(\.turnID)).count }
}

public struct UsageChartPoint: Identifiable, Sendable {
    public let date: Date
    public let tokens: Int
    public var id: Date { date }
}

public struct ModelUsage: Identifiable, Sendable {
    public let model: String
    public let tokens: Int
    public var id: String { model }
}

public struct UsageReport: Sendable {
    public let sessions: [SessionUsageSummary]
    public let timeline: [UsageChartPoint]
    public let models: [ModelUsage]
    public let hourly: Bool
    public var tokens: TokenUsage { sessions.reduce(TokenUsage()) { $0 + $1.tokens } }
    public var requestCount: Int { sessions.reduce(0) { $0 + $1.events.count } }
    public var legacyCount: Int { sessions.reduce(0) { $0 + $1.events.filter(\.isLegacy).count } }
}

extension UsageSnapshot {
    public var models: [String] { Set(sessions.flatMap { $0.events.map(\.model) }).sorted() }

    public func report(query: UsageQuery, now: Date = Date(), calendar: Calendar = .current) -> UsageReport {
        let start = query.period.start(at: now, calendar: calendar)
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaries = sessions.compactMap { session -> SessionUsageSummary? in
            if query.source == .chats && session.isAgent { return nil }
            if query.source == .agents && !session.isAgent { return nil }
            if !search.isEmpty && ![session.title, session.directory, session.id].contains(where: {
                $0.localizedCaseInsensitiveContains(search)
            }) { return nil }
            let events = session.events.filter {
                (start == nil || $0.date >= start!) && $0.date <= now &&
                    (query.model == nil || $0.model == query.model)
            }
            return events.isEmpty ? nil : SessionUsageSummary(session: session, events: events)
        }.sorted { $0.tokens.total > $1.tokens.total }
        let events = summaries.flatMap(\.events)
        let hourly = query.period == .today
        let component: Calendar.Component = hourly ? .hour : .day
        var totals: [Date: Int] = [:]
        var models: [String: Int] = [:]
        for event in events {
            let date = calendar.dateInterval(of: component, for: event.date)!.start
            totals[date, default: 0] += event.tokens.total
            models[event.model, default: 0] += event.tokens.total
        }
        // Include empty intervals; a missing day must not disappear from the graph.
        if let first = start ?? totals.keys.min() {
            var cursor = calendar.dateInterval(of: component, for: first)!.start
            let end = calendar.dateInterval(of: component, for: now)!.start
            while cursor <= end {
                totals[cursor, default: 0] += 0
                guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
                cursor = next
            }
        }
        return UsageReport(sessions: summaries,
            timeline: totals.map { UsageChartPoint(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date },
            models: models.map { ModelUsage(model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens },
            hourly: hourly)
    }
}
