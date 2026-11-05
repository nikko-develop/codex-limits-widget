import CodexLimitsCore
import SwiftUI

@MainActor
struct WidgetView: View {
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
        .background {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.15),
                                    Color(red: 0.055, green: 0.065, blue: 0.085)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)))
        .environment(\.colorScheme, .dark)
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
