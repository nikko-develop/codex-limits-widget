import Charts
import CodexLimitsCore
import SwiftUI

enum UsageStyle {
    static let accent = Color(red: 0.47, green: 0.92, blue: 0.73)
    static let cached = Color(red: 0.43, green: 0.67, blue: 1)
    static let output = Color(red: 0.79, green: 0.61, blue: 1)
    static let reasoning = Color(red: 1, green: 0.72, blue: 0.4)
}

extension Int {
    var tokenLabel: String { formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
}

struct UsageTimelineChart: View {
    let points: [UsageChartPoint]
    let hourly: Bool
    @State private var selected: UsageChartPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(hourly ? "ПО ЧАСАМ · ТОКЕНЫ" : "ПО ДНЯМ · ТОКЕНЫ")
                    .font(.system(size: 9, weight: .semibold)).tracking(1)
                Spacer()
                if let selected, points.contains(where: { $0.id == selected.id }) {
                    Text("\(selected.date.formatted(hourly ? .dateTime.hour() : .dateTime.day().month())) · \(selected.tokens.formatted())")
                        .font(.system(size: 10)).monospacedDigit()
                }
            }
            .foregroundStyle(.white.opacity(0.6))
            Chart(points) { point in
                BarMark(x: .value("Дата", point.date, unit: hourly ? .hour : .day),
                        y: .value("Токены", point.tokens))
                    .foregroundStyle(UsageStyle.accent.gradient)
                    .cornerRadius(3)
                    .accessibilityLabel(point.date.formatted(date: .abbreviated, time: hourly ? .shortened : .omitted))
                    .accessibilityValue("\(point.tokens) токенов")
                if let selected, selected.id == point.id {
                    RuleMark(x: .value("Дата", selected.date, unit: hourly ? .hour : .day))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel {
                        if let number = value.as(Int.self) { Text(number.tokenLabel).font(.system(size: 9)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel(format: hourly ? .dateTime.hour() : .dateTime.day().month(.twoDigits))
                        .font(.system(size: 9))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            selected = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                        })
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ModelUsageChart: View {
    let models: [ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("МОДЕЛИ · ТОП 5").font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(.white.opacity(0.6))
            Chart(Array(models.prefix(5))) { model in
                BarMark(x: .value("Токены", model.tokens), y: .value("Модель", model.model))
                    .foregroundStyle(UsageStyle.cached.gradient).cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(model.tokens.tokenLabel).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                    }
                    .accessibilityLabel(model.model).accessibilityValue("\(model.tokens) токенов")
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let name = value.as(String.self) {
                            Text(name).font(.system(size: 9)).lineLimit(1).help(name)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in plot.padding(.trailing, 35) }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TokenBreakdownView: View {
    let tokens: TokenUsage

    private var parts: [(name: String, count: Int, color: Color)] {
        [
            ("Вход без кэша", max(0, tokens.input - tokens.cachedInput), UsageStyle.accent),
            ("Кэш входа", tokens.cachedInput, UsageStyle.cached),
            ("Текст ответа", max(0, tokens.output - tokens.reasoning), UsageStyle.output),
            ("Рассуждения", tokens.reasoning, UsageStyle.reasoning),
            ("Без детализации", max(0, tokens.total - tokens.input - tokens.output), .gray)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(parts.indices, id: \.self) { index in
                        let part = parts[index]
                        Rectangle().fill(part.color)
                            .frame(width: geometry.size.width * Double(part.count) / Double(max(1, tokens.total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 7)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 7) {
                ForEach(parts.indices, id: \.self) { index in
                    let part = parts[index]
                    if part.count > 0 || index < 4 {
                        HStack(spacing: 5) {
                            Circle().fill(part.color).frame(width: 5, height: 5)
                            Text(part.name).foregroundStyle(.white.opacity(0.5))
                            Spacer(minLength: 2)
                            Text(part.count.tokenLabel).monospacedDigit()
                        }
                        .font(.system(size: 10)).help("\(part.name): \(part.count.formatted())")
                    }
                }
            }
        }
    }
}
