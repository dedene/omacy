import SwiftUI

extension Notification.Name {
    static let omacyOpenArt = Notification.Name("be.zenjoy.omacy.openArt")
}

@main
struct OmacyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .onOpenURL(perform: handleOpenURL)
                .onReceive(NotificationCenter.default.publisher(for: .omacyOpenArt)) { _ in
                    openWindow(id: "art")
                }
        }
        .defaultSize(width: 580, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
            }
        }

        Window("Preview", id: "preview") {
            PreviewViewRepresentable()
                .ignoresSafeArea()
        }
        .defaultSize(width: 960, height: 600)

        Window("Art", id: "art") {
            ConfigView()
        }
        .defaultSize(width: ArtMetrics.defaultWindowWidth, height: ArtMetrics.defaultWindowHeight)
        .windowResizability(.contentMinSize)
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "omacy" else { return }
        if url.host == "art" || url.path == "/art" {
            openWindow(id: "art")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SparkleUpdater.shared.start()
        if CommandLine.arguments.contains("--art") {
            NotificationCenter.default.post(name: .omacyOpenArt, object: nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "omacy" && ($0.host == "art" || $0.path == "/art") }) {
            NotificationCenter.default.post(name: .omacyOpenArt, object: nil)
        }
    }
}
