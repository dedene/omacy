import SwiftUI
import AppKit

private let logger = AppexLog.logger("HostApp")

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var pluginManager = PluginManager()
    @State private var statusMessage = "Ready"

    var body: some View {
        NavigationStack {
            Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Omacy")
                            .font(.headline)
                        Text("ASCII screensaver")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            extensionSection
            screensaverSection
            if statusMessage != "Ready" {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Effects by Terminal Text Effects (ChrisBuilds), Rust engine ttfx.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Preview") {
                        openWindow(id: "preview")
                    }
                    Button("Art") {
                        openWindow(id: "art")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Screen Saver Settings…") {
                        openScreenSaverSettings()
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 580)
    }

    private var extensionSection: some View {
        Section("Extension") {
            HStack {
                statusDot(on: pluginManager.isInstalled && !pluginManager.isPluginMissing)
                if pluginManager.isInstalled {
                    Text("Installed")
                    if let version = pluginManager.installedVersion {
                        Text("v\(version)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Not registered")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton(busy: pluginManager.isLoading) {
                    pluginManager.checkInstallationStatus()
                }
            }

            if pluginManager.isInstalled {
                if pluginManager.isPluginMissing {
                    Text("The registered screensaver extension is missing. Re-register it from this app.")
                        .foregroundStyle(.orange)
                }
                if let path = pluginManager.installedPath {
                    LabeledContent("Path") {
                        Text(path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                if pluginManager.hasConflictingRegistrations {
                    Text("Registered in more than one place. Unregister extras so only /Applications or DerivedData remains.")
                        .foregroundStyle(.orange)
                    ForEach(pluginManager.registeredPaths, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Omacy is not in System Settings yet. Register the extension from this app — the preview still runs either way.")
                    .foregroundStyle(.secondary)
                if let embeddedVersion = pluginManager.embeddedVersion {
                    LabeledContent("Embedded") {
                        Text("v\(embeddedVersion)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if let error = pluginManager.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }

            if pluginManager.isInstalled && !pluginManager.isPluginMissing {
                Button("Uninstall", role: .destructive) {
                    uninstallExtension()
                }
                .disabled(pluginManager.isLoading)
            } else {
                Button(pluginManager.isPluginMissing ? "Re-register" : "Install") {
                    installExtension()
                }
                .disabled(pluginManager.isLoading)
            }
        }
    }

    private var screensaverSection: some View {
        Section("Screensaver") {
            HStack {
                statusDot(on: pluginManager.isActiveScreensaver)
                if pluginManager.isActiveScreensaver {
                    Text("Active")
                } else {
                    Text("Not active")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton(busy: pluginManager.isCheckingScreensaver) {
                    pluginManager.checkScreensaverStatus()
                }
            }

            if let error = pluginManager.screensaverError {
                Text(error)
                    .foregroundStyle(.red)
            }

            if pluginManager.isInstalled && !pluginManager.isActiveScreensaver {
                Button("Use as Screensaver") {
                    Task {
                        await pluginManager.enableAsScreensaver()
                    }
                }
                .disabled(pluginManager.isCheckingScreensaver)
            }
        }
    }

    private func statusDot(on: Bool) -> some View {
        Circle()
            .fill(on ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private func refreshButton(busy: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh status")
            }
        }
        .frame(width: 24, height: 24)
    }

    private func installExtension() {
        statusMessage = "Installing extension…"
        do {
            try pluginManager.install()
            statusMessage = "Extension installed"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
            logger.error("Install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uninstallExtension() {
        statusMessage = "Uninstalling extension…"
        do {
            try pluginManager.uninstall()
            statusMessage = "Unregistered. Move Omacy to Trash to finish removing it. You can also delete the App Group data if you want a clean slate."
        } catch {
            statusMessage = "Uninstall failed: \(error.localizedDescription)"
            logger.error("Uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openScreenSaverSettings() {
        // Tahoe keeps Screen Saver as a sheet on Wallpaper. The old
        // ScreenSaver-Settings.extension URL no longer opens that pane.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ContentView()
}
