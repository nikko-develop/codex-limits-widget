import CodexLimitsCore
import Foundation
import Testing

struct LimitsTests {
    @Test func testDocumentedResponseAndWindowDurations() throws {
        let data = Data("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1900000000}},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"plus",
           "primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1900000000},
           "secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1900001000}}}}
        """.utf8)
        let bucket = try #require(JSONDecoder().decode(LimitsResponse.self, from: data).codex)
        #expect(bucket.primary?.remainingPercent == 75)
        #expect(bucket.secondary?.remainingPercent == 58)
        #expect(bucket.minimumRemaining == 58)
        #expect(bucket.primary?.title == "5 ч")
        #expect(bucket.secondary?.title == "7 дн.")
        #expect(bucket.primary?.resetDate == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func testOlderResponseWithoutBucketIDAndMissingFields() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":12.5},"secondary":null}}"#.utf8)
        let bucket = try #require(JSONDecoder().decode(LimitsResponse.self, from: data).codex)
        #expect(bucket.primary?.remainingPercent == 87.5)
        #expect(bucket.primary?.title == "Окно лимита")
        #expect(bucket.primary?.resetDate == nil)
        #expect(bucket.windows.count == 1)
    }

    @Test func testDoesNotSubstituteUnrelatedBucket() throws {
        for json in [
            #"{"rateLimitsByLimitId":{"codex_other":{"primary":{"usedPercent":1}}}}"#,
            #"{"rateLimits":{"limitId":"codex_other","primary":{"usedPercent":1}}}"#,
            #"{"rateLimits":null,"rateLimitsByLimitId":null}"#
        ] {
            #expect(try JSONDecoder().decode(LimitsResponse.self, from: Data(json.utf8)).codex == nil)
        }
    }

    @Test func testRemainingIsClampedAndUnknownResetStaysUnknown() {
        #expect(LimitWindow(usedPercent: 125, windowDurationMins: nil, resetsAt: nil).remainingPercent == 0)
        #expect(LimitWindow(usedPercent: -1, windowDurationMins: nil, resetsAt: nil).remainingPercent == 100)
    }

    @Test func testSnapshotStalenessAfterAgeOrResetAndRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let window = LimitWindow(usedPercent: 20, windowDurationMins: 60, resetsAt: now.addingTimeInterval(300).timeIntervalSince1970)
        let snapshot = LimitsSnapshot(bucket: LimitBucket(limitId: "codex", limitName: nil,
            primary: window, secondary: nil, planType: nil), fetchedAt: now)
        #expect(!snapshot.isStale(at: now))
        #expect(snapshot.isStale(at: now.addingTimeInterval(300)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(601)))
        let roundTrip = try JSONDecoder().decode(LimitsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(roundTrip.bucket == snapshot.bucket)
        #expect(roundTrip.fetchedAt == now)
    }

    @Test func testExplicitInvalidCLIPathDoesNotSilentlyUseAnotherAccount() {
        #expect(CodexLocator.find(override: "/does/not/exist/codex") == nil)
    }
}
