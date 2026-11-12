import AppKit
import Network

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case flagAndIP, flagOnly, ipOnly, codeAndIP, flagAndCode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flagAndIP: return "Flag + IP"
        case .flagOnly: return "Flag only"
        case .ipOnly: return "IP only"
        case .codeAndIP: return "Country code + IP"
        case .flagAndCode: return "Flag + country code"
        }
    }

    func text(for info: IPInfo) -> String {
        let code = info.country ?? "??"
        switch self {
        case .flagAndIP: return "\(info.flag) \(info.ip)"
        case .flagOnly: return info.flag
        case .ipOnly: return info.ip
        case .codeAndIP: return "\(code) \(info.ip)"
        case .flagAndCode: return "\(info.flag) \(code)"
        }
    }
}

@MainActor
final class IPModel: ObservableObject {
    @Published private(set) var info: IPInfo?
    @Published private(set) var network: NetworkSnapshot?
    @Published private(set) var deviceLocation: DeviceLocation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "ipinfoToken") }
    }
    @Published var notifyMode: NotifyMode {
        didSet {
            UserDefaults.standard.set(notifyMode.rawValue, forKey: "notifyMode")
            if notifyMode != .off { Notifier.shared.requestAuthorization() }
        }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var logWiFiName: Bool {
        didSet {
            UserDefaults.standard.set(logWiFiName, forKey: "logWiFiName")
            if logWiFiName { LocationService.shared.request() }
        }
    }
    @Published var logLocation: Bool {
        didSet {
            UserDefaults.standard.set(logLocation, forKey: "logLocation")
            if logLocation { LocationService.shared.request() }
            if !logLocation { deviceLocation = nil }
        }
    }
    /// Decimal places kept for the real location: 1 ≈ 11 km, 2 ≈ 1 km, 3 ≈ 100 m.
    @Published var locationPrecision: Int {
        didSet { UserDefaults.standard.set(locationPrecision, forKey: "locationPrecision") }
    }

    private let monitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var timer: Timer?
    private var pendingRefresh: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var sawInitialPath = false

    init() {
        let defaults = UserDefaults.standard
        token = defaults.string(forKey: "ipinfoToken") ?? ""
        notifyMode = defaults.string(forKey: "notifyMode").flatMap(NotifyMode.init) ?? .anyChange
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init) ?? .flagAndIP
        logWiFiName = defaults.object(forKey: "logWiFiName") as? Bool ?? true
        logLocation = defaults.object(forKey: "logLocation") as? Bool ?? true
        locationPrecision = defaults.object(forKey: "locationPrecision") as? Int ?? 2

        if notifyMode != .off { Notifier.shared.requestAuthorization() }
        if logWiFiName || logLocation { LocationService.shared.request() }

        // Network changes (Wi-Fi switch, VPN up/down): wait briefly for routes to settle.
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.currentPath = path
                if !self.sawInitialPath { self.sawInitialPath = true; return }
                self.scheduleRefresh(after: 2, trigger: "network")
            }
        }
        monitor.start(queue: .global(qos: .utility))

        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(trigger: "timer") }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(after: 3, trigger: "wake") }
        }

        // Give the path monitor a moment to report the initial path.
        scheduleRefresh(after: 0.3, trigger: "launch")
    }

    func scheduleRefresh(after seconds: Double, trigger: String) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.refresh(trigger: trigger)
        }
    }

    func refreshIfStale() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 60 { return }
        refresh(trigger: "open")
    }

    func refresh(trigger: String = "manual") {
        fetchTask?.cancel()
        isLoading = true
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (info, raw) = try await IPInfoClient.fetch(token: self.token)
                try Task.checkCancellation()
                let network = NetworkInfo.snapshot(path: self.currentPath, includeSSID: self.logWiFiName)
                let location = self.logLocation
                    ? await LocationService.shared.currentLocation(decimals: self.locationPrecision)
                    : nil
                try Task.checkCancellation()
                Notifier.shared.notifyIfNeeded(
                    old: self.info, new: info, mode: self.notifyMode,
                    oldLocation: self.deviceLocation, newLocation: location
                )
                self.info = info
                self.network = network
                self.deviceLocation = location
                self.errorMessage = nil
                self.lastUpdated = Date()
                IPLogger.shared.record(raw: raw, ip: info.ip, network: network, location: location, trigger: trigger)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }
}
