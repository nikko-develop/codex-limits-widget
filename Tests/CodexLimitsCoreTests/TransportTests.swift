import CodexLimitsCore
import Foundation
import Testing

final class TransportTests {
    private var directories: [URL] = []

    deinit {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func server(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let executable = directory.appendingPathComponent("fake-codex")
        try ("#!/usr/bin/python3\nimport json, sys, time\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private let handshake = #"""
    request = json.loads(sys.stdin.readline())
    assert request['method'] == 'initialize' and request['id'] == 0
    assert request['params']['clientInfo']['name'] == 'codex_limits_widget'
    print('{"id":0,"result":{"userAgent":"test"}}', flush=True)
    assert json.loads(sys.stdin.readline())['method'] == 'initialized'
    request = json.loads(sys.stdin.readline())
    assert request['method'] == 'account/rateLimits/read' and request['id'] == 1

    """#

    @Test func testHandshakeNotificationsAndPartialMessages() throws {
        let executable = try server(handshake + #"""
        print('{"method":"account/updated","params":{}}', flush=True)
        sys.stdout.write('{"id":1,"result":{"rateLimits":{"limitId":"codex",')
        sys.stdout.flush()
        time.sleep(0.02)
        print('"primary":{"usedPercent":37,"windowDurationMins":300}}}}', flush=True)
        sys.stdin.read()
        """#)
        let result = try CodexClient(executable: executable, timeout: 2).read()
        #expect(result.bucket.primary?.remainingPercent == 63)
    }

    @Test func testRPCErrorDoesNotLeakServerDiagnostics() throws {
        let executable = try server(handshake + #"""
        print('{"id":1,"error":{"code":-32001,"message":"private-token-do-not-display"}}', flush=True)
        """#)
        do {
            _ = try CodexClient(executable: executable, timeout: 2).read()
            Issue.record("Expected an error")
        } catch {
            #expect(!error.localizedDescription.contains("private-token"))
            #expect(error.localizedDescription.contains("-32001"))
        }
    }

    @Test func testTimeoutTerminatesUnresponsiveServer() throws {
        let executable = try server("time.sleep(30)\n")
        let start = Date()
        do {
            _ = try CodexClient(executable: executable, timeout: 0.15).read()
            Issue.record("Expected timeout")
        } catch {
            guard case CodexClientError.timedOut = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func testMissingWindowsAreNotReportedAsFullQuota() throws {
        let executable = try server(handshake + #"""
        print('{"id":1,"result":{"rateLimits":{"primary":null,"secondary":null}}}', flush=True)
        """#)
        do {
            _ = try CodexClient(executable: executable, timeout: 2).read()
            Issue.record("Expected an error")
        } catch {
            guard case CodexClientError.noLimits = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test func testMalformedServerOutputIsRejected() throws {
        let executable = try server(handshake + "print('not-json', flush=True)\n")
        do {
            _ = try CodexClient(executable: executable, timeout: 2).read()
            Issue.record("Expected an error")
        } catch {
            guard case CodexClientError.invalidResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }
}
