import AppKit
import UserNotifications

enum NotifyMode: String, CaseIterable, Identifiable {
    case anyChange, countryChange, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anyChange: return "Any IP change"
        case .countryChange: return "Country change only"
        case .off: return "Off"
        }
    }
}

/// Posts a notification when the public IP (or country) changes.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var center: UNUserNotificationCenter { .current() }

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    func notifyIfNeeded(old: IPInfo?, new: IPInfo, mode: NotifyMode,
                        oldLocation: DeviceLocation? = nil, newLocation: DeviceLocation? = nil) {
        guard let old, old.ip != new.ip else { return }
        let countryChanged = old.country != new.country

        switch mode {
        case .off: return
        case .countryChange where !countryChanged: return
        default: break
        }

        let content = UNMutableNotificationContent()
        if countryChanged {
            content.title = "\(old.flag) → \(new.flag)  Now in \(new.countryName ?? "unknown country")"
        } else {
            content.title = "\(new.flag)  IP address changed"
        }
        content.body = [
            "\(old.ip) → \(new.ip)",
            [new.city, new.isp].compactMap { $0 }.joined(separator: " · "),
            Self.movement(from: oldLocation, to: newLocation),
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        content.sound = .default

        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// "📍 You're still in Lisbon" / "📍 You moved to Porto (275 km)".
    private static func movement(from old: DeviceLocation?, to new: DeviceLocation?) -> String? {
        guard let new else { return nil }
        let place = new.city ?? new.country ?? "the same place"
        guard let old else { return "📍 You're in \(place)" }
        let meters = new.distance(to: old)
        if meters < 5_000 { return "📍 You're still in \(place)" }
        let distance = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return "📍 You moved to \(place) (\(distance))"
    }

    // Show banners even while the popover is open (app is "active").
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
