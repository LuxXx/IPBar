import CoreLocation
import Foundation

/// One line of ip-log.jsonl.
struct LogEntry {
    let date: Date
    let fields: [String: Any]

    func string(_ key: String) -> String? { fields[key] as? String }

    var ip: String { string("ip") ?? "?" }
    var vpn: Bool { fields["vpn"] as? Bool ?? false }
    var country: String? { string("country") }
    /// Where you actually were, falling back to the IP's country.
    var effectiveCountry: String? { string("real_country") ?? country }

    var isp: String? {
        guard let org = string("org") else { return nil }
        if let first = org.split(separator: " ").first, first.hasPrefix("AS") {
            return String(org.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
        }
        return org
    }

    var ipCoordinate: CLLocationCoordinate2D? { Self.coordinate(string("loc")) }

    var realLocation: DeviceLocation? {
        guard let c = Self.coordinate(string("real_loc")) else { return nil }
        return DeviceLocation(
            latitude: c.latitude, longitude: c.longitude,
            accuracy: fields["real_accuracy_m"] as? Int ?? 0,
            city: string("real_city"), region: string("real_region"), country: string("real_country")
        )
    }

    /// Whether two entries belong to the same period. A missing Wi-Fi name or real city
    /// (e.g. Location Services briefly unavailable) doesn't split a period.
    func belongsWith(_ other: LogEntry) -> Bool {
        func compatible(_ key: String) -> Bool {
            guard let a = string(key), let b = other.string(key) else { return true }
            return a == b
        }
        return ip == other.ip && vpn == other.vpn && compatible("ssid") && compatible("real_city")
    }

    var hasLocalDetails: Bool { fields["ssid"] != nil || fields["real_loc"] != nil }

    private static func coordinate(_ string: String?) -> CLLocationCoordinate2D? {
        let parts = (string ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}

/// A stretch of time with the same IP, Wi-Fi, VPN state and real city.
struct Period: Identifiable {
    let id: Int
    let start: Date
    var end: Date
    var entries: [LogEntry]

    /// The newest entry with Wi-Fi/location details, so a sparse entry doesn't hide them.
    var latest: LogEntry { entries.last(where: \.hasLocalDetails) ?? entries[entries.count - 1] }
    var duration: TimeInterval { end.timeIntervalSince(start) }

    func matches(_ query: String) -> Bool {
        let haystack = [
            latest.ip, latest.string("org"), latest.string("city"), latest.string("region"),
            latest.string("ssid"), latest.string("real_city"), latest.string("real_region"),
            latest.country.flatMap { Locale.current.localizedString(forRegionCode: $0) },
            latest.string("real_country").flatMap { Locale.current.localizedString(forRegionCode: $0) },
        ]
        return haystack.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    /// Without a log line for this long, the Mac is assumed to have been off or offline.
    static let gap: TimeInterval = 70 * 60

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var periods: [Period] = []   // newest first
    @Published private(set) var dayCountries: [Date: [String: TimeInterval]] = [:]
    @Published private(set) var error: String?

    func reload() {
        do {
            let text = try String(contentsOf: IPLogger.shared.fileURL, encoding: .utf8)
            let iso = ISO8601DateFormatter()
            entries = text.split(separator: "\n").compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let date = (object["timestamp"] as? String).flatMap(iso.date(from:))
                else { return nil }
                return LogEntry(date: date, fields: object)
            }
            .sorted { $0.date < $1.date }
            error = nil
        } catch {
            entries = []
            self.error = "Couldn't read the log: \(error.localizedDescription)"
        }
        periods = Self.buildPeriods(entries)
        dayCountries = Self.buildDayCountries(periods)
    }

    private static func buildPeriods(_ entries: [LogEntry]) -> [Period] {
        var result: [Period] = []
        var current: Period?
        var lastSeen = Date.distantPast

        for entry in entries {
            let continuous = entry.date.timeIntervalSince(lastSeen) <= gap
            if var period = current, continuous, entry.belongsWith(period.latest) {
                period.entries.append(entry)
                period.end = entry.date
                current = period
            } else {
                if var period = current {
                    // A change within the gap means the old period lasted until now.
                    if continuous { period.end = entry.date }
                    result.append(period)
                }
                current = Period(id: result.count, start: entry.date, end: entry.date, entries: [entry])
            }
            lastSeen = entry.date
        }
        if var period = current {
            if Date().timeIntervalSince(lastSeen) <= gap { period.end = Date() }
            result.append(period)
        }
        return result.reversed()
    }

    /// Seconds spent per country for each calendar day (periods split at midnight).
    private static func buildDayCountries(_ periods: [Period]) -> [Date: [String: TimeInterval]] {
        let calendar = Calendar.current
        var result: [Date: [String: TimeInterval]] = [:]
        for period in periods {
            guard let country = period.latest.effectiveCountry else { continue }
            var cursor = period.start
            repeat {
                let day = calendar.startOfDay(for: cursor)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
                let sliceEnd = min(period.end, nextDay)
                // Count at least a minute so short visits still show up.
                result[day, default: [:]][country, default: 0] += max(sliceEnd.timeIntervalSince(cursor), 60)
                cursor = nextDay
            } while cursor < period.end
        }
        return result
    }

    func dominantCountry(on day: Date) -> String? {
        dayCountries[day]?.max { $0.value < $1.value }?.key
    }

    func csv(for periods: [Period]) -> String {
        let rows = periods.reversed().flatMap(\.entries)
        let preferred = ["timestamp", "ip", "country", "region", "city", "loc", "org", "hostname", "postal", "timezone",
                         "real_country", "real_region", "real_city", "real_loc", "real_accuracy_m",
                         "ssid", "network_type", "interface", "vpn", "vpn_interface", "trigger"]
        let allKeys = Set(rows.flatMap(\.fields.keys))
        let columns = preferred.filter(allKeys.contains) + allKeys.subtracting(preferred).sorted()

        func escape(_ value: Any?) -> String {
            guard let value else { return "" }
            let text = "\(value)"
            guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        let lines = [columns.joined(separator: ",")]
            + rows.map { row in columns.map { escape(row.fields[$0]) }.joined(separator: ",") }
        return lines.joined(separator: "\n") + "\n"
    }
}
