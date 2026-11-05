import AppKit
import CodexLimitsCore
import Combine

@MainActor
final class LimitsStore: ObservableObject {
    @Published private(set) var snapshot: LimitsSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var now = Date()
    @Published var widgetVisible = true
    @Published var keepOnTop = false
    @Published var cliPath: String
    @Published var codexHome: String
    let isDemo: Bool
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private let cacheURL: URL

    var isStale: Bool { error != nil || (snapshot?.isStale(at: now) ?? true) }
    var statusTitle: String {
        guard let remaining = snapshot?.bucket.minimumRemaining else { return "Codex —" }
        return "\(isStale ? "~" : "")\(Int(remaining.rounded(.down)))%"
    }
    var resolvedCLI: String { CodexLocator.find(override: cliPath)?.path ?? "Не найден" }

    init(demo: Bool) {
        isDemo = demo
        let defaults = UserDefaults.standard
        cliPath = defaults.string(forKey: "cliPath") ?? ""
        codexHome = defaults.string(forKey: "codexHome") ?? ""
        widgetVisible = defaults.object(forKey: "widgetVisible") as? Bool ?? true
        keepOnTop = defaults.bool(forKey: "keepOnTop")
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.codex-limits-widget/limits.json")
        if demo {
            snapshot = .demo
        } else if let data = try? Data(contentsOf: cacheURL) {
            snapshot = try? JSONDecoder().decode(LimitsSnapshot.self, from: data)
        }
    }

    func start() {
        refresh()
        // The clock also updates stale state and reset labels while the popover is closed.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    private func tick() {
        now = Date()
        if now.timeIntervalSince(lastAttempt) >= 5 * 60 { refresh() }
    }

    @objc private func didWake() { refresh() }

    func refresh() {
        guard !isLoading else { return }
        now = Date()
        lastAttempt = now
        guard !isDemo else { snapshot = .demo; return }
        guard let executable = CodexLocator.find(override: cliPath) else {
            error = CodexClientError.executableMissing.localizedDescription
            return
        }
        isLoading = true
        let client = CodexClient(executable: executable, codexHome: codexHome)
        Task {
            defer { isLoading = false }
            do {
                let result = try await client.fetch()
                snapshot = result
                error = nil
                now = Date()
                saveCache(result)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        cliPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        codexHome = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(cliPath, forKey: "cliPath")
        defaults.set(codexHome, forKey: "codexHome")
        // Cached percentages may belong to a different account after changing CODEX_HOME.
        snapshot = nil
        try? FileManager.default.removeItem(at: cacheURL)
        refresh()
    }

    private func saveCache(_ value: LimitsSnapshot) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: cacheURL, options: .atomic)
        } catch {
            // Live data remains usable; the UI explicitly reports a failure to persist it.
            self.error = "Лимиты получены, но не удалось сохранить локальный кэш."
        }
    }
}
