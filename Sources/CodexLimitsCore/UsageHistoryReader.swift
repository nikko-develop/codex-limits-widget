import Foundation

public enum UsageHistoryError: LocalizedError {
    case missingDirectory, unreadableDirectory

    public var errorDescription: String? {
        switch self {
        case .missingDirectory: return "Локальная история Codex не найдена. Проверьте CODEX_HOME в настройках."
        case .unreadableDirectory: return "Не удалось прочитать историю Codex. Проверьте доступ к папке CODEX_HOME."
        }
    }
}

/// Reads only local rollout files. Authentication files and databases are never opened.
public actor UsageHistoryReader {
    private struct CachedFile {
        let size: Int
        let modified: Date
        let result: ParsedHistory
    }
    private var cache: [URL: CachedFile] = [:]

    public init() {}

    public static func directory(override: String = "") -> URL {
        let configured = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configured.isEmpty ? ProcessInfo.processInfo.environment["CODEX_HOME"] : configured
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public func read(directory: URL) throws -> UsageSnapshot {
        let manager = FileManager.default
        var files: [URL] = []
        var warnings = 0
        var existingDirectories = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        for name in ["sessions", "archived_sessions"] {
            let folder = directory.appendingPathComponent(name)
            guard manager.fileExists(atPath: folder.path) else { continue }
            existingDirectories += 1
            guard manager.isReadableFile(atPath: folder.path),
                  let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles], errorHandler: { _, _ in warnings += 1; return true }) else {
                throw UsageHistoryError.unreadableDirectory
            }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                files.append(file)
            }
        }
        guard existingDirectories > 0 else { throw UsageHistoryError.missingDirectory }
        var sessions: [String: UsageSession] = [:]
        var currentCache: [URL: CachedFile] = [:]
        for file in files.sorted(by: { $0.path < $1.path }) {
            do {
                let attributes = try file.resourceValues(forKeys: Set(keys))
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
                let size = attributes.fileSize ?? 0
                let modified = attributes.contentModificationDate ?? .distantPast
                let parsed: ParsedHistory
                if let previous = cache[file], previous.size == size, previous.modified == modified {
                    parsed = previous.result
                } else {
                    parsed = try HistoryParser.parse(file: file)
                }
                currentCache[file] = CachedFile(size: size, modified: modified, result: parsed)
                warnings += parsed.warnings
                guard let session = parsed.session else { continue }
                if var existing = sessions[session.id] {
                    // A thread may exist in both directories during archival or after a copy.
                    existing.events += session.events
                    existing.turns += session.turns.filter { turn in !existing.turns.contains { $0.id == turn.id } }
                    existing.isArchived = existing.isArchived && session.isArchived
                    sessions[session.id] = existing
                } else {
                    sessions[session.id] = session
                }
            } catch {
                warnings += 1
            }
        }
        cache = currentCache
        let names = readNames(directory: directory)
        var seen = Set<String>()
        var output: [UsageSession] = []
        // Stable order also makes copied/forked historical events count only once globally.
        for var session in sessions.values.sorted(by: {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }) {
            if let title = names[session.id], !title.isEmpty { session.title = title }
            let modernTurns = Set(session.events.filter { !$0.isLegacy }.map(\.turnID))
            session.events = session.events.filter {
                (!$0.isLegacy || !modernTurns.contains($0.turnID)) && seen.insert($0.id).inserted
            }.sorted { $0.date < $1.date }
            output.append(session)
        }
        return UsageSnapshot(sessions: output, fileCount: files.count, warningCount: warnings,
                             historyDirectory: directory.path)
    }

    private func readNames(directory: URL) -> [String: String] {
        var names: [String: String] = [:]
        // This index contains only thread identifiers and their display names.
        try? HistoryParser.lines(file: directory.appendingPathComponent("session_index.jsonl")) { line in
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = row["id"] as? String, let name = row["thread_name"] as? String else { return }
            names[id] = String(name.prefix(200))
        }
        return names
    }
}

private struct ParsedHistory {
    let session: UsageSession?
    let warnings: Int
}

private enum HistoryParser {
    static func parse(file: URL) throws -> ParsedHistory {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return fractional.date(from: text) ?? standard.date(from: text)
        }
        var metadata: [String: Any] = [:]
        var startedAt: Date?
        var turnID = "unknown"
        var model = "Неизвестна"
        var contexts: [String: String] = [:]
        var turns: [String: UsageTurn] = [:]
        var modern: [UsageEvent] = []
        var legacy: [UsageEvent] = []
        var previous: TokenUsage?
        var warnings = 0
        try lines(file: file) { line in
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = row["type"] as? String, let payload = row["payload"] as? [String: Any] else {
                warnings += 1
                return
            }
            let timestamp = date(row["timestamp"])
            switch type {
            case "session_meta":
                if metadata.isEmpty { metadata = payload; startedAt = date(payload["timestamp"]) ?? timestamp }
            case "turn_context":
                turnID = payload["turn_id"] as? String ?? turnID
                model = payload["model"] as? String ?? "Неизвестна"
                contexts[turnID] = model
            case "token_usage_record":
                guard let fields = payload["usage"] as? [String: Any], let timestamp else { return }
                let tokens = TokenUsage(fields)
                let id = payload["turn_id"] as? String ?? turnID
                let eventModel = payload["model"] as? String ?? contexts[id] ?? model
                let response = payload["response_id"] as? String ?? "\(id):\(timestamp.timeIntervalSince1970):\(tokens.total)"
                modern.append(UsageEvent(id: "response:\(response)", date: timestamp, turnID: id,
                                         model: eventModel, tokens: tokens, isLegacy: false))
            case "event_msg":
                let eventType = payload["type"] as? String
                if eventType == "task_started" || eventType == "turn_started" {
                    turnID = payload["turn_id"] as? String ?? turnID
                    if turns[turnID] == nil, let timestamp {
                        turns[turnID] = UsageTurn(id: turnID, prompt: "", startedAt: timestamp)
                    }
                } else if eventType == "user_message", let text = payload["message"] as? String, let timestamp {
                    setPrompt(text, turnID: turnID, timestamp: timestamp, turns: &turns)
                } else if eventType == "token_count", let timestamp,
                          let info = payload["info"] as? [String: Any],
                          let fields = info["total_token_usage"] as? [String: Any] {
                    let total = TokenUsage(fields)
                    defer { previous = total }
                    if let previous, previous == total { return }
                    let tokens: TokenUsage
                    if let previous, total.total >= previous.total {
                        tokens = total.delta(since: previous)
                    } else if let last = info["last_token_usage"] as? [String: Any] {
                        // A resumed/forked log can start with counters inherited from earlier history.
                        tokens = TokenUsage(last)
                    } else {
                        tokens = total
                    }
                    guard tokens.total > 0 else { return }
                    let key = "legacy:\(turnID):\(timestamp.timeIntervalSince1970):\(total.input):\(total.output):\(total.total)"
                    legacy.append(UsageEvent(id: key, date: timestamp, turnID: turnID,
                                             model: contexts[turnID] ?? model, tokens: tokens, isLegacy: true))
                }
            case "response_item":
                if payload["type"] as? String == "message", payload["role"] as? String == "user",
                   let content = payload["content"] as? [[String: Any]], let timestamp {
                    for part in content {
                        if let text = part["text"] as? String {
                            setPrompt(text, turnID: turnID, timestamp: timestamp, turns: &turns)
                        }
                    }
                }
            default: break
            }
        }
        guard !metadata.isEmpty else { return ParsedHistory(session: nil, warnings: warnings + 1) }
        let id = metadata["id"] as? String ?? file.deletingPathExtension().lastPathComponent
        let modernTurns = Set(modern.map(\.turnID))
        let events = modern + legacy.filter { !modernTurns.contains($0.turnID) }
        let sortedTurns = turns.values.sorted { $0.startedAt < $1.startedAt }
        let source = metadata["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let isAgent = source?["subagent"] != nil || metadata["parent_thread_id"] as? String != nil
        let directory = metadata["cwd"] as? String ?? ""
        let fallback = isAgent ? "Агент · \(id.prefix(8))" : "Чат · \(id.prefix(8))"
        let title = sortedTurns.first(where: { !$0.prompt.isEmpty })?.prompt ?? fallback
        return ParsedHistory(session: UsageSession(id: id, title: title,
            project: directory.isEmpty ? "Без проекта" : URL(fileURLWithPath: directory).lastPathComponent,
            directory: directory, startedAt: startedAt ?? events.first?.date ?? .distantPast,
            isAgent: isAgent, parentID: metadata["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String,
            isArchived: file.pathComponents.contains("archived_sessions"), events: events, turns: sortedTurns),
            warnings: warnings)
    }

    private static func setPrompt(_ text: String, turnID: String, timestamp: Date, turns: inout [String: UsageTurn]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS.md"),
              turns[turnID]?.prompt.isEmpty != false else { return }
        // Keep only a short task label, never assistant content, tool output, or a full conversation.
        turns[turnID] = UsageTurn(id: turnID, prompt: String(trimmed.prefix(300)),
                                 startedAt: turns[turnID]?.startedAt ?? timestamp)
    }

    static func lines(file: URL, body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex...end)
                if !line.isEmpty { body(line) }
            }
        }
        // An active Codex process may still be writing the final JSON line. Retry it next scan.
    }
}
