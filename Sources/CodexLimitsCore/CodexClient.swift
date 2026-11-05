import Darwin
import Foundation

public enum CodexClientError: LocalizedError {
    case executableMissing, timedOut, connectionClosed, invalidResponse, noLimits, rpc(Int)

    public var errorDescription: String? {
        switch self {
        case .executableMissing: return "Codex CLI не найден. Укажите путь в настройках."
        case .timedOut: return "Codex не ответил за отведённое время. Проверьте интернет и вход в аккаунт."
        case .connectionClosed: return "Codex завершил соединение. Проверьте CLI командой codex --version."
        case .invalidResponse: return "Не удалось прочитать ответ Codex. Возможно, требуется обновить CLI."
        case .noLimits: return "Codex не вернул окна лимитов. Войдите через ChatGPT: codex login."
        case .rpc(let code): return "Codex не вернул лимиты (RPC \(code)). Проверьте codex login и подключение."
        }
    }
}

public enum CodexLocator {
    public static func find(override: String = "") -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return manager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        var paths = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            home.appendingPathComponent(".local/bin/codex").path
        ]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/codex" }
        // The IDE extension bundles a CLI even when there is no global installation.
        for folder in [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions"] {
            let root = home.appendingPathComponent(folder)
            let extensions = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
            for name in extensions.filter({ $0.hasPrefix("openai.chatgpt-") })
                .sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                #if arch(arm64)
                let architecture = "macos-aarch64"
                #else
                let architecture = "macos-x86_64"
                #endif
                paths.append(root.appendingPathComponent("\(name)/bin/\(architecture)/codex").path)
            }
        }
        return paths.first(where: manager.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }
}

public struct CodexClient: Sendable {
    public let executable: URL
    public let codexHome: String
    public let timeout: TimeInterval

    public init(executable: URL, codexHome: String = "", timeout: TimeInterval = 30) {
        self.executable = executable
        self.codexHome = codexHome
        self.timeout = timeout
    }

    public func fetch() async throws -> LimitsSnapshot {
        try await Task.detached(priority: .utility) { try read() }.value
    }

    /// Blocking transport; GUI callers use fetch() to keep it off the main thread.
    public func read() throws -> LimitsSnapshot {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path,
                               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                               environment["PATH"] ?? ""].joined(separator: ":")
        if !codexHome.isEmpty {
            environment["CODEX_HOME"] = (codexHome as NSString).expandingTildeInPath
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Diagnostics may include account details; never persist or display raw server logs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Report an early server exit as an error instead of terminating the GUI with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let watchdog = ProcessWatchdog(process: process, timeout: timeout)
        defer {
            watchdog.stop()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        var reader = LineReader(handle: output.fileHandleForReading, watchdog: watchdog)

        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        try send(["id": 0, "method": "initialize", "params": ["clientInfo": [
            "name": "codex_limits_widget", "title": "Codex Limits Widget", "version": "1.0.0"
        ]]])
        _ = try reader.response(id: 0)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 1, "method": "account/rateLimits/read"])
        let result = try reader.response(id: 1)
        let response: LimitsResponse
        do {
            response = try JSONDecoder().decode(LimitsResponse.self, from: result)
        } catch {
            throw CodexClientError.invalidResponse
        }
        guard let bucket = response.codex, !bucket.windows.isEmpty else { throw CodexClientError.noLimits }
        return LimitsSnapshot(bucket: bucket)
    }
}

private final class ProcessWatchdog: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopped = false
    private var expired = false

    init(process: Process, timeout: TimeInterval) {
        self.process = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.expire()
        }
    }

    var didExpire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    private func expire() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        expired = true
        terminate()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        terminate()
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        // A broken CLI must not keep the read blocked by ignoring SIGTERM.
        let child = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

private struct LineReader {
    let handle: FileHandle
    let watchdog: ProcessWatchdog
    var buffer = Data()

    mutating func response(id: Int) throws -> Data {
        while true {
            if watchdog.didExpire { throw CodexClientError.timedOut }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexClientError.invalidResponse
                }
                guard let responseID = envelope["id"] as? Int, responseID == id else { continue }
                if let error = envelope["error"] as? [String: Any] {
                    throw CodexClientError.rpc(error["code"] as? Int ?? -1)
                }
                guard let result = envelope["result"], JSONSerialization.isValidJSONObject(result) else {
                    throw CodexClientError.invalidResponse
                }
                return try JSONSerialization.data(withJSONObject: result)
            }
            // FileHandle.read(upToCount:) can wait for more bytes on a live pipe.
            // POSIX read returns the available fragment without waiting for EOF.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw watchdog.didExpire ? CodexClientError.timedOut : CodexClientError.connectionClosed
            }
            guard count > 0 else {
                throw watchdog.didExpire ? CodexClientError.timedOut : CodexClientError.connectionClosed
            }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 4 * 1024 * 1024 else { throw CodexClientError.invalidResponse }
        }
    }
}
