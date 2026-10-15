import Foundation
import Darwin

struct ClaudeQuotaCache: Codable {
    // Separate from the session-log cache and the optional statusLine capture.
    var version = 1
    var attempted: Double = 0
    var observed: Double = 0
    var accountID: String?
    var windows: [LimitWindow] = []
    var error = ""
    var failures = 0
    var retryInterval: Double { min(600, 60 * pow(2, Double(min(4, max(0, failures - 1))))) }
}

enum ClaudeUsageError: LocalizedError {
    case missingCLI, exited, timeout, unsupported, unavailable, invalidResponse, accountChanged
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "Claude CLIが見つかりません。Claude Codeをインストールしてください"
        case .exited: return "Claude CLIとの通信が終了しました。Claude Codeの起動状態を確認してください"
        case .timeout: return "Claudeの利用枠取得がタイムアウトしました"
        case .unsupported: return "Claudeのget_usageを実行できません。Claude Codeのバージョンとログイン状態を確認してください"
        case .unavailable: return "Claudeの利用枠を取得できません。サブスクリプションのログイン状態を確認してください"
        case .invalidResponse: return "Claudeから有効な利用枠が返りませんでした"
        case .accountChanged: return "取得中にClaudeのアカウントが変わりました。再取得してください"
        }
    }
}

struct ClaudeUsageClient {
    var configDirectory: URL? = nil
    var executableOverride: URL? = nil
    var timeout: TimeInterval = 15
    var environment = ProcessInfo.processInfo.environment

    func fetch() throws -> [String: Any] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchPath = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:" + home.appendingPathComponent(".local/bin").path
        var candidates = executableOverride.map { [$0.path] } ?? []
        if let configured = environment["TOKENMETER_CLAUDE"] { candidates.append(configured) }
        candidates += searchPath.split(separator: ":").map { String($0) + "/claude" }
        candidates.append(home.appendingPathComponent(".claude/local/claude").path)
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ClaudeUsageError.missingCLI }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeter-ClaudeUsage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(), input = Pipe(), output = Pipe()
        let receiver = ClaudeControlReceiver()
        process.executableURL = URL(fileURLWithPath: executable)
        // No prompt/user message is sent. Only initialize and get_usage are allowed below.
        // Disable project/user hooks, plugins and MCP discovery for this read-only probe.
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--no-session-persistence", "--setting-sources", "",
                             "--settings", "{\"disableAllHooks\":true}",
                             "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        process.currentDirectoryURL = directory
        var childEnvironment = environment
        childEnvironment["PATH"] = searchPath
        if let configDirectory { childEnvironment["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        process.environment = childEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { receiver.feed($0.availableData) }
        var started = false
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if started { process.waitUntilExit() }
        }
        do { try process.run(); started = true } catch { throw ClaudeUsageError.exited }
        func send(_ id: String, _ request: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        }
        try send("initialize", ["subtype": "initialize"])
        _ = try receiver.wait(for: "initialize", timeout: timeout)
        try send("usage", ["subtype": "get_usage", "skip_behaviors": true])
        return try receiver.wait(for: "usage", timeout: timeout)
    }

    static func windows(from result: [String: Any], observed: Double) throws -> [LimitWindow] {
        guard result["rate_limits_available"] as? Bool == true else { throw ClaudeUsageError.unavailable }
        guard let limits = result["rate_limits"] as? [String: Any] else { throw ClaudeUsageError.invalidResponse }
        var windows: [LimitWindow] = []
        func append(_ raw: Any?, label: String, bucket: String) {
            guard let raw = raw as? [String: Any],
                  let used = ClaudeQuotaCapture.number(raw["utilization"]), used >= 0 else { return }
            let reset: Double
            if let value = ClaudeQuotaCapture.number(raw["resets_at"]), value > 0 { reset = value }
            else if let text = raw["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970 ?? 0
            } else { reset = 0 }
            guard !windows.contains(where: { $0.bucket == bucket && $0.label == label }) else { return }
            windows.append(LimitWindow(label: label, remaining: max(0, min(100, 100 - used)), resetsAt: reset,
                                       observed: observed, expired: reset > 0 && reset <= observed, bucket: bucket))
        }
        append(limits["five_hour"], label: "5時間", bucket: "claude")
        append(limits["seven_day"], label: "7日", bucket: "claude")
        // Model-only limits must never replace the account-wide menu-bar limit.
        for raw in limits["model_scoped"] as? [[String: Any]] ?? [] {
            guard let name = raw["display_name"] as? String, !name.isEmpty else { continue }
            append(raw, label: String(name.prefix(80)) + " · 7日", bucket: "claude-model")
        }
        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            append(limits[key], label: name + " · 7日", bucket: "claude-model")
        }
        guard windows.contains(where: { $0.bucket == "claude" }) else { throw ClaudeUsageError.invalidResponse }
        return windows
    }
}

final class ClaudeControlReceiver: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [String: [String: Any]] = [:]
    private var ended = false

    func feed(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        if data.isEmpty { ended = true; condition.broadcast(); return }
        buffer.append(data)
        // Bound malformed/unexpected output. Never retain or log session messages.
        if buffer.count > 2 * 1024 * 1024 { buffer.removeAll(); ended = true; condition.broadcast(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  value["type"] as? String == "control_response",
                  let response = value["response"] as? [String: Any],
                  let id = response["request_id"] as? String, ["initialize", "usage"].contains(id) else { continue }
            responses[id] = response
        }
        condition.broadcast()
    }

    func wait(for id: String, timeout: TimeInterval) throws -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while responses[id] == nil && !ended {
            if !condition.wait(until: deadline) { break }
        }
        guard let response = responses.removeValue(forKey: id) else {
            throw ended ? ClaudeUsageError.exited : ClaudeUsageError.timeout
        }
        guard response["subtype"] as? String == "success" else { throw ClaudeUsageError.unsupported }
        guard let result = response["response"] as? [String: Any] else { throw ClaudeUsageError.invalidResponse }
        return result
    }
}
