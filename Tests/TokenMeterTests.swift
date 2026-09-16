import Foundation
import Darwin

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@main
struct TokenMeterTests {
    static var passed = 0

    static func main() throws {
        try test("累計スナップショットを重複加算しない", cumulativeSnapshots)
        try test("新旧トークンイベントを重複加算しない", newAndOldEvents)
        try test("旧形式からの移行分を保持する", migrationResidual)
        try test("親スレッドのレコードを除外する", foreignThread)
        try test("フォークの親履歴を課金しない", forkHistory)
        try test("Codexエージェントを親チャットへ重複なく集計する", spawnedAgentGrouping)
        try test("旧キャッシュの親子情報を先頭メタデータから復元する", cachedAgentMetadata)
        try test("親のIDを誤保存した子キャッシュだけ再構築する", cachedAgentIdentity)
        try test("子孫・アーカイブ重複・親不在の使用量を保持する", nestedAgentGrouping)
        try test("モデル変更を別料金で集計する", modelSwitch)
        try test("Claudeストリーミングを重複除去する", claudeStreaming)
        try test("追記途中とファイル縮小を処理する", partialLineAndTruncation)
        try test("オフライン集計を差分更新する", offlineCollection)
        try test("ファイル走査を上限内で並列実行する", boundedFileScanning)
        try test("並列集計と直列集計のキャッシュ・差分結果が一致する", parallelCollection)
        try test("利用枠の0・欠落・期限切れを区別する", quotaEdgeCases)
        try test("複数の利用枠を保持する", multipleBuckets)
        try test("CodexアカウントIDを取得・保持する", codexAccountID)
        try test("ClaudeアカウントIDを読み取り変更・欠落を反映する", claudeAccountID)
        try test("公式ステータスと進行中インシデントを読む", providerStatusParsing)
        try test("連携状態を正しく判定する", providerLinkState)
        try test("Claude設定を保持して復元する", bridgePreservesSettings)
        try test("旧ClaudeブリッジをSwift版へ移行する", bridgeMigratesLegacyHelper)
        try test("旧名のSwift連携を更新して元の設定を復元する", bridgeMigratesRenamedHelper)
        try test("不正なClaude設定を上書きしない", bridgeRejectsInvalidSettings)
        try test("セッションを入出力・参考料金で並び替える", sessionSorting)
        try test("OpenAI公式MarkdownのStandard単価を読む", openAIPricingMarkdown)
        try test("Anthropic公式Markdownのキャッシュ単価を読む", anthropicPricingMarkdown)
        try test("自動単価よりユーザー単価を優先する", pricingPrecedence)
        try test("新モデルを追加し欠落モデルの単価を保持する", pricingDiscovery)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterTests-\(UUID().uuidString)")
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

    static func spawnedAgentGrouping() throws {
        let c = collector()
        var parent = c.newState(for: URL(fileURLWithPath: "parent.jsonl"), provider: "codex")
        c.consume(["type": "session_meta", "payload": ["id": "parent", "cwd": "/tmp/project"]], state: &parent)
        c.consume(["type": "turn_context", "payload": ["model": "gpt-test"]], state: &parent)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "parent", "response_id": "parent-own", "usage": usage(200)]], state: &parent)

        var child = c.newState(for: URL(fileURLWithPath: "child.jsonl"), provider: "codex")
        let source: [String: Any] = ["subagent": ["thread_spawn": [
            "parent_thread_id": "parent", "depth": 1, "agent_nickname": "Astra Worker"
        ]]]
        c.consume(["type": "session_meta", "payload": [
            "id": "child", "cwd": "/tmp/project", "source": source
        ]], state: &child)
        try check(child.parentID == "parent" && child.forked == true,
                  "thread_spawnのparent_thread_idから親を復元しない")
        // Codex copies the parent's metadata and usage into a spawned log.
        c.consume(["type": "session_meta", "payload": ["id": "parent", "cwd": "/tmp/project"]], state: &child)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "parent", "response_id": "inherited", "usage": usage(999)]], state: &child)
        c.consume(["type": "turn_context", "payload": ["model": "gpt-test"]], state: &child)
        c.consume(["type": "token_usage_record", "payload": ["thread_id": "child", "response_id": "child-own", "usage": usage(100)]], state: &child)

        let rows = c.summarize([parent, child], prices: prices)
        try check(rows.count == 1, "子エージェントが別のチャット行になった")
        try check(rows[0].input == 300 && rows[0].members.count == 2, "親子の利用量を正しく合算しない")
        try check(rows[0].members[1].input == 100, "複製された親履歴を子の利用量に含めた")
        try check(rows[0].members[1].agentName == "Astra Worker", "エージェント名を保持しない")
    }

    static func agentLog(_ id: String, parent: String? = nil, input: Int64) throws -> Data {
        var meta: [String: Any] = ["id": id, "cwd": "/tmp/synthetic-project"]
        if let parent {
            meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent, "agent_nickname": "Worker"]]]
        }
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": meta],
            ["type": "turn_context", "payload": ["model": "gpt-test"]],
            ["type": "token_usage_record", "timestamp": 1000, "payload": [
                "thread_id": id, "response_id": id + "-own", "usage": usage(input)]],
            event(usage(input))
        ]
        return try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(0x0A)
        }
    }

    struct TestSessionCache: Codable {
        var version: Int
        var files: [String: FileState]
    }

    static func cachedAgentMetadata() throws {
        for version in 5...8 {
            try temporary { root in
                let c = collector(root: root)
                let sessions = c.codexHome.appendingPathComponent("sessions")
                try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
                let parent = sessions.appendingPathComponent("parent.jsonl")
                let child = sessions.appendingPathComponent("child.jsonl")
                try agentLog("parent", input: 200).write(to: parent)
                try agentLog("child", parent: "parent", input: 100).write(to: child)
                _ = try c.collect(live: false)
                let cacheURL = c.stateDirectory.appendingPathComponent("sessions-cache.json")
                var cache = try JSONDecoder().decode(TestSessionCache.self, from: Data(contentsOf: cacheURL))
                cache.version = version
                for key in Array(cache.files.keys) {
                    cache.files[key]?.sessionMetaSeen = nil
                    cache.files[key]?.parentID = nil
                    cache.files[key]?.agentName = nil
                    cache.files[key]?.forked = false
                    // A sentinel proves migration reused counters/offsets instead of rescanning.
                    cache.files[key]?.malformed = 7
                }
                try JSONEncoder().encode(cache).write(to: cacheURL)
                let snapshot = try c.collect(live: false)
                try check(snapshot.sessions.count == 1 && snapshot.sessions[0].members.count == 2,
                          "version \(version) のキャッシュから子を復元しない")
                try check(snapshot.sessions[0].input == 300 && snapshot.sessions[0].members[1].input == 100,
                          "旧累計と子実績を重複加算した")
                let repaired = try JSONDecoder().decode(TestSessionCache.self, from: Data(contentsOf: cacheURL))
                try check(repaired.version == UsageCollector.cacheVersion, "キャッシュ形式を更新しない")
                for (key, old) in cache.files {
                    let new = repaired.files[key]!
                    try check(new.requests == old.requests && new.offset == old.offset && new.malformed == 7,
                              "正しい使用量を再走査した")
                }
                try check(repaired.files.values.first(where: { $0.id == "child" })?.parentID == "parent", "親IDを保存しない")
                let unchanged = try c.collect(live: false)
                try check(unchanged.sessions == snapshot.sessions, "移行後の再読で数値が変わる")
                let handle = try FileHandle(forWritingTo: child)
                try handle.seekToEnd()
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: [
                    "type": "token_usage_record", "payload": ["thread_id": "child", "response_id": "next", "usage": usage(50)]
                ]) + Data([0x0A]))
                try handle.close()
                let appended = try c.collect(live: false)
                try check(appended.sessions[0].input == 350, "修復後の差分更新が不正")
            }
        }
    }

    static func cachedAgentIdentity() throws {
        try temporary { root in
            let c = collector(root: root)
            let sessions = c.codexHome.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let path = sessions.appendingPathComponent("child.jsonl")
            try agentLog("child", parent: "parent", input: 100).write(to: path)
            _ = try c.collect(live: false)
            let cacheURL = c.stateDirectory.appendingPathComponent("sessions-cache.json")
            var cache = try JSONDecoder().decode(TestSessionCache.self, from: Data(contentsOf: cacheURL))
            cache.version = 8
            let key = cache.files.keys.first!
            cache.files[key]?.id = "parent"
            cache.files[key]?.sessionMetaSeen = nil
            cache.files[key]?.requests = [:]
            cache.files[key]?.foreignRecords = true
            try JSONEncoder().encode(cache).write(to: cacheURL)
            let rows = try c.collect(live: false).sessions
            try check(rows.count == 1 && rows[0].id == "child" && rows[0].input == 100,
                      "誤ったIDのキャッシュを再構築しない")
            try check(rows[0].parentID == "parent", "親不在時に関係を失った")
        }
    }

    static func nestedAgentGrouping() throws {
        try temporary { root in
            let c = collector(root: root)
            var states: [FileState] = []
            for (id, parent, input) in [("root", nil, 200), ("child", "root", 100), ("grandchild", "child", 50)] as [(String, String?, Int64)] {
                let path = root.appendingPathComponent(id + ".jsonl")
                try agentLog(id, parent: parent, input: input).write(to: path)
                states.append(try c.scanFile(path, provider: "codex"))
            }
            let rows = c.summarize(states + [states[1]], prices: prices)
            try check(rows.count == 1 && rows[0].input == 350 && rows[0].members.count == 3,
                      "子孫やアーカイブ複製を重複加算した")
            try check(rows[0].members[2].parentID == "child", "孫の親が不明")
            let orphan = c.summarize(Array(states.dropFirst()), prices: prices)
            try check(orphan.count == 1 && orphan[0].input == 150 && orphan[0].parentID == "root",
                      "親ログ不在で子の使用量が消えた")
        }
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

    static func boundedFileScanning() throws {
        let condition = NSCondition()
        var active = 0, peak = 0, arrivals = 0
        let values = FileScanExecutor.map(Array(0..<20), concurrency: 4) { index in
            condition.lock()
            active += 1; arrivals += 1; peak = max(peak, active)
            condition.broadcast()
            let deadline = Date().addingTimeInterval(3)
            // The first four jobs must overlap; a serial executor times out and
            // fails the peak assertion instead of deadlocking the test suite.
            while arrivals < 4 {
                if !condition.wait(until: deadline) { break }
            }
            active -= 1
            condition.unlock()
            return index * 2
        }
        try check(peak == 4, "4ワーカーが同時実行されない、または上限を超えた")
        try check(values == (0..<20).map { $0 * 2 }, "結果が欠落・重複した、または順序が変わった")
        let empty: [Int] = FileScanExecutor.map([], concurrency: 4) { $0 }
        try check(empty.isEmpty, "空の入力を処理できない")
    }

    static func parallelCollection() throws {
        struct Cache: Decodable { var files: [String: FileState] }
        try temporary { root in
            let codex = root.appendingPathComponent("codex")
            let claude = root.appendingPathComponent("claude")
            let serial = UsageCollector(stateDirectory: root.appendingPathComponent("serial"),
                                        codexHome: codex, claudeHome: claude, scanConcurrency: 1)
            let parallel = UsageCollector(stateDirectory: root.appendingPathComponent("parallel"),
                                          codexHome: codex, claudeHome: claude, scanConcurrency: 4)
            var paths: [URL] = []
            for index in 0..<12 {
                let path = root.appendingPathComponent(index < 8
                    ? "codex/sessions/session-\(index).jsonl"
                    : "claude/projects/project/subagents/agent-\(index).jsonl")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let record: [String: Any] = index < 8 ? event(usage(Int64(100 + index))) : [
                    "type": "assistant", "sessionId": "shared-parent", "timestamp": 1000,
                    "message": ["id": "r", "model": "claude-test", "usage": usage(50)]
                ]
                try (JSONSerialization.data(withJSONObject: record) + Data([0x0A])).write(to: path)
                paths.append(path)
            }
            func compare() throws -> [String: FileState] {
                let left = try serial.collect(live: false)
                let right = try parallel.collect(live: false)
                try check(left.errors == right.errors, "読み取りエラーが一致しない")
                try check(left.sessions.count == right.sessions.count &&
                          left.sessions.reduce(0) { $0 + $1.input } == right.sessions.reduce(0) { $0 + $1.input },
                          "集計結果が一致しない")
                func cache(_ collector: UsageCollector) throws -> [String: FileState] {
                    try JSONDecoder().decode(Cache.self, from: Data(contentsOf:
                        collector.stateDirectory.appendingPathComponent("sessions-cache.json"))).files
                }
                let a = try cache(serial), b = try cache(parallel)
                try check(a == b, "ファイル単位の集計キャッシュが一致しない")
                return Dictionary(uniqueKeysWithValues: b.map { (URL(fileURLWithPath: $0.key).lastPathComponent, $0.value) })
            }
            let initial = try compare()
            try check(initial.count == 12, "走査したファイル数が不正: \(initial.count)")
            try check(initial[paths[8].lastPathComponent]?.id == "agent-8", "Claudeサブエージェントを保持しない")
            let unchanged = try compare()
            try check(initial == unchanged, "未変更キャッシュが変化した")
            let partial = try JSONSerialization.data(withJSONObject: event(usage(500)))
            let handle = try FileHandle(forWritingTo: paths[0])
            try handle.seekToEnd(); try handle.write(contentsOf: partial.prefix(30)); try handle.close()
            let pending = try compare()
            try check(pending[paths[0].lastPathComponent]?.offset == initial[paths[0].lastPathComponent]?.offset, "部分行を消費した")
            let append = try FileHandle(forWritingTo: paths[0])
            try append.seekToEnd(); try append.write(contentsOf: partial.dropFirst(30) + Data([0x0A])); try append.close()
            try (JSONSerialization.data(withJSONObject: event(usage(2))) + Data([0x0A])).write(to: paths[1])
            let changed = try compare()
            try check(changed[paths[0].lastPathComponent]?.legacy["unknown"]?.input == 500 &&
                      changed[paths[1].lastPathComponent]?.legacy["unknown"]?.input == 2, "追記・置換結果が不正")
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

    static func codexAccountID() throws {
        try temporary { root in
            let c = collector(root: root)
            try check(c.codexAccountID(["account": ["type": "chatgpt", "email": " user@example.com "]]) == "user@example.com", "メールアドレスをアカウントIDとして読めない")
            try check(c.codexAccountID(["account": ["type": "apiKey"]]) == nil, "存在しないIDを推測した")
            let state = root.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            let now = Date().timeIntervalSince1970
            try json(["observed": now, "raw": ["rateLimits": ["primary": ["usedPercent": 10]]],
                      "accountID": "user@example.com", "linked": true],
                     to: state.appendingPathComponent("codex-quota.json"))
            try check(c.codexQuota(states: [], live: false, force: false).accountID == "user@example.com", "キャッシュしたアカウントIDを保持しない")
            try check(c.cachedCodexAccountID() == "user@example.com", "起動直後にキャッシュしたアカウントIDを読めない")
            var newerLog = c.newState(for: root.appendingPathComponent("session.jsonl"), provider: "codex")
            newerLog.rate = RateSample(raw: JSONValue(any: ["primary": ["used_percent": 20]]), observed: now + 1)
            let quotaFromLog = c.codexQuota(states: [newerLog], live: false, force: false)
            try check(quotaFromLog.source == "セッションログ" && quotaFromLog.accountID == "user@example.com", "ログの利用枠を使うと保存済みIDが消える")
        }
    }

    static func providerStatusParsing() throws {
        let summary = Data(#"""
        {
          "page":{"updated_at":"2026-09-15T09:10:54.237Z","url":"https://status.example.com"},
          "status":{"indicator":"minor","description":"Minor Service Outage"},
          "components":[
            {"id":"codex","name":"Codex API","status":"operational"},
            {"id":"files","name":"Files","status":"partial_outage"}
          ]
        }
        """#.utf8)
        let incidents = Data(#"""
        {
          "incidents":[
            {"id":"active","name":"Elevated errors","status":"monitoring","impact":"minor","updated_at":"2026-09-15T09:00:00Z","resolved_at":null,
             "incident_updates":[{"body":"Recovery is being monitored.","status":"monitoring","created_at":"2026-09-15T08:30:00Z"}]},
            {"id":"done","name":"Resolved issue","status":"resolved","impact":"minor","updated_at":"2026-09-14T09:00:00Z","resolved_at":"2026-09-14T09:00:00Z","incident_updates":[]}
          ]
        }
        """#.utf8)
        let result = try ProviderStatusService().parse(summaryData: summary, incidentsData: incidents,
                                                       providerID: "openai", providerName: "OpenAI", baseURL: "https://status.example.com")
        try check(result.hasIssue, "障害状態を検出しない")
        try check(result.incidents.count == 1 && result.incidents[0].id == "active", "解決済みインシデントを除外しない")
        try check(result.incidents[0].url == "https://status.example.com/incidents/active", "インシデントURLが不正")
        try check(result.relevantComponents.map(\.id) == ["codex", "files"], "関連項目または障害中の項目を表示しない")
        try check(result.updated > 0, "小数秒付き日時を読めない")
    }

    static func claudeAccountID() throws {
        try temporary { root in
            let c = collector(root: root)
            let path = root.appendingPathComponent("claude/.claude.json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try check(c.claudeQuota().accountID == nil, "独立プロファイルで実アカウントを読んだ")
            try json(["oauthAccount": ["emailAddress": " first@example.com ", "accountUuid": "account-1"]], to: path)
            let original = try Data(contentsOf: path)
            try check(c.claudeQuota().accountID == "first@example.com", "メールアドレスを優先しない")
            let afterRead = try Data(contentsOf: path)
            try check(afterRead == original, "アカウント設定を書き換えた")
            try json(["oauthAccount": ["emailAddress": "next@example.com"]], to: path)
            try check(c.claudeQuota().accountID == "next@example.com", "アカウント変更が反映されない")
            try json(["oauthAccount": ["emailAddress": " ", "accountUuid": "account-2"]], to: path)
            try check(c.claudeQuota().accountID == "account-2", "メール未設定時にUUIDを表示しない")
            try json(["oauthAccount": ["emailAddress": 123]], to: path)
            try check(c.claudeQuota().accountID == nil, "不正なIDを表示した")
            try json([:], to: path)
            try check(c.claudeQuota().accountID == nil, "ログアウト後も古いIDを表示した")
            try Data("{".utf8).write(to: path)
            try check(c.claudeQuota().accountID == nil, "不正JSONでIDを表示した")
        }
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
            _ = try manager.setup(); _ = try manager.setup()
            let installed = try readJSON(settings)["statusLine"] as? [String: Any] ?? [:]
            try check((installed["refreshInterval"] as? Int) == 60, "Claude通知を60秒間隔に設定しない")
            try check((installed["padding"] as? Int) == 3, "既存の表示設定を保持しない")
            _ = try manager.setup(remove: true)
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
            let state = root.appendingPathComponent("UsageBar"), claude = root.appendingPathComponent("claude")
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
            try check(command.contains("TokenMeterClaudeBridge") && !command.contains("python3"), "Swiftヘルパーへ移行しない")
            let installed = try Data(contentsOf: state.appendingPathComponent("TokenMeterClaudeBridge"))
            try check(installed == Data("swift-helper".utf8), "ヘルパーを更新しない")
        }
    }

    static func bridgeMigratesRenamedHelper() throws {
        try temporary { root in
            let state = root.appendingPathComponent("UsageBar"), claude = root.appendingPathComponent("claude")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let helper = root.appendingPathComponent("helper")
            try Data("new-helper".utf8).write(to: helper)
            let original: [String: Any] = ["type": "command", "command": "cat", "padding": 3]
            let configURL = state.appendingPathComponent("bridge-config.json")
            let settingsURL = claude.appendingPathComponent("settings.json")
            try json(["installed": true, "original": original], to: configURL)
            try json(["statusLine": ["type": "command", "command": "'\(state.path)/UsageBarClaudeBridge'", "padding": 3],
                      "env": ["DUMMY": "retained"]], to: settingsURL)
            let manager = BridgeManager(stateDirectory: state, claudeDirectory: claude, helperSource: helper)
            manager.migrateLegacyBridgeIfNeeded()
            let migrated = try readJSON(settingsURL)
            let command = (migrated["statusLine"] as? [String: Any])?["command"] as? String ?? ""
            try check(command.contains("TokenMeterClaudeBridge") && !command.contains("UsageBarClaudeBridge"), "旧名のヘルパーを更新しない")
            let installed = try Data(contentsOf: state.appendingPathComponent("TokenMeterClaudeBridge"))
            try check(installed == Data("new-helper".utf8), "新ヘルパーを配置しない")
            _ = try manager.setup(remove: true)
            let restored = try readJSON(settingsURL)
            try check(NSDictionary(dictionary: restored["statusLine"] as? [String: Any] ?? [:]).isEqual(to: original), "旧版の元コマンドを復元しない")
            try check((restored["env"] as? [String: String])?["DUMMY"] == "retained", "無関係な設定を変更した")
            // A later user edit must survive migration and removal.
            try json(["installed": true, "original": original], to: configURL)
            let changed: [String: Any] = ["statusLine": ["type": "command", "command": "echo user-edited"]]
            try json(changed, to: settingsURL)
            let nextManager = BridgeManager(stateDirectory: state, claudeDirectory: claude, helperSource: helper)
            nextManager.migrateLegacyBridgeIfNeeded()
            _ = try nextManager.setup(remove: true)
            let untouched = try readJSON(settingsURL)
            try check(NSDictionary(dictionary: untouched).isEqual(to: changed), "後から変更されたコマンドを上書きした")
        }
    }

    static func sessionSorting() throws {
        func session(_ id: String, input: Int64, output: Int64, cost: Double?, updated: Double) -> Session {
            Session(id: id, provider: "codex", title: id, cwd: "/tmp", updated: updated,
                    input: input, output: output, cached: 0, write: 0, cost: cost,
                    knownCost: cost ?? 0, unknownModels: cost == nil ? ["unknown"] : [], models: [])
        }
        let rows = [
            session("a", input: 100, output: 30, cost: 0.03, updated: 1),
            session("b", input: 300, output: 10, cost: nil, updated: 3),
            session("c", input: 200, output: 20, cost: 0.01, updated: 2)
        ]
        try check(sortedSessions(rows, by: SessionSort(key: .input, direction: .descending)).map(\.id) == ["b", "c", "a"], "入力の降順が不正")
        try check(sortedSessions(rows, by: SessionSort(key: .output, direction: .ascending)).map(\.id) == ["b", "c", "a"], "出力の昇順が不正")
        try check(sortedSessions(rows, by: SessionSort(key: .cost, direction: .ascending)).map(\.id) == ["c", "a", "b"], "料金の昇順または未設定の位置が不正")
        try check(sortedSessions(rows, by: SessionSort(key: .cost, direction: .descending)).map(\.id) == ["a", "c", "b"], "料金の降順または未設定の位置が不正")

        let descending = nextSessionSort(current: nil, key: .input)
        let ascending = nextSessionSort(current: descending, key: .input)
        let descendingAgain = nextSessionSort(current: ascending, key: .input)
        try check(descending == SessionSort(key: .input, direction: .descending), "1回目のクリックで降順にならない")
        try check(ascending == SessionSort(key: .input, direction: .ascending), "2回目のクリックで昇順にならない")
        try check(descendingAgain == SessionSort(key: .input, direction: .descending), "3回目のクリックで降順に戻らない")
    }

    static func openAIPricingMarkdown() throws {
        let markdown = """
        ### Standard pricing data
        | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | gpt-6-astra | $10.00 | $1.00 | $12.50 | $50.00 | $20.00 | $2.00 | $25.00 | $75.00 |
        ### Batch pricing data
        | gpt-batch-only | $5.00 | $0.50 | $6.25 | $25.00 | $10.00 | $1.00 | $12.50 | $37.50 |
        | gpt-6-astra | $5.00 | $0.50 | $6.25 | $25.00 | $10.00 | $1.00 | $12.50 | $37.50 |
        ### Grouped Pricing Table data
        | Category | Model | Input | Cached input | Output |
        | Codex | gpt-5.3-codex | $1.75 | $0.175 | $14.00 |
        """
        let rates = OfficialPricingUpdater.parseOpenAI(markdown)
        try check(rates["gpt-batch-only"] == nil, "Batch専用行を標準単価として追加した")
        try check(rates["gpt-6-astra"] == PriceRate(input: 10, cached: 1, write: 12.5, write1h: nil, output: 50), "Batch単価を選んだ")
        try check(rates["gpt-5.3-codex"] == PriceRate(input: 1.75, cached: 0.175, write: 1.75, write1h: nil, output: 14), "Codex単価を読めない")
    }

    static func anthropicPricingMarkdown() throws {
        let markdown = """
        | Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
        | --- | --- | --- | --- | --- | --- |
        | Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok[^1] | $50 / MTok |
        | Claude Sonnet 5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
        | Claude Haiku 4.5 | $1 / MTok | $1.25 / MTok | $2 / MTok | $0.10 / MTok | $5 / MTok |
        """
        let rates = OfficialPricingUpdater.parseAnthropic(markdown)
        let fable = PriceRate(input: 10, cached: 0.25, write: 12.5, write1h: 20, output: 50)
        try check(rates["claude-fable-5-1"] == fable, "Fable 5.1のキャッシュ単価を読めない")
        let bundled = try JSONDecoder().decode(PricingDocument.self, from: Data(contentsOf: URL(fileURLWithPath: "Sources/pricing.json")))
        try check(bundled.models["claude-fable-5-1"] == fable, "Fable 5.1の同梱単価が不正")
        try check(rates["claude-sonnet-5"] == PriceRate(input: 2, cached: 0.2, write: 2.5, write1h: 4, output: 10), "Sonnet単価を読めない")
        try check(rates["claude-haiku-4-5"] == PriceRate(input: 1, cached: 0.1, write: 1.25, write1h: 2, output: 5), "小数バージョンIDを変換できない")
    }

    static func pricingDiscovery() throws {
        let old = PriceRate(input: 5, cached: 0.5, write: 6.25, write1h: 10, output: 25)
        let markdown = """
        | Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok | $50 / MTok |
        | Claude Opus 5 | $6 / MTok | $7.50 / MTok | $12 / MTok | $0.60 / MTok | $30 / MTok |
        | Claude Missing 5 | $10 / MTok | - | - | $1 / MTok | $50 / MTok |
        """
        let current = ["claude-opus-5": old, "claude-legacy-1": old]
        let parsed = OfficialPricingUpdater.parseAnthropic(markdown)
        let next = OfficialPricingUpdater.mergePrices(current: current, parsed: parsed)
        try check(next["claude-fable-5-1"]?.cached == 0.25, "新モデルが追加されない")
        try check(next["claude-opus-5"]?.input == 6, "既存単価が更新されない")
        try check(next["claude-legacy-1"] == old, "欠落モデルを削除した")
        try check(next["claude-missing-5"] == nil, "不完全な単価を追加した")
        try check(OfficialPricingUpdater.mergePrices(current: next, parsed: parsed) == next, "再確認で単価が変わった")
    }

    static func pricingPrecedence() throws {
        try temporary { root in
            let state = root.appendingPathComponent("state")
            let sessions = root.appendingPathComponent("codex/sessions")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let base = root.appendingPathComponent("base-pricing.json")
            let rate: (Double) -> [String: Any] = { value in
                ["input": value, "cached": value, "write": value, "output": value]
            }
            try json(["verified": "2026-01-01", "models": ["gpt-test": rate(1)]], to: base)
            try json(["verified": "2026-02-01", "models": ["gpt-test": rate(2)]], to: state.appendingPathComponent("official-pricing.json"))
            try json(["models": ["gpt-test": rate(3)]], to: state.appendingPathComponent("pricing.json"))
            let context = try JSONSerialization.data(withJSONObject: ["type": "turn_context", "payload": ["model": "gpt-test"]]) + Data([0x0A])
            let usageLine = try JSONSerialization.data(withJSONObject: event(["input_tokens": 1_000_000, "output_tokens": 0, "cached_input_tokens": 0])) + Data([0x0A])
            try (context + usageLine).write(to: sessions.appendingPathComponent("pricing.jsonl"))
            let collector = UsageCollector(stateDirectory: state, codexHome: root.appendingPathComponent("codex"),
                                           claudeHome: root.appendingPathComponent("claude"), pricingURL: base)
            let snapshot = try collector.collect(live: false)
            try close(snapshot.sessions.first?.cost, 3, "ユーザー単価が最優先にならない")
            try check(snapshot.pricingDate == "2026-02-01", "自動単価の確認日を表示しない")
        }
    }

    static func json(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
