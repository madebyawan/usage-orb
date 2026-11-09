import XCTest
@testable import UsageOrb

final class ProviderParsingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testExpiredTokenIsNotReadAgainUntilTheItemChanges() {
        let cache = TokenCache()
        let stamp = now.addingTimeInterval(-100)
        cache.store("token", expiry: now.addingTimeInterval(-1), stamp: stamp)
        XCTAssertNil(cache.token(now: now))
        XCTAssertEqual(cache.knownFailure(stamp: stamp)?.kind, .auth)
        XCTAssertNil(cache.knownFailure(stamp: now), "A rewritten item is worth reading")
    }

    func testFailedReadIsRememberedUntilTheItemChanges() {
        let cache = TokenCache()
        let stamp = now.addingTimeInterval(-100)
        cache.store(failure: .notConfigured("denied"), stamp: stamp)
        XCTAssertEqual(cache.knownFailure(stamp: stamp), .notConfigured("denied"))
        XCTAssertNil(cache.knownFailure(stamp: now))
    }

    func testRejectedTokenStaysCachedWhileTheItemIsUnchanged() {
        let cache = TokenCache()
        let stamp = now.addingTimeInterval(-100)
        cache.store("token", expiry: now.addingTimeInterval(100), stamp: stamp)
        XCTAssertFalse(cache.hasChanged(stamp: stamp))
        XCTAssertTrue(cache.hasChanged(stamp: now))
        XCTAssertEqual(cache.token(now: now), "token")
    }

    func testUnknownModificationDateRulesNothingOut() {
        let cache = TokenCache()
        cache.store(failure: .notConfigured("none"), stamp: nil)
        XCTAssertNil(cache.knownFailure(stamp: nil))
        XCTAssertTrue(cache.hasChanged(stamp: nil))
    }

    func testClaudeLimitsList() throws {
        let object = try json("""
        {"five_hour": {"utilization": 7.0, "resets_at": "2026-10-18T20:39:59.614650+00:00"},
         "limits": [
          {"kind": "session", "group": "session", "percent": 7, "resets_at": "2026-10-18T20:39:59.614650+00:00", "scope": null},
          {"kind": "weekly_all", "group": "weekly", "percent": 21, "resets_at": "2026-10-24T03:59:59+00:00", "scope": null},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 3, "resets_at": null, "scope": {"model": "opus"}}
         ],
         "extra_usage": {"is_enabled": false}}
        """)
        let snapshot = try ClaudeCodeProvider.parse(object, now: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["claudeCode.session", "claudeCode.weekly_all", "claudeCode.weekly_scoped.opus"])
        XCTAssertEqual(snapshot.windows.map(\.name), ["Session", "Weekly", "Weekly · Opus"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [7, 21, 3])
        XCTAssertEqual(snapshot.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-10-24T03:59:59Z"))
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.source == .undocumentedAPI && $0.observedAt == now })
        XCTAssertTrue(snapshot.money.isEmpty)
    }

    func testClaudeFlatFallbackAndExtraUsage() throws {
        let object = try json("""
        {"five_hour": {"utilization": 41.5, "resets_at": "2026-10-18T20:00:00Z"},
         "seven_day": {"utilization": 80, "resets_at": "2026-10-24T04:00:00Z"},
         "seven_day_opus": null,
         "extra_usage": {"is_enabled": true, "used_credits": 1234, "currency": "USD", "decimal_places": 2}}
        """)
        let snapshot = try ClaudeCodeProvider.parse(object, now: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["claudeCode.session", "claudeCode.weekly_all"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [41.5, 80])
        XCTAssertEqual(snapshot.money.first?.amount ?? 0, 12.34, accuracy: 0.0001)
    }

    func testClaudeRejectsUnrecognisedResponse() throws {
        XCTAssertThrowsError(try ClaudeCodeProvider.parse(try json(#"{"something": 1}"#), now: now))
    }

    func testCodexRolloutLogUsesLastRateLimitLine() {
        let log = """
        {"timestamp":"2026-10-18T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1792010000},"secondary":null}}}
        {"timestamp":"2026-10-18T11:00:00.000Z","type":"response_item","payload":{"type":"message"}}
        {"timestamp":"2026-10-18T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1792010000},"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1792500000},"credits":{"has_credits":true,"unlimited":false,"balance":"17.5"},"plan_type":"plus"}}}
        {"timestamp":"2026-10-18T12:00:01.000Z","type":"event_msg","payload":{"type":"agent_message"}}
        """
        let snapshot = CodexProvider.parseLog(log, fileDate: now, now: now)
        XCTAssertEqual(snapshot?.windows.map(\.id), ["codex.300", "codex.10080"])
        XCTAssertEqual(snapshot?.windows.map(\.name), ["Session", "Weekly"])
        XCTAssertEqual(snapshot?.windows.map(\.usedPercent), [12.5, 40])
        XCTAssertEqual(snapshot?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_792_010_000))
        XCTAssertEqual(snapshot?.windows.first?.observedAt, ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z"))
        XCTAssertEqual(snapshot?.windows.first?.source, .localLog)
        XCTAssertEqual(snapshot?.money.first?.amount, 17.5)
        XCTAssertEqual(snapshot?.notes, ["Plan: Plus"])
    }

    func testCodexOlderRelativeResets() {
        let log = #"{"timestamp":"2026-10-18T12:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":60,"window_minutes":300,"resets_in_seconds":600}}}}"#
        let snapshot = CodexProvider.parseLog(log, fileDate: now, now: now)
        let observed = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        XCTAssertEqual(snapshot?.windows.first?.resetsAt, observed.addingTimeInterval(600))
    }

    func testCodexLogWithoutRateLimits() {
        XCTAssertNil(CodexProvider.parseLog(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
                                            fileDate: now, now: now))
    }

    func testCodexReadsNewestFileTail() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let day = home.appendingPathComponent("sessions/2026/10/18")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let old = day.appendingPathComponent("rollout-old.jsonl")
        let new = day.appendingPathComponent("rollout-new.jsonl")
        try #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":90,"window_minutes":300}}}}"#
            .write(to: old, atomically: true, encoding: .utf8)
        try #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":15,"window_minutes":300}}}}"#
            .write(to: new, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: new.path)

        let result = try await CodexProvider(home: home).fetch(now: now)
        XCTAssertEqual(result.windows.first?.usedPercent, 15)
        XCTAssertEqual(result.windows.first?.observedAt, now, "falls back to the file's modification time")
    }

    func testDeepSeekBalance() throws {
        let object = try json("""
        {"is_available": false, "balance_infos": [{"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}]}
        """)
        let snapshot = try DeepSeekProvider.parse(object, now: now)
        XCTAssertTrue(snapshot.windows.isEmpty, "a balance is never a quota window")
        XCTAssertEqual(snapshot.money.map(\.amount), [110])
        XCTAssertEqual(snapshot.money.first?.currency, "CNY")
        XCTAssertEqual(snapshot.money.first?.kind, .balance)
        XCTAssertEqual(snapshot.notes.count, 1)
    }

    func testOpenRouterKeyWithAndWithoutLimit() throws {
        let unlimited = try OpenRouterProvider.parse(try json("""
        {"data": {"label": "k", "limit": null, "limit_remaining": null, "usage": 25.5, "usage_daily": 0.25, "usage_weekly": 3, "usage_monthly": 9.75}}
        """), now: now)
        XCTAssertEqual(unlimited.money.map(\.id), ["openRouter.spendDaily", "openRouter.spendMonthly"])
        XCTAssertTrue(unlimited.windows.isEmpty)

        let limited = try OpenRouterProvider.parse(try json("""
        {"data": {"limit": 50, "limit_remaining": 12.5, "limit_reset": "monthly", "usage": 37.5}}
        """), now: now)
        let limit = try XCTUnwrap(limited.windows.first)
        XCTAssertEqual(limit.id, "openRouter.keyLimit")
        XCTAssertEqual(limit.usedPercent, 75)
        XCTAssertNil(limit.resetsAt)
        XCTAssertTrue(limit.detail?.contains("resets monthly") == true)
    }
}
