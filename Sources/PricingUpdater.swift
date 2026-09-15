import Foundation

struct PricingDocument: Codable, Equatable {
    var verified: String?
    var basis: String?
    var sources: [String]?
    var models: [String: PriceRate]
}

struct PricingCheckStatus: Codable, Equatable {
    var lastAttempt: Double = 0
    var lastSuccess: Double = 0
    var message: String = "未確認"
}

enum PricingCheckOutcome: Equatable {
    case skipped
    case unchanged(PricingCheckStatus)
    case updated(PricingCheckStatus, Int)
    case failed(PricingCheckStatus)
}

enum PricingUpdateError: LocalizedError {
    case invalidResponse(String)
    case missingModels([String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let provider): return provider + "の公式料金表を取得できませんでした"
        case .missingModels(let models): return "公式料金表で確認できないモデルがあります: " + models.joined(separator: ", ")
        }
    }
}

final class OfficialPricingUpdater: @unchecked Sendable {
    static let openAIURL = URL(string: "https://developers.openai.com/api/docs/pricing.md")!
    static let anthropicURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
    static let successInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60

    let stateDirectory: URL
    let bundledPricingURL: URL
    private let session: URLSession
    private let fileManager = FileManager.default

    init(
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageBar"),
        bundledPricingURL: URL? = nil,
        session: URLSession = .shared
    ) {
        self.stateDirectory = stateDirectory
        self.bundledPricingURL = bundledPricingURL ?? Bundle.main.url(forResource: "pricing", withExtension: "json") ??
            URL(fileURLWithPath: "Sources/pricing.json")
        self.session = session
    }

    var statusURL: URL { stateDirectory.appendingPathComponent("pricing-check.json") }
    var officialPricingURL: URL { stateDirectory.appendingPathComponent("official-pricing.json") }

    func readStatus() -> PricingCheckStatus {
        read(PricingCheckStatus.self, from: statusURL) ?? PricingCheckStatus()
    }

    func isDue(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let status = readStatus()
        if status.lastSuccess > 0 && now - status.lastSuccess < Self.successInterval { return false }
        return status.lastAttempt == 0 || now - status.lastAttempt >= Self.retryInterval
    }

    func check(force: Bool = false, now: Date = Date()) async -> PricingCheckOutcome {
        let timestamp = now.timeIntervalSince1970
        if !force && !isDue(now: timestamp) { return .skipped }

        var status = readStatus()
        status.lastAttempt = timestamp
        do {
            async let openAIText = download(Self.openAIURL, provider: "OpenAI")
            async let anthropicText = download(Self.anthropicURL, provider: "Anthropic")
            let (openAI, anthropic) = try await (openAIText, anthropicText)
            guard let bundled = read(PricingDocument.self, from: bundledPricingURL) else {
                throw PricingUpdateError.invalidResponse("同梱単価")
            }

            var current = bundled
            if let saved = read(PricingDocument.self, from: officialPricingURL) {
                current.models.merge(saved.models) { _, new in new }
                current.verified = saved.verified ?? current.verified
            }

            let parsedOpenAI = Self.parseOpenAI(openAI)
            let parsedAnthropic = Self.parseAnthropic(anthropic)
            var missing: [String] = []
            var nextModels = current.models
            var changed = 0
            for (model, oldRate) in current.models.sorted(by: { $0.key < $1.key }) {
                let parsed = model.hasPrefix("claude-") ? parsedAnthropic[model] : parsedOpenAI[model]
                guard let newRate = parsed else { missing.append(model); continue }
                if newRate != oldRate { nextModels[model] = newRate; changed += 1 }
            }
            if !missing.isEmpty { throw PricingUpdateError.missingModels(missing) }

            status.lastSuccess = timestamp
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            let date = formatter.string(from: now)
            if changed > 0 {
                let document = PricingDocument(
                    verified: date,
                    basis: bundled.basis,
                    sources: [
                        "https://developers.openai.com/api/docs/pricing",
                        "https://platform.claude.com/docs/en/about-claude/pricing"
                    ],
                    models: nextModels
                )
                try write(document, to: officialPricingURL)
                status.message = "参考単価を更新しました（\(changed)モデル）"
                try write(status, to: statusURL)
                return .updated(status, changed)
            }
            status.message = "公式単価に変更はありません"
            try write(status, to: statusURL)
            return .unchanged(status)
        } catch {
            status.message = error.localizedDescription
            try? write(status, to: statusURL)
            return .failed(status)
        }
    }

    static func parseOpenAI(_ markdown: String) -> [String: PriceRate] {
        var rates: [String: PriceRate] = [:]
        for line in markdown.split(separator: "\n").map(String.init) where line.hasPrefix("|") {
            let cells = tableCells(line)
            if cells.count >= 9, cells[0].hasPrefix("gpt-") || cells[0].hasPrefix("o") {
                guard rates[cells[0]] == nil,
                      let input = dollars(cells[1]), let cached = dollars(cells[2]),
                      let write = dollars(cells[3]), let output = dollars(cells[4]) else { continue }
                rates[cells[0]] = PriceRate(input: input, cached: cached, write: write, write1h: nil, output: output)
            } else if cells.count >= 5, cells[0] == "Codex", cells[1].hasPrefix("gpt-") {
                let model = cells[1]
                guard rates[model] == nil,
                      let input = dollars(cells[2]), let cached = dollars(cells[3]),
                      let output = dollars(cells[4]) else { continue }
                rates[model] = PriceRate(input: input, cached: cached, write: input, write1h: nil, output: output)
            }
        }
        return rates
    }

    static func parseAnthropic(_ markdown: String) -> [String: PriceRate] {
        var rates: [String: PriceRate] = [:]
        for line in markdown.split(separator: "\n").map(String.init) where line.hasPrefix("|") {
            let cells = tableCells(line)
            guard cells.count >= 6, cells[0].hasPrefix("Claude "),
                  let model = claudeModelID(cells[0]), rates[model] == nil,
                  let input = dollars(cells[1]), let write = dollars(cells[2]),
                  let write1h = dollars(cells[3]), let cached = dollars(cells[4]),
                  let output = dollars(cells[5]) else { continue }
            rates[model] = PriceRate(input: input, cached: cached, write: write, write1h: write1h, output: output)
        }
        return rates
    }

    private static func tableCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func dollars(_ text: String) -> Double? {
        guard text != "-", text.lowercased() != "free" else { return nil }
        let allowed = text.drop(while: { $0 != "$" }).dropFirst().prefix { $0.isNumber || $0 == "." }
        return Double(allowed)
    }

    private static func claudeModelID(_ display: String) -> String? {
        let name = display.split(separator: "(", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? display
        let parts = name.split(separator: " ")
        guard parts.count >= 3, parts[0] == "Claude" else { return nil }
        let family = parts[1].lowercased()
        let version = parts[2].replacingOccurrences(of: ".", with: "-")
        return "claude-\(family)-\(version)"
    }

    private func download(_ url: URL, provider: String) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("TokenMeter/1.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PricingUpdateError.invalidResponse(provider)
        }
        return text
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let temporary = stateDirectory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: url) }
    }
}
