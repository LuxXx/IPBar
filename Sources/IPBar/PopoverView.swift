import MapKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: IPModel
    let openSettings: () -> Void
    let openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = model.info {
                InfoGrid(info: info, network: model.network, location: model.deviceLocation)
                if info.coordinate != nil || model.deviceLocation != nil {
                    MapCard(ipCoordinate: info.coordinate, ipLabel: info.city ?? info.ip, device: model.deviceLocation)
                        .id("\(info.loc ?? "")|\(model.deviceLocation.map { "\($0.latitude),\($0.longitude)" } ?? "")")
                }
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Footer(model: model, openSettings: openSettings, openHistory: openHistory)
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct InfoGrid: View {
    let info: IPInfo
    let network: NetworkSnapshot?
    let location: DeviceLocation?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row("Public IP", info.ip)
            row("Hostname", info.hostname)
            row("ISP", info.isp)
            row("ASN", info.asn)
            row("Country / Region", info.countryName.map { "\(info.flag)  \($0)" }, copy: info.countryName)
            row("Region", info.region)
            row("City", info.city)
            row("Postal Code", info.postal)
            row("Time Zone", info.timezone)
            row("Coordinates", info.formattedCoordinates)
            row("Your Location", location?.displayName, copy: location.map { "\($0.latitude),\($0.longitude)" })
            row("Network", network?.displayNetwork)
            row("VPN", network.map { $0.vpnInterface.map { "Active (\($0))" } ?? "Off" })
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, copy: String? = nil) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                CopyableText(value: value, copyValue: copy ?? value)
            }
        }
    }
}

/// Click to copy, with a brief "Copied" confirmation.
private struct CopyableText: View {
    let value: String
    let copyValue: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Text(copied ? "Copied" : value)
            .foregroundStyle(copied ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            .onHover { hovering = $0 }
            .onTapGesture {
                Clipboard.copy(copyValue)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    copied = false
                }
            }
            .help("\(value)\nClick to copy")
    }
}

/// Shows the IP's location and, when known, the Mac's real location.
struct MapCard: View {
    let ipCoordinate: CLLocationCoordinate2D?
    let ipLabel: String
    let device: DeviceLocation?
    @State private var position: MapCameraPosition

    init(ipCoordinate: CLLocationCoordinate2D?, ipLabel: String, device: DeviceLocation?) {
        self.ipCoordinate = ipCoordinate
        self.ipLabel = ipLabel
        self.device = device
        let points = [ipCoordinate, device?.coordinate].compactMap { $0 }
        _position = State(initialValue: Self.camera(for: points))
    }

    var body: some View {
        Map(position: $position) {
            if let ipCoordinate, let device, !isSamePlace {
                MapPolyline(coordinates: [device.coordinate, ipCoordinate])
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if let ipCoordinate {
                Marker(device == nil ? ipLabel : "IP: \(ipLabel)", systemImage: "network", coordinate: ipCoordinate)
                    .tint(.purple)
            }
            if let device {
                Marker("You: \(device.city ?? "here")", systemImage: "location.fill", coordinate: device.coordinate)
                    .tint(.blue)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .overlay(alignment: .bottomLeading) {
            if let distance, !isSamePlace {
                Text("\(distance) apart")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }

    private var meters: CLLocationDistance? {
        guard let ipCoordinate, let device else { return nil }
        return CLLocation(latitude: ipCoordinate.latitude, longitude: ipCoordinate.longitude)
            .distance(from: CLLocation(latitude: device.latitude, longitude: device.longitude))
    }

    private var isSamePlace: Bool { (meters ?? 0) < 2_000 }

    private var distance: String? {
        meters.map {
            Measurement(value: $0, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
    }

    /// Frames all points with some padding; a single point gets a city-level zoom.
    private static func camera(for points: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard let first = points.first else { return .automatic }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let span = max(lats.max()! - lats.min()!, lons.max()! - lons.min()!)
        if points.count == 1 || span < 0.02 {
            return .region(MKCoordinateRegion(center: first, span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)))
        }
        let center = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2, longitude: (lons.max()! + lons.min()!) / 2)
        return .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: min((lats.max()! - lats.min()!) * 1.6 + 0.5, 170),
                longitudeDelta: min((lons.max()! - lons.min()!) * 1.6 + 0.5, 360)
            )
        ))
    }
}

private struct Footer: View {
    @ObservedObject var model: IPModel
    let openSettings: () -> Void
    let openHistory: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("IP")
                .font(.title2.weight(.heavy).italic())
                .foregroundStyle(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))

            if let updated = model.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: openHistory) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("History")

            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            Menu {
                Button("Copy IP") { Clipboard.copy(model.info?.ip) }
                Button("Copy All Details") { Clipboard.copy(details) }
                Divider()
                Button("Show Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([IPLogger.shared.fileURL])
                }
                Button("History…", action: openHistory)
                Button("Settings…", action: openSettings)
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var details: String? {
        guard let info = model.info else { return nil }
        return [
            ("IP", info.ip), ("Hostname", info.hostname), ("ISP", info.org),
            ("Country", info.countryName), ("Region", info.region), ("City", info.city),
            ("Postal", info.postal), ("Time Zone", info.timezone), ("Location", info.loc),
            ("Your Location", model.deviceLocation.map { "\($0.displayName) (\($0.latitude),\($0.longitude))" }),
            ("Network", model.network?.displayNetwork), ("VPN", model.network.map { $0.vpn ? "Active" : "Off" }),
        ]
        .compactMap { label, value in value.map { "\(label): \($0)" } }
        .joined(separator: "\n")
    }
}
