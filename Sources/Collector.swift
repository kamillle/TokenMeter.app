import Foundation
import Darwin

struct LimitWindow: Codable, Identifiable, Equatable {
    var label: String
    var remaining: Double
    var resetsAt: Double
    var observed: Double
    var expired: Bool
    var bucket: String
    var id: String { bucket + label }
}

struct Quota: Codable, Equatable {
    var windows: [LimitWindow]
    var observed: Double
    var source: String
    var error: String
    var stale: Bool
    var detail: String
    var accountID: String? = nil
    var bridgeInstalled: Bool?
    var linked: Bool?

    static var empty: Quota {
        Quota(windows: [], observed: 0, source: "読み込み中", error: "", stale: true, detail: "")
    }

    var limiting: LimitWindow? {
        let primary = windows.filter { $0.bucket == "codex" || $0.bucket == "claude" }
        return (primary.isEmpty ? windows : primary)
            .filter { !$0.expired }
            .min { $0.remaining < $1.remaining }
    }
}

struct ModelUsage: Codable, Identifiable, Equatable {
    var model: String
    var input: Int64
    var output: Int64
    var cached: Int64
    var write: Int64
    var cost: Double?
    var id: String { model }
}

struct Session: Codable, Identifiable, Equatable {
    var id: String
    var provider: String
    var title: String
    var cwd: String
    var updated: Double
    var input: Int64
    var output: Int64
    var cached: Int64
    var write: Int64
    var cost: Double?
    var knownCost: Double
    var unknownModels: [String]
    var models: [ModelUsage]
}

struct Snapshot: Codable, Equatable {
    var updated: Double
    var sessions: [Session]
    var codex: Quota
    var claude: Quota
    var errors: [String]
    var pricingDate: String
    var scope: String
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(any value: Any) {
        if value is NSNull { self = .null }
        else if let value = value as? [String: Any] {
            self = .object(value.mapValues(JSONValue.init(any:)))
        } else if let value = value as? [Any] {
            self = .array(value.map(JSONValue.init(any:)))
        } else if let value = value as? String { self = .string(value) }
        else if let value = value as? NSNumber {
            if String(cString: value.objCType) == "c" { self = .bool(value.boolValue) }
            else { self = .number(value.doubleValue) }
        } else { self = .null }
    }

    var any: Any {
        switch self {
        case .object(let value): return value.mapValues(\.any)
        case .array(let value): return value.map(\.any)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }

    var object: [String: Any]? { any as? [String: Any] }
}

struct TokenVector: Codable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cached: Int64 = 0
    var write: Int64 = 0
    var write1h: Int64 = 0

    mutating func add(_ other: TokenVector) {
        input += other.input
        output += other.output
        cached += other.cached
        write += other.write
        write1h += other.write1h
    }

    func maximum(_ other: TokenVector) -> TokenVector {
        TokenVector(input: max(input, other.input), output: max(output, other.output),
                    cached: max(cached, other.cached), write: max(write, other.write),
                    write1h: max(write1h, other.write1h))
    }

    func subtractingFloorZero(_ previous: TokenVector) -> TokenVector {
        TokenVector(input: max(0, input - previous.input), output: max(0, output - previous.output),
                    cached: max(0, cached - previous.cached), write: max(0, write - previous.write),
                    write1h: max(0, write1h - previous.write1h))
    }
}

struct RequestRecord: Codable, Equatable {
    var model: String
    var usage: TokenVector
}

struct RateSample: Codable, Equatable {
    var raw: JSONValue
    var observed: Double
}

struct FileState: Codable, Equatable {
    var provider: String
    var id: String
    var title: String
    var cwd: String
    var model: String
    var updated: Double
    var offset: Int64
    var inode: UInt64
    var mtime: Int64
    var size: Int64
    var requests: [String: RequestRecord]
    var legacy: [String: TokenVector]
    var previous: TokenVector
    var rate: RateSample?
    var malformed: Int
    var forked: Bool?
    var internalSession: Bool?
    var foreignRecords: Bool?

    enum CodingKeys: String, CodingKey {
        case provider, id, title, cwd, model, updated, offset, inode, mtime, size
        case requests, legacy, previous, rate, malformed, forked, foreignRecords
        case internalSession = "internal"
    }
}

private struct SessionCache: Codable {
    var version: Int
    var files: [String: FileState]
}

struct PriceRate: Codable, Equatable {
    var input: Double
    var cached: Double
    var write: Double
    var write1h: Double?
    var output: Double
}

private struct PricingFile: Codable {
    var verified: String?
    var models: [String: PriceRate]
}

private struct CodexQuotaCache: Codable {
    var attempted: Double?
    var observed: Double?
    var raw: JSONValue?
    var accountID: String?
    var accountIDChecked: Bool?
    var linked: Bool?
    var error: String?
}

enum CollectorError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

final class UsageCollector: @unchecked Sendable {
    static let cacheVersion = 6

    let stateDirectory: URL
    let codexHome: URL
    let claudeHome: URL
    let pricingURL: URL
    private let fileManager = FileManager.default

    init(
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageBar"),
        codexHome: URL? = nil,
        claudeHome: URL? = nil,
        pricingURL: URL? = nil
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.stateDirectory = stateDirectory
        self.codexHome = codexHome ?? URL(fileURLWithPath: environment["CODEX_HOME"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        self.claudeHome = claudeHome ?? URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
        self.pricingURL = pricingURL ?? Bundle.main.url(forResource: "pricing", withExtension: "json") ??
            URL(fileURLWithPath: "Sources/pricing.json")
    }

    func newState(for path: URL, provider: String) -> FileState {
        FileState(provider: provider, id: path.deletingPathExtension().lastPathComponent,
                  title: "", cwd: "", model: "unknown", updated: 0, offset: 0,
                  inode: 0, mtime: 0, size: 0, requests: [:], legacy: [:],
                  previous: TokenVector(), rate: nil, malformed: 0,
                  forked: nil, internalSession: nil, foreignRecords: nil)
    }

    func collect(live: Bool = true, force: Bool = false) throws -> Snapshot {
        try ensurePrivateDirectory(stateDirectory)
        let cacheURL = stateDirectory.appendingPathComponent("sessions-cache.json")
        let cache = readCodable(SessionCache.self, from: cacheURL)
        // Version 5 is the final Python cache and has the same persisted fields.
        // Reuse it once so migration does not reread multi-gigabyte log histories.
        let previous = [5, Self.cacheVersion].contains(cache?.version ?? -1) ? cache?.files ?? [:] : [:]
        var files: [String: FileState] = [:]
        var errors = Set<String>()
        let cutoff = Date().timeIntervalSince1970 - 30 * 86_400

        for (provider, roots) in [("codex", [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]),
                                  ("claude", [claudeHome.appendingPathComponent("projects")])] {
            for root in roots where fileManager.fileExists(atPath: root.path) {
                guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsPackageDescendants]) else { continue }
                for case let path as URL in enumerator where path.pathExtension == "jsonl" {
                    do {
                        let values = try path.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                        guard values.isRegularFile != false, (values.contentModificationDate?.timeIntervalSince1970 ?? 0) >= cutoff else { continue }
                        var state = try scanFile(path, provider: provider, previous: previous[path.path])
                        if provider == "claude" && path.pathComponents.contains("subagents") {
                            state.id = path.deletingPathExtension().lastPathComponent
                            if state.title.isEmpty { state.title = "Subagent · " + String(state.id.suffix(8)) }
                        }
                        files[path.path] = state
                    } catch {
                        errors.insert(provider + ": 読み取れないログがあります")
                    }
                }
            }
        }

        try atomicWrite(SessionCache(version: Self.cacheVersion, files: files), to: cacheURL)
        let bundledPricing = readCodable(PricingFile.self, from: pricingURL)
        var prices = bundledPricing?.models ?? [:]
        let officialPricing = readCodable(PricingFile.self, from: stateDirectory.appendingPathComponent("official-pricing.json"))
        if let official = officialPricing?.models {
            prices.merge(official) { _, new in new }
        }
        if let overrides = readCodable(PricingFile.self, from: stateDirectory.appendingPathComponent("pricing.json"))?.models {
            prices.merge(overrides) { _, new in new }
        }
        let titles = readCodexTitles()
        let states = Array(files.values)
        let now = Date().timeIntervalSince1970
        return Snapshot(updated: now, sessions: summarize(states, prices: prices, titles: titles),
                        codex: codexQuota(states: states, live: live, force: force),
                        claude: claudeQuota(), errors: errors.sorted(),
                        pricingDate: officialPricing?.verified ?? bundledPricing?.verified ?? "",
                        scope: "このMacの直近30日以内に更新されたセッション · 数値は各セッションの累計")
    }

    func consume(_ record: [String: Any], state: inout FileState) {
        let kind = string(record["type"])
        let payload = object(record["payload"]) ?? [:]
        let observed = timestamp(record["timestamp"])
        if state.provider == "codex" {
            switch kind {
            case "session_meta":
                state.id = string(payload["id"]) ?? state.id
                state.cwd = string(payload["cwd"]) ?? ""
                state.forked = !(string(payload["forked_from_id"]) ?? "").isEmpty
                let source = object(payload["source"])
                let subagent = object(source?["subagent"])
                state.internalSession = string(subagent?["other"]) == "guardian"
            case "turn_context":
                state.model = modelName(string(payload["model"]))
            case "token_usage_record":
                if (string(payload["thread_id"]) ?? state.id) != state.id {
                    state.foreignRecords = true
                    return
                }
                guard let usage = object(payload["usage"]) else { return }
                let requestID = string(payload["response_id"]) ?? string(record["ordinal"]) ?? string(record["timestamp"]) ?? "unknown"
                state.requests[requestID] = RequestRecord(model: state.model, usage: vector(usage, provider: state.provider))
                state.updated = max(state.updated, observed)
            case "event_msg" where string(payload["type"]) == "token_count":
                if let rate = object(payload["rate_limits"]) {
                    state.rate = RateSample(raw: JSONValue(any: rate), observed: observed)
                }
                guard let info = object(payload["info"]), let usage = object(info["total_token_usage"]) else { return }
                let current = vector(usage, provider: state.provider)
                if current.input < state.previous.input || current.output < state.previous.output {
                    state.previous = TokenVector()
                }
                let delta = current.subtractingFloorZero(state.previous)
                state.legacy[state.model, default: TokenVector()].add(delta)
                state.previous = current
                state.updated = max(state.updated, observed)
            default: break
            }
        } else {
            if kind == "custom-title" || kind == "ai-title" {
                state.title = string(record["customTitle"]) ?? string(record["aiTitle"]) ?? state.title
            }
            guard kind == "assistant", let message = object(record["message"]),
                  let usage = object(message["usage"]), string(message["model"]) != "<synthetic>" else { return }
            state.id = string(record["sessionId"]) ?? state.id
            state.cwd = string(record["cwd"]) ?? state.cwd
            let model = modelName(string(message["model"]))
            let requestID = (string(message["id"]) ?? string(record["uuid"]) ?? "nil") + ":" + (string(record["requestId"]) ?? "")
            var value = vector(usage, provider: state.provider)
            if let old = state.requests[requestID] { value = value.maximum(old.usage) }
            state.requests[requestID] = RequestRecord(model: model, usage: value)
            state.updated = max(state.updated, observed)
        }
    }

    func scanFile(_ path: URL, provider: String, previous: FileState? = nil) throws -> FileState {
        let attributes = try fileManager.attributesOfItem(atPath: path.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000_000_000)
        var state = previous ?? newState(for: path, provider: provider)
        // Python's stat nanoseconds and Foundation's Date can differ by a few
        // hundred nanoseconds for the same file. This tolerance is only enough
        // to bridge that representation gap, not a real filesystem update.
        let mtimeMatches = abs(mtime - state.mtime) <= 1_000
        if state.inode != inode || size < state.offset || (size == state.size && !mtimeMatches) {
            state = newState(for: path, provider: provider)
        }
        if size == state.size && mtimeMatches {
            state.mtime = mtime
            return state
        }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, state.offset)))
        let data = try handle.readToEnd() ?? Data()
        let baseOffset = state.offset
        let needles = provider == "codex"
            ? ["\"session_meta\"", "\"turn_context\"", "\"token_usage_record\"", "\"token_count\""]
            : ["\"assistant\"", "\"custom-title\"", "\"ai-title\""]
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<newline]
            if let text = String(data: line, encoding: .utf8), needles.contains(where: text.contains) {
                do {
                    guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw CollectorError.message("invalid record") }
                    consume(record, state: &state)
                } catch {
                    state.malformed += 1
                }
            }
            start = data.index(after: newline)
            state.offset = baseOffset + Int64(start - data.startIndex)
        }
        state.inode = inode
        state.size = size
        state.mtime = mtime
        return state
    }

    func summarize(_ states: [FileState], prices: [String: PriceRate], titles: [String: String] = [:]) -> [Session] {
        struct Group {
            var id: String
            var provider: String
            var title = ""
            var cwd = ""
            var updated = 0.0
            var requests: [String: RequestRecord] = [:]
            var legacy: [String: TokenVector] = [:]
        }
        var groups: [String: Group] = [:]
        for state in states where state.internalSession != true {
            let key = state.provider + ":" + state.id
            var group = groups[key] ?? Group(id: state.id, provider: state.provider)
            if !state.title.isEmpty { group.title = state.title }
            if !state.cwd.isEmpty { group.cwd = state.cwd }
            group.updated = max(group.updated, state.updated)
            for (requestID, record) in state.requests {
                if let old = group.requests[requestID] {
                    group.requests[requestID] = RequestRecord(model: record.model, usage: record.usage.maximum(old.usage))
                } else { group.requests[requestID] = record }
            }
            if state.foreignRecords != true && state.forked != true {
                for (model, usage) in state.legacy {
                    group.legacy[model] = group.legacy[model]?.maximum(usage) ?? usage
                }
            }
            groups[key] = group
        }

        var rows: [Session] = []
        for group in groups.values {
            var models: [String: TokenVector] = [:]
            if !group.requests.isEmpty {
                for record in group.requests.values { models[record.model, default: TokenVector()].add(record.usage) }
                if group.provider == "codex" {
                    for (model, usage) in group.legacy { models[model] = models[model]?.maximum(usage) ?? usage }
                }
            } else { models = group.legacy }

            var total = TokenVector()
            var breakdown: [ModelUsage] = []
            var unknown: [String] = []
            var estimated = 0.0
            for model in models.keys.sorted() {
                guard let usage = models[model] else { continue }
                total.add(usage)
                let cost = cost(usage, rate: rate(for: model, prices: prices))
                if cost == nil && (usage.input > 0 || usage.output > 0) { unknown.append(model) }
                estimated += cost ?? 0
                breakdown.append(ModelUsage(model: model, input: usage.input, output: usage.output,
                                            cached: usage.cached, write: usage.write, cost: cost))
            }
            guard total.input > 0 || total.output > 0 else { continue }
            let fallbackTitle = URL(fileURLWithPath: group.cwd).lastPathComponent
            let title = titles[group.id].flatMap { $0.isEmpty ? nil : $0 } ??
                (!group.title.isEmpty ? group.title : (!fallbackTitle.isEmpty ? fallbackTitle : "Session"))
            rows.append(Session(id: group.id, provider: group.provider, title: title, cwd: group.cwd,
                                updated: group.updated, input: total.input, output: total.output,
                                cached: total.cached, write: total.write,
                                cost: unknown.isEmpty ? estimated : nil, knownCost: estimated,
                                unknownModels: unknown, models: breakdown))
        }
        return rows.sorted { $0.updated > $1.updated }
    }

    func normalizeWindow(_ window: [String: Any], label initialLabel: String, observed: Double, snake: Bool = false, now: Double = Date().timeIntervalSince1970) -> LimitWindow? {
        guard let used = double(window[snake ? "used_percent" : "usedPercent"]) else { return nil }
        var label = initialLabel
        if let duration = double(window[snake ? "window_minutes" : "windowDurationMins"]), duration != 0 {
            if duration >= 1_440 { label = String(Int(duration / 1_440)) + "日" }
            else {
                let hours = duration / 60
                label = hours.rounded() == hours ? String(Int(hours)) + "時間" : String(format: "%.1f時間", hours)
            }
        }
        let reset = timestamp(window[snake ? "resets_at" : "resetsAt"])
        return LimitWindow(label: label, remaining: max(0, min(100, 100 - used)), resetsAt: reset,
                           observed: observed, expired: reset > 0 && reset <= now, bucket: "")
    }

    func codexWindows(_ result: [String: Any], observed: Double, snake: Bool = false, now: Double = Date().timeIntervalSince1970) -> [LimitWindow] {
        var buckets = object(result["rateLimitsByLimitId"])
        if buckets == nil || buckets?.isEmpty == true {
            let raw = snake ? result : object(result["rateLimits"]) ?? [:]
            let key = string(raw[snake ? "limit_id" : "limitId"]) ?? "codex"
            buckets = [key: raw]
        }
        let keys = (buckets?.keys ?? Dictionary<String, Any>().keys).sorted { left, right in
            if left == "codex" { return true }
            if right == "codex" { return false }
            return left < right
        }
        var windows: [LimitWindow] = []
        for key in keys {
            guard let bucket = object(buckets?[key]) else { continue }
            for (field, baseLabel) in [("primary", "主な利用枠"), ("secondary", "追加の利用枠")] {
                guard let rawWindow = object(bucket[field]), var window = normalizeWindow(rawWindow, label: baseLabel, observed: observed, snake: snake, now: now) else { continue }
                window.bucket = key
                if key != "codex" { window.label = (string(bucket["limitName"]) ?? key) + " · " + window.label }
                windows.append(window)
            }
        }
        return windows
    }

    func codexAccountID(_ result: [String: Any]) -> String? {
        guard let account = object(result["account"]),
              let email = string(account["email"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return email
    }

    func cachedCodexAccountID() -> String? {
        readCodable(CodexQuotaCache.self, from: stateDirectory.appendingPathComponent("codex-quota.json"))?.accountID
    }

    func codexQuota(states: [FileState], live: Bool, force: Bool) -> Quota {
        let now = Date().timeIntervalSince1970
        let path = stateDirectory.appendingPathComponent("codex-quota.json")
        var cache = readCodable(CodexQuotaCache.self, from: path) ?? CodexQuotaCache()
        let needsAccountIDBackfill = cache.raw != nil && cache.accountIDChecked != true
        if live && (force || needsAccountIDBackfill || now - (cache.attempted ?? 0) >= 300) {
            do {
                let result = try codexRPC()
                cache = CodexQuotaCache(attempted: now, observed: now, raw: JSONValue(any: result.rateLimits),
                                        accountID: result.accountID ?? cache.accountID, accountIDChecked: true,
                                        linked: true, error: "")
            } catch {
                cache.attempted = now
                cache.accountIDChecked = true
                cache.error = (error as? LocalizedError)?.errorDescription ?? "Codex CLIとの通信に失敗しました"
            }
            try? atomicWrite(cache, to: path)
        }
        let sample = states.compactMap(\.rate).max { $0.observed < $1.observed }
        let cacheObserved = cache.observed ?? 0
        let observed: Double
        let windows: [LimitWindow]
        let source: String
        let accountID: String?
        if let raw = cache.raw?.object, sample == nil || cacheObserved >= (sample?.observed ?? 0) {
            observed = cacheObserved
            windows = codexWindows(raw, observed: observed)
            source = "Codexアカウント"
            accountID = cache.accountID
        } else if let sample, let raw = sample.raw.object {
            observed = sample.observed
            windows = codexWindows(raw, observed: observed, snake: true)
            source = "セッションログ"
            accountID = cache.accountID
        } else {
            observed = 0
            windows = []
            source = "未取得"
            accountID = cache.accountID
        }
        let linked = (cache.linked ?? (cache.raw != nil)) || sample != nil
        return Quota(windows: windows, observed: observed, source: source, error: cache.error ?? "",
                     stale: now - observed > 600, detail: "利用枠はアカウント全体で共有されます",
                     accountID: accountID, bridgeInstalled: nil, linked: linked)
    }

    func claudeQuota(now: Double = Date().timeIntervalSince1970) -> Quota {
        let data = readObject(from: stateDirectory.appendingPathComponent("claude-status.json")) ?? [:]
        let observed = double(data["observed"]) ?? 0
        let limits = object(data["rate_limits"]) ?? [:]
        var windows: [LimitWindow] = []
        for (key, label) in [("five_hour", "5時間"), ("seven_day", "7日"), ("spend_limit", "支出枠")] {
            guard let raw = object(limits[key]) else { continue }
            let normalized: [String: Any] = ["usedPercent": raw["used_percentage"] ?? NSNull(), "resetsAt": raw["resets_at"] ?? NSNull()]
            if var window = normalizeWindow(normalized, label: label, observed: observed, now: now) {
                window.bucket = "claude"
                windows.append(window)
            }
        }
        let config = readObject(from: stateDirectory.appendingPathComponent("bridge-config.json")) ?? [:]
        let installed = bool(config["installed"]) ?? false
        let detail: String
        if windows.isEmpty {
            detail = installed
                ? "連携済み・Claude Codeからの利用枠通知待ち。Pro/Maxの応答後に更新されます。接続先によっては通知されません"
                : "「Claude連携」で使用率の通知を受け取れます。セッションのトークン集計は連携前でも利用できます"
        } else { detail = "Claude Codeからの最終通知。会話の応答時に更新されます" }
        return Quota(windows: windows, observed: observed, source: observed > 0 ? "Claude Code通知" : "未取得",
                     error: "", stale: now - observed > 600, detail: detail,
                     bridgeInstalled: installed, linked: installed && !windows.isEmpty)
    }

    private func vector(_ usage: [String: Any], provider: String) -> TokenVector {
        if provider == "codex" {
            let total = number(usage["input_tokens"])
            let cached = min(total, number(usage["cached_input_tokens"]))
            let write = min(total - cached, number(usage["cache_write_input_tokens"]))
            return TokenVector(input: total, output: number(usage["output_tokens"]), cached: cached, write: write)
        }
        let cached = number(usage["cache_read_input_tokens"])
        let write = number(usage["cache_creation_input_tokens"])
        let creation = object(usage["cache_creation"]) ?? [:]
        let oneHour = min(write, number(creation["ephemeral_1h_input_tokens"]))
        return TokenVector(input: number(usage["input_tokens"]) + cached + write,
                           output: number(usage["output_tokens"]), cached: cached,
                           write: write, write1h: oneHour)
    }

    private func modelName(_ raw: String?) -> String {
        let raw = raw ?? "unknown"
        guard let range = raw.range(of: "claude-") else { return raw }
        return String(raw[range.lowerBound...])
    }

    private func rate(for model: String, prices: [String: PriceRate]) -> PriceRate? {
        if let exact = prices[model] { return exact }
        guard model.count > 9 else { return nil }
        let suffix = model.suffix(9)
        if suffix.first == "-" && suffix.dropFirst().allSatisfy(\.isNumber) {
            return prices[String(model.dropLast(9))]
        }
        return nil
    }

    private func cost(_ usage: TokenVector, rate: PriceRate?) -> Double? {
        guard let rate else { return nil }
        let fresh = max(0, usage.input - usage.cached - usage.write)
        return (Double(fresh) * rate.input + Double(usage.output) * rate.output +
                Double(usage.cached) * rate.cached + Double(usage.write - usage.write1h) * rate.write +
                Double(usage.write1h) * (rate.write1h ?? rate.write)) / 1_000_000
    }

    private func readCodexTitles() -> [String: String] {
        let path = codexHome.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
        var titles: [String: String] = [:]
        text.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = self.string(record["id"]) else { return }
            titles[id] = self.string(record["thread_name"]) ?? self.string(record["title"]) ?? ""
        }
        return titles
    }

    private func codexRPC() throws -> (rateLimits: [String: Any], accountID: String?) {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["USAGEBAR_CODEX"] { candidates.append(configured) }
        let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" +
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        for directory in (environment["PATH"] ?? searchPath).split(separator: ":") {
            candidates.append(String(directory) + "/codex")
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        guard let executable = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw CollectorError.message("Codex CLIが見つかりません")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var childEnvironment = environment
        childEnvironment["PATH"] = searchPath
        process.environment = childEnvironment
        let receiver = JSONRPCReceiver()
        output.fileHandleForReading.readabilityHandler = { handle in receiver.feed(handle.availableData) }
        process.terminationHandler = { _ in receiver.finish() }
        do { try process.run() }
        catch { throw CollectorError.message("Codex CLIを起動できません") }

        func send(_ message: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: message)
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usagebar", "version": "1.0.0"], "capabilities": [:]]])
        _ = try receiver.wait(for: 1, timeout: 12)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
        try send(["id": 3, "method": "account/rateLimits/read"])
        let response = try receiver.wait(for: 3, timeout: 12)
        if response["error"] != nil { throw CollectorError.message("Codexで利用枠を取得できません。ログイン状態を確認してください") }
        let accountResponse = try? receiver.wait(for: 2, timeout: 4)
        let accountID = accountResponse.flatMap { object($0["result"]) }.flatMap(codexAccountID)
        return (object(response["result"]) ?? [:], accountID)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func readCodable<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".\(getpid()).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: temporary)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func readObject(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private func number(_ value: Any?) -> Int64 {
        max(0, (value as? NSNumber)?.int64Value ?? Int64(value as? String ?? "") ?? 0)
    }
    private func double(_ value: Any?) -> Double? {
        if value is NSNull || value == nil { return nil }
        return (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "")
    }
    private func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
    private func timestamp(_ value: Any?) -> Double {
        if let number = double(value) { return number }
        guard let text = value as? String else { return 0 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date.timeIntervalSince1970 }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: text)?.timeIntervalSince1970 ?? 0
    }
}

private final class JSONRPCReceiver: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var ended = false

    func feed(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        if data.isEmpty { ended = true; condition.broadcast(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else { continue }
            responses[id] = object
        }
        condition.broadcast()
    }

    func finish() {
        condition.lock(); ended = true; condition.broadcast(); condition.unlock()
    }

    func wait(for id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil && !ended {
            if !condition.wait(until: deadline) { break }
        }
        if let response = responses.removeValue(forKey: id) {
            if response["error"] != nil { throw CollectorError.message("Codexで利用枠を取得できません。ログイン状態を確認してください") }
            return response
        }
        if ended { throw CollectorError.message("Codex CLIを起動できません") }
        throw CollectorError.message("Codexの利用枠取得がタイムアウトしました")
    }
}
