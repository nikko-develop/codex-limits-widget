import AppKit
import CodexLimitsCore
import Combine
import SwiftUI

@main
enum CodexLimitsWidget {
    @MainActor
    static func main() {
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Лимиты Codex")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 350, height: 426)
        popover.contentViewController = NSHostingController(rootView: widgetView())

        panel = WidgetPanel(contentRect: NSRect(x: 100, y: 100, width: 350, height: 426),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: widgetView())
        let restored = panel.setFrameUsingName("CodexLimitsWidget")
        panel.setFrameAutosaveName("CodexLimitsWidget")
        if !restored, let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 374,
                                              y: screen.visibleFrame.maxY - 24))
        }
        applyWindowPreferences()
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        updateStatus()
        store.start()
    }

    private func widgetView() -> WidgetView {
        WidgetView(store: store, toggleWidget: { [weak self] in self?.toggleWidget() },
                   openSettings: { [weak self] in self?.showSettings() })
    }

    private func updateStatus() {
        statusItem.button?.title = " " + store.statusTitle
        statusItem.button?.toolTip = "Codex: минимальный остаток лимитов\(store.isStale ? " · данные устарели" : "")"
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
