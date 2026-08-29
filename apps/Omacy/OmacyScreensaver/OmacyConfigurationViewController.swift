import AppKit
import ScreenSaver

private let logger = AppexLog.logger("Configuration")

@objc(OmacyConfigurationViewController)
class OmacyConfigurationViewController: ScreenSaverConfigurationViewController {
    private var didLaunch = false
    private let statusLabel = NSTextField(labelWithString: "Art and effects are configured in the Omacy app.")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        let title = NSTextField(labelWithString: "Omacy")
        title.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        let open = NSButton(title: "Open Omacy", target: self, action: #selector(openArt))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(open)

        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(close)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            open.trailingAnchor.constraint(equalTo: container.centerXAnchor, constant: -6),
            open.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            close.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: 6),
            close.bottomAnchor.constraint(equalTo: open.bottomAnchor)
        ])
        view = container
        preferredContentSize = NSSize(width: 380, height: 140)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didLaunch else { return }
        didLaunch = true
        openArt()
        closeSheet()
    }

    @objc private func openArt() {
        if OmacyHostLauncher.openArt() {
            statusLabel.stringValue = "Opened Omacy."
        } else {
            statusLabel.stringValue = "Could not open Omacy. Launch it from /Applications."
            logger.error("failed to open host app")
        }
    }

    @objc private func closeSheet() {
        if let window = view.window {
            if let parent = window.sheetParent {
                parent.endSheet(window)
                return
            }
            window.close()
            return
        }
        dismiss(nil)
    }
}

enum OmacyHostLauncher {
    static let artURL = URL(string: "omacy://art")!

    static func openArt() -> Bool {
        var opened = NSWorkspace.shared.open(artURL)
        if let app = hostAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.arguments = ["--art"]
            NSWorkspace.shared.openApplication(at: app, configuration: config)
            opened = true
        }
        return opened
    }

    static var hostAppURL: URL? {
        var url = Bundle.main.bundleURL
        // …/Omacy.app/Contents/PlugIns/OmacyScreensaver.appex
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url.pathExtension == "app" ? url : nil
    }
}
