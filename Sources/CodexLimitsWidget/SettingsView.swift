import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var store: LimitsStore
    var applyWindowPreferences: () -> Void

    var body: some View {
        Form {
            Section("Подключение к Codex") {
                TextField("Путь к Codex CLI (пусто = автоматически)", text: $store.cliPath)
                HStack {
                    Text(store.resolvedCLI).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Выбрать…", action: selectCLI)
                }
                TextField("CODEX_HOME (пусто = настройки CLI)", text: $store.codexHome)
                Text("Статистика читает sessions и archived_sessions в этой папке. Данные обновляются раз в минуту, пока открыта вкладка.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Вход в ChatGPT выполните в терминале: codex login. API-ключ не даёт лимиты подписки.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Сохранить и обновить") { store.saveSettings() }
                    .disabled(store.isLoading)
            }
            Section("Виджет") {
                Toggle("Показывать на рабочем столе", isOn: $store.widgetVisible)
                    .onChange(of: store.widgetVisible) { _ in applyWindowPreferences() }
                Toggle("Поверх других окон", isOn: $store.keepOnTop)
                    .onChange(of: store.keepOnTop) { _ in applyWindowPreferences() }
                Text("Перетащите виджет за свободное место. Положение сохраняется автоматически.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Проценты показывают остаток каждого окна. В строке меню — минимальный остаток. «~» означает устаревшие данные.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Для автозапуска добавьте приложение в Системные настройки → Основные → Объекты входа.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Завершить Codex Limits") { NSApplication.shared.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 550, height: 510)
    }

    private func selectCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите исполняемый файл codex"
        if panel.runModal() == .OK, let url = panel.url { store.cliPath = url.path }
    }
}
