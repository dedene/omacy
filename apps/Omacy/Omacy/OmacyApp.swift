import AppKit
import SwiftUI

extension Notification.Name {
    static let omacyOpenWorkspace = Notification.Name("be.zenjoy.omacy.openWorkspace")
}

enum OmacyAppRoute: Equatable {
    case workspace

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "omacy" else { return nil }
        return url.host?.lowercased() == "art" || url.path.lowercased() == "/art" ? .workspace : nil
    }

    static func containsLegacyArtArgument(_ arguments: [String]) -> Bool {
        arguments.contains("--art")
    }
}

@MainActor
final class OmacyAppServices: ObservableObject {
    let pluginManager: PluginManager
    let workspace: OmacyWorkspaceModel

    init() {
        OmacyHostBootstrap.migrateLegacyConfigurationIfNeeded()
        let pluginManager = PluginManager()
        self.pluginManager = pluginManager
        workspace = OmacyWorkspaceModel(
            load: OmacyStore.loadConfiguration,
            save: OmacyStore.save,
            bundledArt: OmacyStore.bundledArt,
            convert: { try OmacyAsciiConverter.convert($0, settings: $1) },
            prepareForTest: { try await pluginManager.prepareForScreenSaverTest() },
            launch: { try await ScreenSaverLauncher().launch() }
        )
    }
}

enum OmacyHostBootstrap {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func migrateLegacyConfigurationIfNeeded() {
        guard !isRunningTests else { return }
        do {
            let legacyGroup = "group.be.zenjoy.omacy"
            try OmacyStore.performHostMigrationIfNeeded(
                defaults: {
                    guard let defaults = UserDefaults(suiteName: legacyGroup) else { return nil }
                    return OmacyLegacyConfiguration(
                        settingsData: defaults.data(forKey: "settingsJSON"),
                        art: defaults.string(forKey: "screensaverArt")
                    )
                },
                files: {
                    guard let directory = FileManager.default.containerURL(
                        forSecurityApplicationGroupIdentifier: legacyGroup
                    ) else { return nil }
                    return OmacyLegacyConfiguration(
                        settingsData: try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
                        art: try? String(
                            contentsOf: directory.appendingPathComponent("screensaver.txt"),
                            encoding: .utf8
                        )
                    )
                }
            )
        } catch {
            NSLog("Omacy configuration migration failed: %@", error.localizedDescription)
        }
    }
}

@main
@MainActor
struct OmacyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var services = OmacyAppServices()

    var body: some Scene {
        Window("Omacy", id: "main") {
            ContentView(pluginManager: services.pluginManager, workspace: services.workspace)
                .onOpenURL { route($0) }
                .onReceive(NotificationCenter.default.publisher(for: .omacyOpenWorkspace)) { _ in showWorkspace() }
        }
        .defaultSize(width: ArtMetrics.defaultWindowWidth, height: ArtMetrics.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(after: .appInfo) { CheckForUpdatesCommand() } }
    }

    private func route(_ url: URL) {
        guard OmacyAppRoute.parse(url) != nil else { return }
        showWorkspace()
    }

    private func showWorkspace() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowResizeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !OmacyHostBootstrap.isRunningTests else { return }
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow,
                      window.title == "Omacy",
                      window.isVisible,
                      window.screen != nil,
                      window.styleMask.contains(.titled),
                      window.level == .normal,
                      window.frame.width < OmacyWindowSizing.minimum.width
                        || window.frame.height < OmacyWindowSizing.minimum.height else { return }
                OmacyWindowSizing.enforce(on: window)
            }
        }
        OmacyUpdateRecoveryLauncher.reconcileAfterLaunch()
        SparkleUpdater.shared.start()
        if OmacyAppRoute.containsLegacyArtArgument(CommandLine.arguments) {
            focusWorkspace()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { OmacyAppRoute.parse($0) != nil }) {
            focusWorkspace()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let application = notification.object as? NSApplication,
              let window = OmacyWindowSizing.workspaceWindow(in: application) else { return }
        OmacyWindowSizing.enforce(on: window)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OmacyTerminationGuard.shared.requestTermination { saved in
            NSApp.reply(toApplicationShouldTerminate: saved)
        }.terminateReply
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
            self.windowResizeObserver = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { focusWorkspace() }
        return true
    }

    private func focusWorkspace() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Omacy" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .omacyOpenWorkspace, object: nil)
        }
    }
}
