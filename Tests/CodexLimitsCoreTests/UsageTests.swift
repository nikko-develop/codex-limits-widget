import CodexLimitsCore
import Foundation
import Testing

private final class HistoryFixture {
    let directory: URL
    let file: URL
    let reader = UsageHistoryReader()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        file = sessions.appendingPathComponent("test.jsonl")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ rows: [[String: Any]], to destination: URL? = nil) throws {
        let text = try rows.map { row -> String in
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: destination ?? file, atomically: true, encoding: .utf8)
    }

    func row(_ type: String, _ payload: [String: Any], date: String = "2026-11-05T10:00:00.000Z") -> [String: Any] {
        ["type": type, "timestamp": date, "payload": payload]
    }

    func meta(_ id: String = "chat", agent: Bool = false) -> [String: Any] {
        row("session_meta", ["id": id, "cwd": "/Projects/widget", "source": agent ? ["subagent": ["other": "guardian"]] : "vscode"])
    }

    func context(_ turn: String, model: String = "model-a") -> [String: Any] {
        row("turn_context", ["turn_id": turn, "model": model])
    }

    func usage(_ response: String, turn: String, input: Int, output: Int = 20,
               date: String = "2026-11-05T10:00:00.000Z") -> [String: Any] {
        row("token_usage_record", ["response_id": response, "turn_id": turn,
            "usage": ["input_tokens": input, "cached_input_tokens": input / 2,
                      "output_tokens": output, "reasoning_output_tokens": output / 2,
                      "total_tokens": input + output]], date: date)
    }

    func legacy(_ total: Int, last: Int? = nil, date: String = "2026-11-05T10:00:00.000Z") -> [String: Any] {
        var info: [String: Any] = ["total_token_usage": ["input_tokens": total, "total_tokens": total]]
        if let last { info["last_token_usage"] = ["input_tokens": last, "total_tokens": last] }
        return row("event_msg", ["type": "token_count", "info": info], date: date)
    }

    func snapshot() async throws -> UsageSnapshot { try await reader.read(directory: directory) }

    func report(_ snapshot: UsageSnapshot, _ configure: (inout UsageQuery) -> Void = { _ in }) -> UsageReport {
        var query = UsageQuery()
        query.period = .all
        configure(&query)
        return snapshot.report(query: query, now: Date(timeIntervalSince1970: 1_799_999_999))
    }
}

struct UsageTests {
    @Test func modernRecordsReplaceLegacyAndDeduplicateResponses() async throws {
        let fixture = try HistoryFixture()
        let record = fixture.usage("response-1", turn: "turn-1", input: 100)
        try fixture.write([fixture.meta(), fixture.context("turn-1"), fixture.legacy(120), record, record])
        let report = fixture.report(try await fixture.snapshot())
        #expect(report.tokens.total == 120)
        #expect(report.tokens.input == 100)
        #expect(report.tokens.cachedInput == 50)
        #expect(report.tokens.output == 20)
        #expect(report.tokens.reasoning == 10)
        #expect(report.requestCount == 1)
        #expect(report.legacyCount == 0)
    }

    @Test func legacyUsesDeltasSkipsRepeatsAndHandlesCounterReset() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.context("old"),
            fixture.legacy(100, last: 100), fixture.legacy(100, last: 100),
            fixture.legacy(180, last: 80, date: "2026-11-05T10:01:00Z"),
            fixture.legacy(25, last: 25, date: "2026-11-05T10:02:00Z")])
        let report = fixture.report(try await fixture.snapshot())
        #expect(report.tokens.total == 205)
        #expect(report.requestCount == 3)
        #expect(report.legacyCount == 3)
    }

    @Test func inheritedCountersDoNotChargeUnobservedHistory() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.context("resumed"), fixture.legacy(1000, last: 100),
                           fixture.legacy(1050, last: 50, date: "2026-11-05T10:01:00Z")])
        #expect(fixture.report(try await fixture.snapshot()).tokens.total == 150)
    }

    @Test func mixedVersionsAndModelChangesAreAttributedPerTurn() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.context("old", model: "old-model"), fixture.legacy(100),
            fixture.context("new", model: "new-model"), fixture.legacy(220),
            fixture.usage("new-response", turn: "new", input: 100),
            fixture.usage("late-old-response", turn: "old", input: 80)])
        let report = fixture.report(try await fixture.snapshot())
        #expect(report.tokens.total == 220)
        #expect(report.models.first(where: { $0.model == "old-model" })?.tokens == 100)
        #expect(report.models.first(where: { $0.model == "new-model" })?.tokens == 120)
    }

    @Test func archivedCopiesAndThreadIndexDoNotDuplicateUsage() async throws {
        let fixture = try HistoryFixture()
        let rows = [fixture.meta(), fixture.context("turn"), fixture.usage("response", turn: "turn", input: 100)]
        try fixture.write(rows)
        let archive = fixture.directory.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try fixture.write(rows, to: archive.appendingPathComponent("copy.jsonl"))
        try fixture.write([["id": "chat", "thread_name": "Old title"], ["id": "chat", "thread_name": "Updated title"]],
                          to: fixture.directory.appendingPathComponent("session_index.jsonl"))
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.title == "Updated title")
        #expect(snapshot.sessions.first?.isArchived == false)
        #expect(fixture.report(snapshot).tokens.total == 120)
    }

    @Test func filtersUseRequestDatesRatherThanSessionStart() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.context("turn", model: "model-a"),
            fixture.usage("older", turn: "turn", input: 100, date: "2026-10-01T10:00:00Z"),
            fixture.usage("newer", turn: "turn", input: 200, date: "2026-11-05T10:00:00Z")])
        let snapshot = try await fixture.snapshot()
        var query = UsageQuery()
        query.period = .today
        query.model = "model-a"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
        let report = snapshot.report(query: query, now: now, calendar: calendar)
        #expect(report.tokens.total == 220)
        #expect(report.hourly)
        #expect(report.timeline.count == 16)
        #expect(report.timeline.reduce(0) { $0 + $1.tokens } == 220)
        query.search = "WIDGET"
        #expect(snapshot.report(query: query, now: now, calendar: calendar).tokens.total == 220)
        query.model = "another-model"
        #expect(snapshot.report(query: query, now: now, calendar: calendar).tokens.total == 0)
    }

    @Test func modernActiveFileSupersedesLegacyArchivedCopy() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.context("turn"), fixture.usage("new", turn: "turn", input: 100)])
        let archive = fixture.directory.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try fixture.write([fixture.meta(), fixture.context("turn"), fixture.legacy(120)],
                          to: archive.appendingPathComponent("old-copy.jsonl"))
        let report = fixture.report(try await fixture.snapshot())
        #expect(report.tokens.total == 120)
        #expect(report.requestCount == 1)
        #expect(report.legacyCount == 0)
    }

    @Test func agentsCanBeExcludedAndUnknownModelsRemainUnknown() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.usage("chat-response", turn: "turn", input: 100)])
        try fixture.write([fixture.meta("agent", agent: true), fixture.context("turn", model: "review"),
                           fixture.usage("agent-response", turn: "turn", input: 30)],
                          to: fixture.file.deletingLastPathComponent().appendingPathComponent("agent.jsonl"))
        let snapshot = try await fixture.snapshot()
        #expect(fixture.report(snapshot).tokens.total == 170)
        #expect(fixture.report(snapshot) { $0.source = .chats }.tokens.total == 120)
        #expect(fixture.report(snapshot) { $0.source = .agents }.tokens.total == 50)
        #expect(snapshot.models.contains("Неизвестна"))
    }

    @Test func cacheInvalidatesAndPartialFinalLineIsRetried() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.context("turn")])
        #expect(fixture.report(try await fixture.snapshot()).tokens.total == 0)
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        let record = try JSONSerialization.data(withJSONObject: fixture.usage("appended", turn: "turn", input: 100))
        let middle = record.count / 2
        try handle.write(contentsOf: record.prefix(middle))
        #expect(fixture.report(try await fixture.snapshot()).tokens.total == 0)
        try handle.write(contentsOf: record.suffix(from: middle) + Data([0x0A]))
        try handle.close()
        let complete = try await fixture.snapshot()
        #expect(fixture.report(complete).tokens.total == 120)
        #expect(complete.warningCount == 0)
        #expect(fixture.report(try await fixture.snapshot()).tokens.total == 120)
    }

    @Test func badRowsAreReportedAndPromptsStayShort() async throws {
        let fixture = try HistoryFixture()
        try fixture.write([fixture.meta(), fixture.row("event_msg", ["type": "task_started", "turn_id": "turn"]),
            fixture.row("event_msg", ["type": "user_message", "message": "# AGENTS.md instructions"]),
            fixture.row("event_msg", ["type": "user_message", "message": String(repeating: "Task ", count: 100)]),
            fixture.context("turn"), fixture.usage("response", turn: "turn", input: 100)])
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.warningCount == 1)
        #expect(snapshot.sessions.first?.turns.first?.prompt.count == 300)
        #expect(snapshot.sessions.first?.title.hasPrefix("Task") == true)
    }

    @Test func missingHistoryFailsRatherThanPretendingZeroUsage() async throws {
        let fixture = try HistoryFixture()
        do {
            _ = try await fixture.reader.read(directory: fixture.directory.appendingPathComponent("missing"))
            Issue.record("Expected missing history error")
        } catch {
            #expect(error is UsageHistoryError)
        }
    }
}
