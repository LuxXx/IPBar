import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: IPModel
    private let settingsWindow: SettingsWindow
    private var cancellables = Set<AnyCancellable>()

    init(model: IPModel) {
        self.model = model
        self.settingsWindow = SettingsWindow(model: model)
        super.init()

        let host = NSHostingController(rootView: PopoverView(model: model) { [weak self] in self?.openSettings() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.$info.combineLatest(model.$errorMessage, model.$menuBarStyle)
            .sink { [weak self] info, error, style in self?.updateTitle(info: info, error: error, style: style) }
            .store(in: &cancellables)
    }

    private func updateTitle(info: IPInfo?, error: String?, style: MenuBarStyle) {
        let text: String
        switch (info, error) {
        case let (info?, nil): text = style.text(for: info)
        case let (info?, _?): text = style == .flagOnly || style == .flagAndCode ? "⚠️" : "⚠️ \(info.ip)"
        case (nil, _?): text = "⚠️ No IP"
        case (nil, nil): text = "🌐 …"
        }
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
        )
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refreshIfStale()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Copy IP", action: #selector(copyIP), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Show Log in Finder", action: #selector(showLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        settingsWindow.show()
    }

    @objc private func refresh() { model.refresh() }
    @objc private func copyIP() { Clipboard.copy(model.info?.ip) }
    @objc private func showLog() { NSWorkspace.shared.activateFileViewerSelecting([IPLogger.shared.fileURL]) }
}

enum Clipboard {
    static func copy(_ string: String?) {
        guard let string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
