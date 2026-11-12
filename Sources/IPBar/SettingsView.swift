import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let model: IPModel

    init(model: IPModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "IPBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: IPModel
    @ObservedObject private var logger = IPLogger.shared
    @ObservedObject private var location = LocationService.shared
    @State private var notificationsDenied = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var moveError: String?

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Show", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("Notifications") {
                Picker("Notify on", selection: $model.notifyMode) {
                    ForEach(NotifyMode.allCases) { Text($0.label).tag($0) }
                }
                if notificationsDenied && model.notifyMode != .off {
                    Button("Notifications are turned off for IPBar — open System Settings") {
                        openSystemSettings("com.apple.Notifications-Settings.extension")
                    }
                    .buttonStyle(.link)
                }
            }

            Section {
                Toggle("Log Wi-Fi network name", isOn: $model.logWiFiName)
                Toggle("Log real location", isOn: $model.logLocation)
                if model.logLocation {
                    Picker("Location precision", selection: $model.locationPrecision) {
                        Text("~10 km").tag(1)
                        Text("~1 km").tag(2)
                        Text("~100 m").tag(3)
                    }
                }
                if (model.logWiFiName || model.logLocation) && !location.isAuthorized {
                    HStack {
                        Text("The Wi-Fi name and real location need Location Services access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if location.status == .notDetermined {
                            Button("Allow…") { location.request() }
                        } else {
                            Button("Open Settings") {
                                openSystemSettings("com.apple.preference.security?Privacy_LocationServices")
                            }
                        }
                    }
                }

                LabeledContent("Log file") {
                    Text(displayPath(logger.fileURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(logger.fileURL.path)
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([logger.fileURL])
                    }
                    Spacer()
                    if let iCloud = IPLogger.iCloudFolder, logger.folder.standardizedFileURL != iCloud.standardizedFileURL {
                        Button("Move to iCloud Drive") { move(to: iCloud) }
                    }
                    Button("Choose Folder…", action: chooseFolder)
                    if !logger.isDefaultLocation {
                        Button("Reset") { move(to: IPLogger.defaultFolder) }
                    }
                }
                if let moveError {
                    Text(moveError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Logging")
            } footer: {
                Text("The real location comes from macOS Wi-Fi positioning, so it stays accurate behind a VPN. Keeping the log in iCloud Drive or Dropbox means it survives a new Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Token", text: $model.token)
                    .onSubmit { model.refresh() }
            } header: {
                Text("ipinfo.io")
            } footer: {
                Text("Optional. Without a token ipinfo.io allows a limited number of free requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.notifyMode) {
            try? await Task.sleep(for: .milliseconds(500))
            notificationsDenied = await Notifier.shared.isDenied()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        .onChange(of: location.status) { _, _ in
            model.refresh(trigger: "settings")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where IPBar keeps ip-log.jsonl"
        if panel.runModal() == .OK, let url = panel.url {
            move(to: url)
        }
    }

    private func move(to folder: URL) {
        do {
            try logger.moveLog(to: folder)
            moveError = nil
        } catch {
            moveError = error.localizedDescription
        }
    }

    private func displayPath(_ url: URL) -> String {
        url.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive")
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func openSystemSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }
}
