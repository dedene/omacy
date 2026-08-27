import AppKit
import ScreenSaver

private let logger = AppexLog.logger("Configuration")

@objc(OmacyConfigurationViewController)
class OmacyConfigurationViewController: ScreenSaverConfigurationViewController {
    private let effectField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let title = NSTextField(labelWithString: "Omacy")
        title.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let settings = OmacyStore.loadSettings()
        effectField.stringValue = settings.effect
        effectField.placeholderString = "random or a ttfx name"
        effectField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectField)

        let restore = NSButton(title: "Restore default art", target: self, action: #selector(restoreArt))
        restore.bezelStyle = .rounded
        restore.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(restore)

        let ok = NSButton(title: "OK", target: self, action: #selector(saveAndDismiss))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ok)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            effectField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            effectField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            effectField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            restore.leadingAnchor.constraint(equalTo: effectField.leadingAnchor),
            restore.topAnchor.constraint(equalTo: effectField.bottomAnchor, constant: 12),
            ok.trailingAnchor.constraint(equalTo: effectField.trailingAnchor),
            ok.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: effectField.leadingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -8)
        ])
        self.view = container
        self.preferredContentSize = NSSize(width: 360, height: 180)
    }

    @objc private func restoreArt() {
        do {
            try OmacyStore.restoreDefaultArt()
            statusLabel.stringValue = "Default wordmark restored"
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func saveAndDismiss(_ sender: Any?) {
        var settings = OmacyStore.loadSettings()
        settings.effect = effectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.effect.isEmpty { settings.effect = "random" }
        do {
            try OmacyStore.save(settings: settings, art: OmacyStore.loadArt())
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
        if let window = self.view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            self.dismiss(nil)
        }
    }
}
