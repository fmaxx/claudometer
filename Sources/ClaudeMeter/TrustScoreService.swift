import Darwin
import Foundation

struct TrustScoreService: Sendable {
    private static let claudeTraceURL = URL(string: "https://claude.ai/cdn-cgi/trace")!
    private static let publicTraceURL = URL(string: "https://ip.net.coffee/cdn-cgi/trace")!
    private static let riskURL = URL(string: "https://ip.net.coffee/api/iprisk/")!
    // Net.Coffee displays zero for these country codes regardless of the API score.
    private static let restrictedRegions: Set = ["CN", "HK", "MO", "RU", "KP", "IR", "SY", "CU", "BY", "VE"]

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func claudeIP() async throws -> String {
        try await fetchIP(from: Self.claudeTraceURL)
    }

    func publicIP() async throws -> String {
        try await fetchIP(from: Self.publicTraceURL)
    }

    private func fetchIP(from url: URL) async throws -> String {
        let data = try await fetch(url, timeout: 8)
        let trace = String(decoding: data, as: UTF8.self)

        guard let ipLine = trace.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("ip=") }) else {
            throw ServiceError.invalidIP
        }

        let ip = String(ipLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET, ip, &ipv4) == 1 || inet_pton(AF_INET6, ip, &ipv6) == 1 else {
            throw ServiceError.invalidIP
        }
        return ip
    }

    func score(for ip: String) async throws -> Double {
        let data = try await fetch(Self.riskURL.appendingPathComponent(ip), timeout: 10)
        let response = try JSONDecoder().decode(RiskResponse.self, from: data)
        if let country = response.countryCode?.uppercased(), Self.restrictedRegions.contains(country) {
            return 0
        }
        guard let score = response.trustScore, (0...100).contains(score) else {
            throw ServiceError.missingScore
        }
        return score
    }

    private func fetch(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ServiceError.http(response.statusCode)
        }
        return data
    }

    private struct RiskResponse: Decodable {
        let trustScore: Double?
        let countryCode: String?

        enum CodingKeys: String, CodingKey {
            case trustScore = "trust_score"
            case countryCode
        }
    }

    private enum ServiceError: LocalizedError {
        case invalidIP
        case invalidResponse
        case missingScore
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidIP: "Сервис не вернул корректный IP."
            case .invalidResponse: "Не удалось прочитать ответ сервиса."
            case .missingScore: "Net.Coffee не вернул индекс для этого IP."
            case .http(let status): "Сервис вернул HTTP \(status)."
            }
        }
    }
}
