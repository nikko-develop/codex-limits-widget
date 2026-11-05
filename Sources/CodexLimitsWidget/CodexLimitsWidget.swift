import AppKit
import CodexLimitsCore
import Combine
import QuartzCore
import SwiftUI

@main
enum CodexLimitsWidget {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check-usage") {
            let directory = UsageHistoryReader.directory()
            Task {
                do {
                    let snapshot = try await UsageHistoryReader().read(directory: directory)
                    var query = UsageQuery()
                    query.period = .all
                    let report = snapshot.report(query: query)
                    print("Локальная история: \(snapshot.fileCount) файлов, \(report.sessions.count) сессий с расходом")
                    print("Всего: \(report.tokens.total), вход: \(report.tokens.input), кэш: \(report.tokens.cachedInput), выход: \(report.tokens.output), рассуждения: \(report.tokens.reasoning)")
                    print("Записи расхода: \(report.requestCount), старый формат: \(report.legacyCount), пропуски: \(snapshot.warningCount)")
                    for model in report.models { print("\(model.model): \(model.tokens)") }
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check") {
            do {
                guard let executable = CodexLocator.find() else { throw CodexClientError.executableMissing }
                let snapshot = try CodexClient(executable: executable).read()
                for window in snapshot.bucket.windows {
                    let reset = window.resetDate?.formatted(date: .abbreviated, time: .shortened) ?? "неизвестно"
                    print("\(window.title): осталось \(Int(window.remainingPercent))%, сброс: \(reset)")
                }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: LimitsStore!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: NSPanel!
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = LimitsStore(demo: CommandLine.arguments.contains("--demo"))
        if CommandLine.arguments.contains("--statistics") { store.selectedTab = .statistics }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Лимиты Codex")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.contentSize = store.widgetSize
        popover.contentViewController = NSHostingController(rootView: widgetView())
        popover.contentViewController?.preferredContentSize = store.widgetSize

        panel = WidgetPanel(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: store.widgetSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingView = NSHostingView(rootView: widgetView())
        // Window frames drive layout; intrinsic SwiftUI sizes must not resize the panel again.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let restored = panel.setFrameUsingName("CodexLimitsWidget")
        panel.setFrameAutosaveName("CodexLimitsWidget")
        if !restored, let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 374,
                                              y: screen.visibleFrame.maxY - 24))
        }
        resizePresentation(to: store.widgetSize, animated: false)
        applyWindowPreferences()
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatus()
            }
        }.store(in: &subscriptions)
        store.$selectedTab.dropFirst().removeDuplicates().sink { [weak self] tab in
            guard let self else { return }
            self.resizePresentation(to: self.store.size(for: tab), animated: true)
        }.store(in: &subscriptions)
        updateStatus()
        store.start()
        if store.selectedTab == .statistics { store.refreshUsage() }
    }

    private func widgetView() -> WidgetView {
        WidgetView(store: store, toggleWidget: { [weak self] in self?.toggleWidget() },
                   openSettings: { [weak self] in self?.showSettings() })
    }

    private func updateStatus() {
        statusItem.button?.title = " " + store.statusTitle
        statusItem.button?.toolTip = "Codex: минимальный остаток лимитов\(store.isStale ? " · данные устарели" : "")"
    }

    private func resizePresentation(to size: NSSize, animated: Bool) {
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = NSRect(x: panel.frame.maxX - size.width, y: panel.frame.maxY - size.height,
                           width: size.width, height: size.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - size.height))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.32 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = animate
            if animate && panel.isVisible {
                panel.animator().setFrame(frame, display: true)
            } else {
                panel.setFrame(frame, display: true)
            }
            popover.contentSize = size
            popover.contentViewController?.preferredContentSize = size
        }
    }

    private func applyWindowPreferences() {
        panel.level = store.keepOnTop ? .floating : .normal
        if store.widgetVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        UserDefaults.standard.set(store.widgetVisible, forKey: "widgetVisible")
        UserDefaults.standard.set(store.keepOnTop, forKey: "keepOnTop")
    }

    @objc private func toggleWidget() {
        store.widgetVisible.toggle()
        applyWindowPreferences()
    }

    @objc private func statusClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            addItem(to: menu, title: store.widgetVisible ? "Скрыть виджет" : "Показать виджет", action: #selector(toggleWidget))
            addItem(to: menu, title: "Обновить", action: #selector(refresh))
            addItem(to: menu, title: "Настройки…", action: #selector(showSettings))
            menu.addItem(.separator())
            addItem(to: menu, title: "Завершить", action: #selector(quit))
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func refresh() { store.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codex Limits — настройки"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store,
                applyWindowPreferences: { [weak self] in self?.applyWindowPreferences() }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
