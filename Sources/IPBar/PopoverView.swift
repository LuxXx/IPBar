import MapKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: IPModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = model.info {
                InfoGrid(info: info, network: model.network)
                if let coordinate = info.coordinate {
                    MapCard(coordinate: coordinate).id(info.loc)
                }
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Footer(model: model, openSettings: openSettings)
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct InfoGrid: View {
    let info: IPInfo
    let network: NetworkSnapshot?

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

private struct MapCard: View {
    let coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )))
    }

    var body: some View {
        Map(position: $position) {
            Marker("", coordinate: coordinate)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

private struct Footer: View {
    @ObservedObject var model: IPModel
    let openSettings: () -> Void

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
            ("Network", model.network?.displayNetwork), ("VPN", model.network.map { $0.vpn ? "Active" : "Off" }),
        ]
        .compactMap { label, value in value.map { "\(label): \($0)" } }
        .joined(separator: "\n")
    }
}
