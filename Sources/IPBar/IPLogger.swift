import Foundation

/// Appends lookups to ip-log.jsonl (default: ~/Library/Application Support/IPBar/,
/// movable to e.g. iCloud Drive). One JSON object per line: the raw ipinfo response
/// plus local network fields, "timestamp" (ISO 8601, UTC) and "trigger". A line is
/// written whenever the IP, Wi-Fi network or VPN state changes or the Mac moved more
/// than `moveThreshold`, and otherwise at most
/// once per `heartbeat` so the log also shows how long each IP was in use.
final class IPLogger: ObservableObject {
    static let shared = IPLogger()
    static let fileName = "ip-log.jsonl"

    static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IPBar", isDirectory: true)

    static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("IPBar", isDirectory: true)
    }

    @Published private(set) var fileURL: URL
    private let heartbeat: TimeInterval = 60 * 60
    private let moveThreshold: Double = 5_000
    private var lastKey: String?
    private var lastLocation: DeviceLocation?
    private var lastWrite: Date?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var folder: URL { fileURL.deletingLastPathComponent() }
    var isDefaultLocation: Bool { folder.standardizedFileURL == Self.defaultFolder.standardizedFileURL }

    private init() {
        let folder = UserDefaults.standard.string(forKey: "logFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent(Self.fileName)
        restoreLastEntry()
    }

    func record(raw: Data, ip: String, network: NetworkSnapshot, location: DeviceLocation?, trigger: String) {
        let now = Date()
        let key = Self.key(ip: ip, ssid: network.ssid, vpn: network.vpn)
        let moved = location.map { new in lastLocation.map { new.distance(to: $0) > moveThreshold } ?? true } ?? false
        let changed = key != lastKey || moved
        if !changed, let lastWrite, now.timeIntervalSince(lastWrite) < heartbeat { return }

        guard var object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return }
        object.removeValue(forKey: "readme")
        object.merge(network.logFields) { _, local in local }
        if let location { object.merge(location.logFields) { _, local in local } }
        object["timestamp"] = formatter.string(from: now)
        object["trigger"] = changed ? "change" : trigger
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        line.append(0x0A)

        append(line, to: fileURL)
        lastKey = key
        lastWrite = now
        if let location { lastLocation = location }
    }

    /// Moves the log into `folder`. If a log already exists there, the current
    /// entries are appended to it (sort by "timestamp" when analysing).
    func moveLog(to folder: URL) throws {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(Self.fileName)
        guard target.standardizedFileURL != fileURL.standardizedFileURL else { return }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: fileURL.path) {
            if fm.fileExists(atPath: target.path) {
                append(try Data(contentsOf: fileURL), to: target)
                try fm.removeItem(at: fileURL)
            } else {
                try fm.moveItem(at: fileURL, to: target)
            }
        }

        fileURL = target
        let isDefault = folder.standardizedFileURL == Self.defaultFolder.standardizedFileURL
        UserDefaults.standard.set(isDefault ? nil : folder.path, forKey: "logFolder")
        restoreLastEntry()
    }

    private func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func key(ip: String?, ssid: String?, vpn: Bool) -> String {
        "\(ip ?? "")|\(ssid ?? "")|\(vpn)"
    }

    /// Read the last line so an app restart doesn't log a spurious "change".
    private func restoreLastEntry() {
        lastKey = nil
        lastWrite = nil
        lastLocation = nil
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd(),
              let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        else { return }
        lastKey = Self.key(ip: object["ip"] as? String, ssid: object["ssid"] as? String, vpn: object["vpn"] as? Bool ?? false)
        lastWrite = (object["timestamp"] as? String).flatMap(formatter.date(from:))
        let coords = (object["real_loc"] as? String)?.split(separator: ",").compactMap { Double($0) } ?? []
        if coords.count == 2 {
            lastLocation = DeviceLocation(latitude: coords[0], longitude: coords[1], accuracy: object["real_accuracy_m"] as? Int ?? 0)
        }
    }
}
