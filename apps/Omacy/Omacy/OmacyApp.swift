import SwiftUI

@main
struct OmacyApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .defaultSize(width: 580, height: 560)
        .windowResizability(.contentMinSize)

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
}
