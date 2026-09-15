import Foundation

struct ProviderComponent: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: String
}

struct ProviderIncident: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: String
    var impact: String
    var updated: Double
    var message: String
    var url: String
}

struct ProviderStatus: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var indicator: String
    var description: String
    var updated: Double
    var url: String
    var components: [ProviderComponent]
    var incidents: [ProviderIncident]

    var hasIssue: Bool {
        indicator != "none" || !incidents.isEmpty || components.contains { $0.status != "operational" }
    }

    var relevantComponents: [ProviderComponent] {
        let preferred = components.filter { component in
            if component.status != "operational" { return true }
            let name = component.name.lowercased()
            if id == "openai" {
                return name.contains("codex") || name.contains("chatgpt") || name == "responses" || name == "login"
            }
            return name == "claude.ai" || name.contains("claude code") || name.contains("claude api") || name.contains("console")
        }
        return Array((preferred.isEmpty ? components : preferred).prefix(10))
    }
}

enum ProviderStatusError: LocalizedError {
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "ステータス応答を読み取れませんでした"
        case .http(let code): return "ステータス取得に失敗しました（HTTP \(code)）"
        }
    }
}

final class ProviderStatusService: @unchecked Sendable {
    private struct Endpoint {
        let id: String
        let name: String
        let baseURL: String
    }

    private struct Summary: Decodable {
        struct Page: Decodable { var updatedAt: String?; var url: String? }
        struct State: Decodable { var indicator: String; var description: String }
        struct Component: Decodable { var id: String; var name: String; var status: String }
        var page: Page
        var status: State
        var components: [Component]
    }

    private struct IncidentList: Decodable {
        struct Incident: Decodable {
            struct Update: Decodable {
                var body: String
                var status: String
                var updatedAt: String?
                var createdAt: String?
            }
            var id: String
            var name: String
            var status: String
            var impact: String?
            var updatedAt: String?
            var resolvedAt: String?
            var incidentUpdates: [Update]?
        }
        var incidents: [Incident]
    }

    private let session: URLSession
    private let endpoints = [
        Endpoint(id: "openai", name: "OpenAI", baseURL: "https://status.openai.com"),
        Endpoint(id: "anthropic", name: "Anthropic", baseURL: "https://status.anthropic.com")
    ]

    init(session: URLSession = .shared) { self.session = session }

    func fetch() async -> ([ProviderStatus], [String]) {
        await withTaskGroup(of: (ProviderStatus?, String?).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do { return (try await self.fetch(endpoint), nil) }
                    catch { return (nil, endpoint.name + "：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)) }
                }
            }
            var providers: [ProviderStatus] = []
            var errors: [String] = []
            for await result in group {
                if let provider = result.0 { providers.append(provider) }
                if let error = result.1 { errors.append(error) }
            }
            return (providers.sorted { $0.id > $1.id }, errors.sorted())
        }
    }

    func parse(summaryData: Data, incidentsData: Data?, providerID: String, providerName: String, baseURL: String) throws -> ProviderStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(Summary.self, from: summaryData)
        let incidentList = incidentsData.flatMap { try? decoder.decode(IncidentList.self, from: $0) }
        let incidents = (incidentList?.incidents ?? []).filter { $0.status != "resolved" && $0.resolvedAt == nil }.map { incident in
            let latest = incident.incidentUpdates?.first
            return ProviderIncident(
                id: incident.id, name: incident.name, status: incident.status,
                impact: incident.impact ?? "none",
                updated: Self.timestamp(incident.updatedAt ?? latest?.updatedAt ?? latest?.createdAt),
                message: latest?.body ?? "", url: baseURL + "/incidents/" + incident.id
            )
        }.sorted { $0.updated > $1.updated }
        return ProviderStatus(
            id: providerID, name: providerName, indicator: summary.status.indicator,
            description: summary.status.description, updated: Self.timestamp(summary.page.updatedAt),
            url: summary.page.url ?? baseURL,
            components: summary.components.map { ProviderComponent(id: $0.id, name: $0.name, status: $0.status) },
            incidents: incidents
        )
    }

    private func fetch(_ endpoint: Endpoint) async throws -> ProviderStatus {
        async let summaryData = data(endpoint.baseURL + "/api/v2/summary.json")
        async let incidentsData = optionalData(endpoint.baseURL + "/api/v2/incidents.json")
        return try await parse(summaryData: summaryData, incidentsData: incidentsData,
                               providerID: endpoint.id, providerName: endpoint.name, baseURL: endpoint.baseURL)
    }

    private func data(_ value: String) async throws -> Data {
        guard let url = URL(string: value) else { throw ProviderStatusError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("TokenMeter/1.3", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderStatusError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProviderStatusError.http(http.statusCode) }
        return data
    }

    private func optionalData(_ value: String) async -> Data? { try? await data(value) }

    private static func timestamp(_ value: String?) -> Double {
        guard let value else { return 0 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date.timeIntervalSince1970 }
        return ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? 0
    }
}
