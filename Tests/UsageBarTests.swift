import Foundation
import Darwin

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@main
struct UsageBarTests {
    static var passed = 0

    static func main() throws {
        try test("累計スナップショットを重複加算しない", cumulativeSnapshots)
        try test("新旧トークンイベントを重複加算しない", newAndOldEvents)
        try test("旧形式からの移行分を保持する", migrationResidual)
        try test("親スレッドのレコードを除外する", foreignThread)
        try test("フォークの親履歴を課金しない", forkHistory)
        try test("モデル変更を別料金で集計する", modelSwitch)
        try test("Claudeストリーミングを重複除去する", claudeStreaming)
        try test("追記途中とファイル縮小を処理する", partialLineAndTruncation)
        try test("オフライン集計を差分更新する", offlineCollection)
        try test("利用枠の0・欠落・期限切れを区別する", quotaEdgeCases)
        try test("複数の利用枠を保持する", multipleBuckets)
        try test("連携状態を正しく判定する", providerLinkState)
        try test("Claude設定を保持して復元する", bridgePreservesSettings)
        try test("旧ClaudeブリッジをSwift版へ移行する", bridgeMigratesLegacyHelper)
        try test("不正なClaude設定を上書きしない", bridgeRejectsInvalidSettings)
        print("\(passed) tests passed")
    }

    static let prices = [
        "gpt-test": PriceRate(input: 10, cached: 1, write: 12.5, write1h: nil, output: 50),
        "claude-test": PriceRate(input: 5, cached: 0.5, write: 6.25, write1h: 10, output: 25)
    ]

    static func test(_ name: String, _ body: () throws -> Void) throws {
        do { try body(); passed += 1; print("✓ " + name) }
        catch { print("✗ " + name + ": \(error)"); throw error }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.failed(message) }
    }

    static func close(_ left: Double?, _ right: Double, _ message: String) throws {
        guard let left, abs(left - right) < 0.000000001 else { throw TestFailure.failed(message + ": \(String(describing: left)) != \(right)") }
    }

    static func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    static func collector(root: URL? = nil) -> UsageCollector {
        let base = root ?? FileManager.default.temporaryDirectory
        return UsageCollector(stateDirectory: base.appendingPathComponent("state"),
                              codexHome: base.appendingPathComponent("codex"),
                              claudeHome: base.appendingPathComponent("claude"),
                              pricingURL: URL(fileURLWithPath: "Sources/pricing.json"))
    }

    static func state(_ collector: UsageCollector, provider: String = "codex") -> FileState {
        var value = collector.newState(for: URL(fileURLWithPath: "session.jsonl"), provider: provider)
        value.model = "gpt-test"
        return value
    }

    static func usage(_ input: Int64, output: Int64 = 10, cached: Int64 = 0) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached]
    }

    static func event(_ usage: [String: Any]) -> [String: Any] {
        ["type": "event_msg", "timestamp": "2026-09-14T01:00:00Z",
         "payload": ["type": "token_count", "info": ["total_token_usage": usage]]]
    }

    static func cumulativeSnapshots() throws {
        let c = collector(); var s = state(c)
        var third = usage(250, output: 30, cached: 100); third["reasoning_output_tokens"] = 20
        for item in [usage(100, cached: 20), usage(100, cached: 20), third] { c.consume(event(item), state: &s) }
        let row = c.summarize([s], prices: prices)[0]
        try check(row.input == 250 && row.output == 30 && row.cached == 100, "累計値が不正")
        try close(row.cost, (150 * 10 + 100 + 30 * 50) / 1_000_000, "料金が不正")
    }

    static func newAndOldEvents() throws {
        let c = collector(); var s = state(c)
        let record: [String: Any] = ["type": "token_usage_record", "payload": ["thread_id": "session", "response_id": "r1", "usage": usage(100)]]
        c.consume(record, state: &s); c.consume(record, state: &s); c.consume(event(usage(100)), state: &s)
        try check(c.summarize([s], prices: prices)[0].input == 100, "新旧イベントが重複した")
    }

    static func migrationResidual() throws {
        let c = collector(); var s = state(c)
        c.consume(event(usage(100)), state: &s)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "session", "response_id": "r", "usage": usage(50)]], state: &s)
        c.consume(event(usage(150, output: 20)), state: &s)
        try check(c.summarize([s], prices: prices)[0].input == 150, "移行前の利用量が失われた")
    }

    static func foreignThread() throws {
        let c = collector(); var s = state(c)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "parent", "response_id": "r", "usage": usage(999)]], state: &s)
        try check(c.summarize([s], prices: prices).isEmpty, "親レコードを集計した")
    }

    static func forkHistory() throws {
        let c = collector(); var s = state(c)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "parent", "response_id": "parent-r", "usage": usage(1000)]], state: &s)
        c.consume(event(usage(1000)), state: &s)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "session", "response_id": "own-r", "usage": usage(100)]], state: &s)
        c.consume(event(usage(1100)), state: &s)
        try check(c.summarize([s], prices: prices)[0].input == 100, "フォークの親履歴を集計した")
    }

    static func modelSwitch() throws {
        let c = collector(); var s = state(c)
        c.consume(event(usage(100)), state: &s); s.model = "unknown-new-model"; c.consume(event(usage(200, output: 20)), state: &s)
        let row = c.summarize([s], prices: prices)[0]
        try check(row.cost == nil && row.knownCost > 0 && row.models.count == 2, "モデル別料金が不正")
    }

    static func claudeStreaming() throws {
        let c = collector(); var s = state(c, provider: "claude")
        var message: [String: Any] = ["type": "assistant", "sessionId": "session", "message": [
            "id": "m1", "model": "converse/global.anthropic.claude-test", "usage": [
                "input_tokens": 100, "output_tokens": 10, "cache_read_input_tokens": 1000,
                "cache_creation_input_tokens": 200, "cache_creation": ["ephemeral_1h_input_tokens": 50]
            ]
        ]]
        c.consume(message, state: &s); c.consume(message, state: &s)
        var body = message["message"] as! [String: Any]
        var tokens = body["usage"] as! [String: Any]; tokens["output_tokens"] = 30; body["usage"] = tokens; message["message"] = body
        c.consume(message, state: &s)
        let row = c.summarize([s, s], prices: prices)[0]
        try check(row.input == 1300 && row.output == 30 && row.cached == 1000 && row.write == 200, "Claude重複除去が不正")
        let expectedCost = (500.0 + 750.0 + 500.0 + 937.5 + 500.0) / 1_000_000
        try close(row.cost, expectedCost, "Claude料金が不正")
    }

    static func partialLineAndTruncation() throws {
        try temporary { root in
            let c = collector(root: root); let path = root.appendingPathComponent("s.jsonl")
            let line = try JSONSerialization.data(withJSONObject: event(usage(100)))
            try line.prefix(30).write(to: path)
            var s = try c.scanFile(path, provider: "codex")
            try check(s.offset == 0, "部分行を進めた")
            let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd(); try handle.write(contentsOf: line.dropFirst(30) + Data([0x0A])); try handle.close()
            s = try c.scanFile(path, provider: "codex", previous: s)
            try check(c.summarize([s], prices: prices)[0].input == 100, "追記行を読めない")
            s.mtime += 500 // Python statからFoundation Dateへ移る際の丸め差
            let unchanged = try c.scanFile(path, provider: "codex", previous: s)
            try check(c.summarize([unchanged], prices: prices)[0].input == 100, "未変更ファイルを壊した")
            let short = try JSONSerialization.data(withJSONObject: event(usage(20))) + Data([0x0A]); try short.write(to: path)
            s = try c.scanFile(path, provider: "codex", previous: s)
            try check(c.summarize([s], prices: prices)[0].input == 20, "縮小ファイルを再構築しない")
        }
    }

    static func quotaEdgeCases() throws {
        let c = collector(); let now = Date().timeIntervalSince1970
        let valid = c.normalizeWindow(["usedPercent": 0, "resetsAt": now + 100], label: "5h", observed: now, now: now)
        try check(valid?.remaining == 100, "0%使用を欠落扱いした")
        try check(c.normalizeWindow(["usedPercent": NSNull()], label: "5h", observed: 0, now: now) == nil, "欠落値を0扱いした")
        let expired = c.normalizeWindow(["usedPercent": 30, "resetsAt": 1], label: "5h", observed: 1, now: now)
        try check(expired?.expired == true && expired?.remaining == 70, "期限切れから100%を推測した")
    }

    static func offlineCollection() throws {
        try temporary { root in
            let sessions = root.appendingPathComponent("codex/sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let path = sessions.appendingPathComponent("end-to-end.jsonl")
            let first = try JSONSerialization.data(withJSONObject: event(usage(100))) + Data([0x0A])
            try first.write(to: path)
            let c = collector(root: root)
            var snapshot = try c.collect(live: false)
            try check(snapshot.sessions.count == 1 && snapshot.sessions[0].input == 100, "初回集計が不正")
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: event(usage(200))) + Data([0x0A]))
            try handle.close()
            snapshot = try c.collect(live: false)
            try check(snapshot.sessions.count == 1 && snapshot.sessions[0].input == 200, "差分更新が不正")
        }
    }

    static func multipleBuckets() throws {
        let c = collector(); let now = Date().timeIntervalSince1970
        let result: [String: Any] = ["rateLimitsByLimitId": [
            "codex": ["primary": ["usedPercent": 7, "windowDurationMins": 10080]],
            "other": ["primary": ["usedPercent": 99, "windowDurationMins": 300]]
        ]]
        let windows = c.codexWindows(result, observed: now, now: now)
        try check(windows.map(\.remaining) == [93, 1] && windows[0].label == "7日", "複数枠が不正")
    }

    static func providerLinkState() throws {
        try temporary { root in
            let c = collector(root: root); let state = root.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try check(c.codexQuota(states: [], live: false, force: false).linked == false, "Codexを誤連携判定した")
            try json(["linked": true], to: state.appendingPathComponent("codex-quota.json"))
            try check(c.codexQuota(states: [], live: false, force: false).linked == true, "Codex連携を検出しない")
            try check(c.claudeQuota().linked == false, "Claudeを誤連携判定した")
            try json(["installed": true], to: state.appendingPathComponent("bridge-config.json"))
            try check(c.claudeQuota().linked == false, "通知前Claudeを連携表示した")
            let now = Date().timeIntervalSince1970
            try json(["observed": now, "rate_limits": ["five_hour": ["used_percentage": 10, "resets_at": now + 3600]]], to: state.appendingPathComponent("claude-status.json"))
            try check(c.claudeQuota().linked == true, "Claude通知を検出しない")
        }
    }

    static func bridgePreservesSettings() throws {
        try temporary { root in
            let state = root.appendingPathComponent("state"), claude = root.appendingPathComponent("claude")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let helper = root.appendingPathComponent("helper"); try Data("helper".utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let original: [String: Any] = ["env": ["DUMMY": "retained"], "statusLine": ["type": "command", "command": "cat", "padding": 3], "hooks": ["a": []]]
            let settings = claude.appendingPathComponent("settings.json"); try json(original, to: settings)
            let manager = BridgeManager(stateDirectory: state, claudeDirectory: claude, helperSource: helper)
            _ = try manager.setup(); _ = try manager.setup(); _ = try manager.setup(remove: true)
            let restored = try readJSON(settings)
            try check(NSDictionary(dictionary: restored).isEqual(to: original), "元のstatusLineまたは他設定を復元しない")
        }
    }

    static func bridgeRejectsInvalidSettings() throws {
        try temporary { root in
            let claude = root.appendingPathComponent("claude"); try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let settings = claude.appendingPathComponent("settings.json"); try Data("{invalid".utf8).write(to: settings)
            let helper = root.appendingPathComponent("helper"); try Data().write(to: helper)
            let manager = BridgeManager(stateDirectory: root.appendingPathComponent("state"), claudeDirectory: claude, helperSource: helper)
            do { _ = try manager.setup(); throw TestFailure.failed("不正JSONを拒否しない") }
            catch BridgeError.invalidSettings {}
            let unchanged = try Data(contentsOf: settings)
            try check(String(data: unchanged, encoding: .utf8) == "{invalid", "不正設定を上書きした")
        }
    }

    static func bridgeMigratesLegacyHelper() throws {
        try temporary { root in
            let state = root.appendingPathComponent("state"), claude = root.appendingPathComponent("claude")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let helper = root.appendingPathComponent("helper"); try Data("swift-helper".utf8).write(to: helper)
            try json(["installed": true, "original": NSNull()], to: state.appendingPathComponent("bridge-config.json"))
            try json(["statusLine": ["type": "command", "command": "/usr/bin/python3 '\(state.path)/claude_bridge.py'"]],
                     to: claude.appendingPathComponent("settings.json"))
            let manager = BridgeManager(stateDirectory: state, claudeDirectory: claude, helperSource: helper)
            manager.migrateLegacyBridgeIfNeeded()
            let migrated = try readJSON(claude.appendingPathComponent("settings.json"))
            let command = (migrated["statusLine"] as? [String: Any])?["command"] as? String ?? ""
            try check(command.contains("UsageBarClaudeBridge") && !command.contains("python3"), "Swiftヘルパーへ移行しない")
            let installed = try Data(contentsOf: state.appendingPathComponent("UsageBarClaudeBridge"))
            try check(installed == Data("swift-helper".utf8), "ヘルパーを更新しない")
        }
    }

    static func json(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
