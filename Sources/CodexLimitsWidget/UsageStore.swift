import CodexLimitsCore
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private let reader = UsageHistoryReader()
    private let isDemo: Bool
    private var generation = 0
    private var lastAttempt = Date.distantPast

    init(demo: Bool) {
        isDemo = demo
        if demo { snapshot = .demo }
    }

    func reset() {
        generation += 1
        snapshot = isDemo ? .demo : nil
        error = nil
        lastAttempt = .distantPast
        isLoading = false
    }

    func refresh(home: String, force: Bool = false) {
        guard !isDemo, !isLoading, force || Date().timeIntervalSince(lastAttempt) >= 60 else { return }
        isLoading = true
        lastAttempt = Date()
        let currentGeneration = generation
        let directory = UsageHistoryReader.directory(override: home)
        Task {
            do {
                let result = try await reader.read(directory: directory)
                guard generation == currentGeneration else { return }
                snapshot = result
                error = nil
            } catch {
                guard generation == currentGeneration else { return }
                self.error = error.localizedDescription
            }
            if generation == currentGeneration { isLoading = false }
        }
    }
}

extension UsageSnapshot {
    static var demo: UsageSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let models = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-sol", "codex-auto-review"]
        let titles = ["Виджет лимитов Codex", "Анализ архитектуры проекта", "Исправление интеграции", "Проверка действий"]
        let sessions = (0..<4).map { index -> UsageSession in
            let events = (0..<20).map { number -> UsageEvent in
                let day = calendar.date(byAdding: .day, value: -(number % 7), to: today)!
                let date = calendar.date(byAdding: .minute, value: number * 11, to: day)!
                return UsageEvent(id: "demo-\(index)-\(number)", date: min(date, Date()),
                    turnID: "turn-\(number / 3)", model: models[index],
                    tokens: TokenUsage(input: 1200 + number * 160 * (index + 1), cachedInput: number * 300,
                                       output: 400 + number * 80, reasoning: number * 40), isLegacy: false)
            }
            return UsageSession(id: "demo-\(index)", title: titles[index], project: "codex-limits-widget",
                directory: "/Projects/codex-limits-widget", startedAt: events.map(\.date).min()!,
                isAgent: index == 3, parentID: index == 3 ? "demo-0" : nil, isArchived: false,
                events: events, turns: (0..<7).map {
                    UsageTurn(id: "turn-\($0)", prompt: ["Добавить статистику по чатам", "Проверить сборку", "Исправить обработку ошибок"][$0 % 3],
                              startedAt: events[$0].date)
                })
        }
        return UsageSnapshot(sessions: sessions, fileCount: 4, historyDirectory: "Демонстрационные данные")
    }
}
