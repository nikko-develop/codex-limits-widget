import CodexLimitsCore
import SwiftUI

@MainActor
struct WidgetView: View {
    @ObservedObject var store: LimitsStore
    var toggleWidget: () -> Void
    var openSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let expandedSize = store.size(for: .statistics)
            let compactSize = store.size(for: .limits)
            let progress = min(1, max(0, (geometry.size.width - compactSize.width) /
                                      max(1, expandedSize.width - compactSize.width)))
            let compactTabsWidth = compactSize.width - 48
            let tabsWidth = compactTabsWidth + (255 - compactTabsWidth) * progress

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tabPicker.frame(width: tabsWidth, height: 24)
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .trailing) {
                    Button(action: openSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Настройки")
                        .opacity(progress)
                        .allowsHitTesting(store.selectedTab == .statistics)
                        .accessibilityHidden(store.selectedTab != .statistics)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)

                // Keep both pages alive and let the window own the resize animation.
                // Statistics keeps its final layout while the growing window reveals it.
                ZStack(alignment: .topLeading) {
                    LimitsContent(store: store, toggleWidget: toggleWidget, openSettings: openSettings)
                        .opacity(max(0, 1 - Double(progress) * 4))
                        .allowsHitTesting(store.selectedTab == .limits)
                        .accessibilityHidden(store.selectedTab != .limits)
                    StatisticsView(store: store.usage, isDemo: store.isDemo,
                                   refresh: { store.refreshUsage(force: true) })
                        .frame(width: expandedSize.width, height: expandedSize.height - 48)
                        .opacity(max(0, (Double(progress) - 0.25) / 0.75))
                        .allowsHitTesting(store.selectedTab == .statistics)
                        .accessibilityHidden(store.selectedTab != .statistics)
                }
                .frame(width: geometry.size.width, height: max(0, geometry.size.height - 48), alignment: .topLeading)
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.15),
                                    Color(red: 0.055, green: 0.065, blue: 0.085)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)))
        .environment(\.colorScheme, .dark)
        .onChange(of: store.selectedTab) { tab in
            if tab == .statistics { store.refreshUsage() }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(WidgetTab.allCases, id: \.self) { tab in
                Button { store.selectedTab = tab } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(store.selectedTab == tab ? 0.22 : 0))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.selectedTab == tab ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Раздел виджета")
    }
}

@MainActor
private struct LimitsContent: View {
    @ObservedObject var store: LimitsStore
    var toggleWidget: () -> Void
    var openSettings: () -> Void
    private let mint = Color(red: 0.47, green: 0.92, blue: 0.73)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(mint)
                    .frame(width: 38, height: 38)
                    .background(mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("ОСТАТОК ЛИМИТОВ")
                        .font(.system(size: 9, weight: .medium)).tracking(1.6)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(store.isDemo ? "DEMO" : (store.snapshot?.bucket.planType?.uppercased() ?? "LIVE"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mint)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(mint.opacity(0.1), in: Capsule())
            }

            if let snapshot = store.snapshot {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(snapshot.bucket.windows.enumerated()), id: \.offset) { _, window in
                        WindowRow(window: window, now: store.now, stale: store.isStale)
                    }
                }
                if store.isStale {
                    Label("Данные устарели", systemImage: "exclamationmark.clock")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "waveform.path")
                        .font(.system(size: 26)).foregroundStyle(mint)
                    Text(store.isLoading ? "Получаю лимиты…" : "Нет данных")
                        .font(.system(size: 21, weight: .medium, design: .rounded))
                    Text("Используется аккаунт вашего Codex CLI.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }

            if let error = store.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2).help(error)
            }

            Spacer(minLength: 0)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 12) {
                Circle().fill(store.isStale ? Color.orange : mint).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isLoading ? "Обновление…" : "\(store.isDemo ? "Демо · " : "")Обновление каждые 5 мин")
                    if let date = store.snapshot?.fetchedAt {
                        Text("Получено в \(date.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                iconButton("arrow.clockwise", help: "Обновить лимиты", action: store.refresh)
                    .disabled(store.isLoading)
                iconButton(store.widgetVisible ? "rectangle.on.rectangle" : "rectangle",
                           help: "Показать или скрыть виджет", action: toggleWidget)
                iconButton("gearshape", help: "Настройки", action: openSettings)
            }
        }
        .padding(24)
        .frame(width: 350, height: 426)
        .foregroundStyle(.white)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 20, height: 24)
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).help(help)
    }
}

private struct WindowRow: View {
    let window: LimitWindow
    let now: Date
    let stale: Bool

    private var tint: Color {
        if stale { return .gray }
        if window.remainingPercent <= 10 { return Color(red: 1, green: 0.42, blue: 0.42) }
        if window.remainingPercent <= 25 { return .orange }
        return Color(red: 0.47, green: 0.92, blue: 0.73)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Окно · \(window.title)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text("\(Int(window.remainingPercent.rounded(.down)))")
                    .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                + Text(" %").font(.system(size: 14)).foregroundColor(.white.opacity(0.5))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(tint.gradient).frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: 6)
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                if let date = window.resetDate {
                    if date <= now {
                        Text("Окно завершилось · обновите данные")
                    } else {
                        Text("Сброс \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    }
                } else {
                    Text("Время сброса неизвестно")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.title): осталось \(Int(window.remainingPercent)) процентов")
    }
}
