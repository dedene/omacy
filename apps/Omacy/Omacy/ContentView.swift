//
//  ContentView.swift
//  Omacy
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Main view for the host application. Shows extension registration status
//  and provides install / uninstall and "set as active screensaver" actions.
//

import SwiftUI

private let logger = AppexLog.logger("HostApp")

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var pluginManager = PluginManager()
    @State private var statusMessage = "Ready"

    var body: some View {
        VStack(spacing: 20) {
            // MARK: - Header
            Image(systemName: "tv")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Omacy")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Screensaver Extension")
                .font(.title2)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Extension Status
            Text("Extension Status")
                .font(.headline)

            extensionStatusView
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Screensaver Activation
            Text("Screensaver Activation")
                .font(.headline)

            screensaverActivationView
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 40)

            // MARK: - Actions
            HStack(spacing: 12) {
                Button("Open Preview") {
                    openWindow(id: "preview")
                }
                .buttonStyle(.borderedProminent)

                Button("Edit art") {
                    openWindow(id: "config")
                }
                .buttonStyle(.bordered)

                Button("Open Screen Saver Settings") {
                    openScreenSaverSettings()
                }
                .buttonStyle(.bordered)
            }

            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .fixedSize()
    }

    @ViewBuilder
    private var extensionStatusView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(pluginManager.isInstalled ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)

                    if pluginManager.isInstalled {
                        Text("Installed")
                            .fontWeight(.medium)
                        if let version = pluginManager.installedVersion {
                            Text("(v\(version))")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Not Installed")
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if pluginManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button {
                            pluginManager.checkInstallationStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh status")
                    }
                }

                if pluginManager.isInstalled {
                    if let path = pluginManager.installedPath {
                        HStack(alignment: .top) {
                            Text("Path:")
                                .foregroundColor(.secondary)
                            Text(path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                } else {
                    if let embeddedVersion = pluginManager.embeddedVersion {
                        Text("Embedded version: \(embeddedVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = pluginManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack {
                    Spacer()
                    if pluginManager.isInstalled {
                        Button("Uninstall") {
                            uninstallExtension()
                        }
                        .buttonStyle(.bordered)
                        .disabled(pluginManager.isLoading)
                    } else {
                        Button("Install") {
                            installExtension()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pluginManager.isLoading)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var screensaverActivationView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(pluginManager.isActiveScreensaver ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)

                    if pluginManager.isActiveScreensaver {
                        Text("Active")
                            .fontWeight(.medium)
                    } else {
                        Text("Not Active")
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if pluginManager.isCheckingScreensaver {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button {
                            pluginManager.checkScreensaverStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh status")
                    }
                }

                if let error = pluginManager.screensaverError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if pluginManager.isInstalled && !pluginManager.isActiveScreensaver {
                    HStack {
                        Spacer()
                        Button("Enable as Screensaver") {
                            Task {
                                await pluginManager.enableAsScreensaver()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pluginManager.isCheckingScreensaver)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(8)
        }
    }

    private func installExtension() {
        statusMessage = "Installing extension..."
        do {
            try pluginManager.install()
            statusMessage = "Extension installed successfully"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
            logger.error("Install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uninstallExtension() {
        statusMessage = "Uninstalling extension..."
        do {
            try pluginManager.uninstall()
            statusMessage = "Extension uninstalled successfully"
        } catch {
            statusMessage = "Uninstall failed: \(error.localizedDescription)"
            logger.error("Uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    ContentView()
}
