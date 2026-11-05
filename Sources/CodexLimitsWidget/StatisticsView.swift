import AppKit
import CodexLimitsCore
import SwiftUI

@MainActor
struct StatisticsView: View {
    @ObservedObject var store: UsageStore
    let isDemo: Bool
    var refresh: () -> Void
    @State private var query = UsageQuery()
    @State private var selectedID: String?
    @State private var newestFirst = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Расход по чатам").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(isDemo ? "Демонстрационные данные" : "Локальная история Codex · токены")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.isLoading).help("Перечитать историю")
            }
            filters
            if let snapshot = store.snapshot {
                let report = snapshot.report(query: query)
                reportContent(report, snapshot: snapshot)
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 32)).foregroundStyle(UsageStyle.accent)
                    Text(store.isLoading ? "Читаю историю сессий…" : "История пока недоступна")
                    Text(store.error ?? "Здесь появятся локальные чаты, модели и расход токенов.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
            if let error = store.error, store.snapshot != nil {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("Период", selection: $query.period) {
                    ForEach(UsagePeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 310)
                Picker("Модель", selection: $query.model) {
                    Text("Все модели").tag(String?.none)
                    ForEach(store.snapshot?.models ?? [], id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden().frame(maxWidth: 230)
                Picker("Источник", selection: $query.source) {
                    ForEach(UsageSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 180)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                TextField("Поиск по чату или проекту", text: $query.search).textFieldStyle(.plain)
                if !query.search.isEmpty {
                    Button { query.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12)).padding(8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func reportContent(_ report: UsageReport, snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                metric("ВСЕГО ТОКЕНОВ", value: report.tokens.total, note: "\(report.sessions.count) чатов и агентов")
                metric("ВХОД", value: report.tokens.input, note: "Кэш: \(report.tokens.cachedInput.tokenLabel)")
                metric("ВЫХОД", value: report.tokens.output, note: "Рассуждения: \(report.tokens.reasoning.tokenLabel)")
                metric("ЗАПРОСЫ", value: report.requestCount, note: "\(report.models.count) моделей")
            }
            HStack(spacing: 10) {
                UsageTimelineChart(points: report.timeline, hourly: report.hourly)
                    .frame(maxWidth: .infinity)
                ModelUsageChart(models: report.models).frame(width: 270)
            }
            .frame(height: 148)
            HStack(alignment: .top, spacing: 12) {
                sessionList(report).frame(width: 265)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                let selected = report.sessions.first { $0.id == selectedID } ?? report.sessions.first
                if let selected {
                    SessionDetailView(summary: selected).id(selected.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 24))
                        Text("Нет расхода за выбранный период")
                        Text("Попробуйте изменить фильтры.").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("\(snapshot.fileCount) файлов · \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                if snapshot.warningCount > 0 {
                    Text("· Пропуски: \(snapshot.warningCount)").foregroundStyle(.orange)
                        .help("Некоторые файлы или строки не удалось прочитать. Сумма может быть неполной.")
                }
                Spacer()
                Text("Токены ≠ стоимость или % лимита")
            }
            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            .help("Локальная история может быть неполной и содержать несколько аккаунтов. Кэш входит во вход, рассуждения — в выход. Суммы не являются счётом за подписку.")
        }
    }

    private func metric(_ title: String, value: Int, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.45))
            Text(value.tokenLabel).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            Text(note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .help(value.formatted())
    }

    private func sessionList(_ report: UsageReport) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("ЧАТЫ И СЕССИИ").font(.system(size: 9, weight: .semibold)).tracking(1)
                Spacer()
                Button { newestFirst.toggle() } label: {
                    Image(systemName: newestFirst ? "clock" : "arrow.down")
                }
                .buttonStyle(.plain).help(newestFirst ? "Сортировка: новые сначала" : "Сортировка: по расходу")
            }
            .foregroundStyle(.white.opacity(0.5))
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(newestFirst ? report.sessions.sorted { $0.lastActivity > $1.lastActivity } : report.sessions) { item in
                        Button { selectedID = item.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Image(systemName: item.session.isAgent ? "cpu" : "bubble.left")
                                        .foregroundStyle(item.session.isAgent ? UsageStyle.reasoning : UsageStyle.accent)
                                    Text(item.session.title).font(.system(size: 12, weight: .medium))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                HStack {
                                    Text(item.session.project).lineLimit(1)
                                    Spacer()
                                    Text(item.tokens.total.tokenLabel).monospacedDigit().foregroundStyle(UsageStyle.accent)
                                }
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                                Text("\(item.turnCount) ходов · \(item.models.joined(separator: ", "))")
                                    .font(.system(size: 9)).lineLimit(1).foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background((selectedID ?? report.sessions.first?.id) == item.id ? UsageStyle.accent.opacity(0.1) : .white.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct SessionDetailView: View {
    let summary: SessionUsageSummary

    private var turns: [(id: String, prompt: String, date: Date, events: [UsageEvent])] {
        let labels = Dictionary(summary.session.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: summary.events, by: \.turnID).map { id, events in
            (id: id, prompt: labels[id]?.prompt ?? "", date: events.map(\.date).min()!, events: events)
        }.sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.session.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    Text(summary.session.directory).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        .textSelection(.enabled).lineLimit(2)
                    HStack {
                        Text(summary.session.isAgent ? "Фоновый агент" : "Чат")
                        if summary.session.isArchived { Text("· В архиве") }
                        Spacer()
                        Text("\(summary.tokens.total.formatted()) токенов")
                    }
                    .font(.system(size: 10)).foregroundStyle(UsageStyle.accent)
                    Text(summary.models.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                    if let parent = summary.session.parentID {
                        Text("Родительский чат: \(parent)").font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4)).textSelection(.enabled)
                    }
                }
                TokenBreakdownView(tokens: summary.tokens)
                if summary.events.contains(where: \.isLegacy) {
                    Text("Часть расхода восстановлена из счётчиков старого формата истории.")
                        .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8))
                }
                Text("ХОДЫ ДИАЛОГА · \(turns.count)").font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(turns, id: \.id) { turn in
                    let tokens = turn.events.reduce(TokenUsage()) { $0 + $1.tokens }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            if !turn.prompt.isEmpty {
                                Text(turn.prompt).font(.system(size: 11)).textSelection(.enabled)
                            }
                            TokenBreakdownView(tokens: tokens)
                            ForEach(turn.events.sorted { $0.date < $1.date }) { event in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.model).font(.system(size: 10, design: .monospaced))
                                        Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(event.tokens.total.formatted()).font(.system(size: 10)).monospacedDigit()
                                        Text("↑ \(event.tokens.input.tokenLabel)  ↓ \(event.tokens.output.tokenLabel)")
                                            .font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.padding(.vertical, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.prompt.isEmpty ? "Ход · \(turn.id.prefix(8))" : turn.prompt)
                                .font(.system(size: 11, weight: .medium)).lineLimit(2)
                            Text("\(turn.date.formatted(date: .abbreviated, time: .shortened)) · \(turn.events.count) запросов · \(tokens.total.tokenLabel) токенов")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .tint(UsageStyle.accent)
                    Divider().overlay(.white.opacity(0.04))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 5)
        }
    }
}
