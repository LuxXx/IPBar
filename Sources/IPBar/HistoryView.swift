import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HistoryWindow {
    private var window: NSWindow?
    private let store = HistoryStore()

    func show() {
        store.reload()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(store: store)))
            window.title = "IPBar History"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 960, height: 620))
            window.contentMinSize = NSSize(width: 760, height: 460)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("IPBarHistory")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum HistoryTab: String, CaseIterable {
    case timeline = "Timeline", calendar = "Calendar"
}

private enum VPNFilter: String, CaseIterable {
    case all = "All", vpn = "VPN", direct = "No VPN"
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var tab = HistoryTab.timeline
    @State private var search = ""
    @State private var vpnFilter = VPNFilter.all
    @State private var selection: Period.ID?
    @State private var scrollTarget: Period.ID?

    private var filtered: [Period] {
        store.periods.filter { period in
            switch vpnFilter {
            case .all: break
            case .vpn: if !period.latest.vpn { return false }
            case .direct: if period.latest.vpn { return false }
            }
            return search.isEmpty || period.matches(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.error {
                ContentUnavailableView("No history yet", systemImage: "clock", description: Text(error))
            } else {
                switch tab {
                case .timeline: timeline
                case .calendar: CalendarGrid(store: store, onSelectDay: jump(to:))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(HistoryTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if tab == .timeline {
                TextField("Search IP, ISP, city, Wi-Fi…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("", selection: $vpnFilter) {
                    ForEach(VPNFilter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Spacer()

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload log")
            Button("Export CSV…", action: exportCSV)
        }
        .padding(10)
    }

    private var summary: String {
        let countries = Set(filtered.compactMap(\.latest.effectiveCountry)).count
        let ips = Set(filtered.map(\.latest.ip)).count
        return "\(filtered.count) periods · \(ips) IPs · \(countries) countries"
    }

    private var timeline: some View {
        HSplitView {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())) {
                            ForEach(group.periods) { PeriodRow(period: $0).tag($0.id) }
                        }
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
            .frame(minWidth: 360, idealWidth: 420)

            Group {
                if let period = store.periods.first(where: { $0.id == selection }) {
                    PeriodDetail(period: period)
                } else {
                    ContentUnavailableView("Select a period", systemImage: "clock.arrow.circlepath")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groupedByDay: [(day: Date, periods: [Period])] {
        let calendar = Calendar.current
        var groups: [(day: Date, periods: [Period])] = []
        for period in filtered {
            let day = calendar.startOfDay(for: period.start)
            if groups.last?.day == day {
                groups[groups.count - 1].periods.append(period)
            } else {
                groups.append((day, [period]))
            }
        }
        return groups
    }

    private func jump(to day: Date) {
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        search = ""
        vpnFilter = .all
        tab = .timeline
        // Newest-first list: pick the last period that started that day, or one spanning it.
        let target = store.periods.last { $0.start >= day && $0.start < nextDay }
            ?? store.periods.first { $0.start < day && $0.end > day }
        selection = target?.id
        DispatchQueue.main.async { scrollTarget = target?.id }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ip-history-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.csv(for: filtered).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct PeriodRow: View {
    let period: Period

    var body: some View {
        let entry = period.latest
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(IPInfo.flag(for: entry.country))
                Text(entry.ip).font(.body.monospacedDigit().weight(.medium))
                if entry.vpn { Badge(text: "VPN", color: .purple) }
                Spacer()
                Text(timeRange).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(formatDuration(period.duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let entry = period.latest
        var parts = [entry.isp, entry.string("ssid").map { "Wi-Fi \($0)" }]
        if let real = entry.realLocation {
            parts.append("📍 \(real.city ?? "\(real.latitude), \(real.longitude)")")
        } else if let city = entry.string("city") {
            parts.append(city)
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private var timeRange: String {
        let start = period.start.formatted(date: .omitted, time: .shortened)
        let sameDay = Calendar.current.isDate(period.start, inSameDayAs: period.end)
        let end = sameDay
            ? period.end.formatted(date: .omitted, time: .shortened)
            : period.end.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return "\(start) – \(end)"
    }
}

private struct PeriodDetail: View {
    let period: Period

    var body: some View {
        let entry = period.latest
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(IPInfo.flag(for: entry.country)).font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(entry.ip).font(.title2.weight(.semibold).monospacedDigit()).textSelection(.enabled)
                        Text("\(period.start.formatted(date: .abbreviated, time: .shortened)) – \(period.end.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(period.duration))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("ISP", entry.string("org"))
                    row("Hostname", entry.string("hostname"))
                    row("IP location", place(city: entry.string("city"), region: entry.string("region"), country: entry.country))
                    row("Your location", entry.realLocation.map {
                        place(city: $0.city, region: $0.region, country: $0.country) ?? "\($0.latitude), \($0.longitude)"
                    })
                    row("Accuracy", entry.realLocation.map { "±\($0.accuracy) m (logged at ~\(precision(entry)))" })
                    row("Wi-Fi", entry.string("ssid"))
                    row("Network", entry.string("network_type").map { type in
                        [type, entry.string("interface")].compactMap { $0 }.joined(separator: " · ")
                    })
                    row("VPN", entry.fields["vpn"] == nil ? nil : (entry.vpn ? "Active (\(entry.string("vpn_interface") ?? "tunnel"))" : "Off"))
                    row("Time zone", entry.string("timezone"))
                    row("Log entries", "\(period.entries.count)")
                }

                if entry.ipCoordinate != nil || entry.realLocation != nil {
                    MapCard(ipCoordinate: entry.ipCoordinate, ipLabel: entry.string("city") ?? entry.ip, device: entry.realLocation)
                        .id(period.id)
                        .frame(height: 260)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).fontWeight(.semibold).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func place(city: String?, region: String?, country: String?) -> String? {
        let name = country.flatMap { Locale.current.localizedString(forRegionCode: $0) }
        let parts = [city, region, name].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "\(IPInfo.flag(for: country))  " + parts.joined(separator: ", ")
    }

    private func precision(_ entry: LogEntry) -> String {
        let decimals = entry.string("real_loc")?.split(separator: ",").map { $0.split(separator: ".").last?.count ?? 0 }.max() ?? 2
        switch decimals {
        case ...1: return "10 km"
        case 2: return "1 km"
        default: return "100 m"
        }
    }
}

/// A year of days, one row per month, each day showing where you spent most of it.
private struct CalendarGrid: View {
    @ObservedObject var store: HistoryStore
    let onSelectDay: (Date) -> Void
    @State private var year = Calendar.current.component(.year, from: Date())

    private let calendar = Calendar.current

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                    Text(String(year)).font(.title2.weight(.semibold).monospacedDigit())
                    Button { year += 1 } label: { Image(systemName: "chevron.right") }
                    Spacer()
                    Text("Each day shows the country you spent most of it in (your real location when logged, otherwise the IP's).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        Text("")
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").font(.caption2).foregroundStyle(.tertiary).frame(width: 22)
                        }
                    }
                    ForEach(1...12, id: \.self) { month in
                        GridRow {
                            Text(calendar.shortMonthSymbols[month - 1])
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                            ForEach(1...31, id: \.self) { day in
                                cell(month: month, day: day)
                            }
                        }
                    }
                }

                legend
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func cell(month: Int, day: Int) -> some View {
        if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
           calendar.component(.month, from: date) == month {
            let country = store.dominantCountry(on: date)
            let isToday = calendar.isDateInToday(date)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(country == nil ? Color.primary.opacity(0.05) : Color.primary.opacity(0.1))
                if let country { Text(IPInfo.flag(for: country)).font(.system(size: 13)) }
            }
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1.5))
            .help(tooltip(for: date))
            .onTapGesture { if country != nil { onSelectDay(date) } }
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }

    private func tooltip(for date: Date) -> String {
        let title = date.formatted(date: .complete, time: .omitted)
        guard let countries = store.dayCountries[date] else { return "\(title)\nNo data" }
        let lines = countries.sorted { $0.value > $1.value }.map { code, seconds in
            "\(IPInfo.flag(for: code)) \(Locale.current.localizedString(forRegionCode: code) ?? code): \(formatDuration(seconds))"
        }
        return ([title] + lines).joined(separator: "\n")
    }

    private var legend: some View {
        let totals = store.dayCountries
            .filter { calendar.component(.year, from: $0.key) == year }
            .compactMap { day, _ in store.dominantCountry(on: day) }
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .sorted { $0.value > $1.value }
        return HStack(spacing: 16) {
            ForEach(totals, id: \.key) { code, days in
                Text("\(IPInfo.flag(for: code)) \(Locale.current.localizedString(forRegionCode: code) ?? code): \(days) \(days == 1 ? "day" : "days")")
                    .font(.callout)
            }
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return seconds < 60 ? "<1m" : formatter.string(from: seconds) ?? ""
}
