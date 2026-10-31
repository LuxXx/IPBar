import Foundation
import CoreLocation

struct IPInfo: Decodable, Equatable {
    let ip: String
    let hostname: String?
    let city: String?
    let region: String?
    let country: String?
    let loc: String?
    let org: String?
    let postal: String?
    let timezone: String?

    var flag: String {
        guard let country, country.count == 2 else { return "🌐" }
        let scalars = country.uppercased().unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    var countryName: String? {
        guard let country else { return nil }
        return Locale.current.localizedString(forRegionCode: country) ?? country
    }

    /// "AS8881 1&1 Versatel" -> "AS8881"
    var asn: String? {
        guard let org, let first = org.split(separator: " ").first, first.hasPrefix("AS") else { return nil }
        return String(first)
    }

    /// "AS8881 1&1 Versatel" -> "1&1 Versatel"
    var isp: String? {
        guard let org else { return nil }
        if let asn { return String(org.dropFirst(asn.count)).trimmingCharacters(in: .whitespaces) }
        return org
    }

    var coordinate: CLLocationCoordinate2D? {
        let parts = (loc ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    var formattedCoordinates: String? {
        guard let c = coordinate else { return nil }
        let lat = String(format: "%.6f° %@", abs(c.latitude), c.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.6f° %@", abs(c.longitude), c.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }
}

enum IPInfoError: LocalizedError {
    case rateLimited
    case server(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "ipinfo.io rate limit reached. Add a token in Settings."
        case .server(let message): return message
        }
    }
}

enum IPInfoClient {
    /// Returns the decoded info plus the raw response body (for logging).
    static func fetch(token: String) async throws -> (IPInfo, Data) {
        var components = URLComponents(string: "https://ipinfo.io/json")!
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { components.queryItems = [URLQueryItem(name: "token", value: token)] }

        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Fresh ephemeral session each time so a kept-alive connection from a
        // previous network (e.g. before a VPN switch) is never reused.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 { throw IPInfoError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? (json?["error"] as? String)
                ?? "HTTP \(http.statusCode)"
            throw IPInfoError.server(message)
        }
        return (try JSONDecoder().decode(IPInfo.self, from: data), data)
    }
}
