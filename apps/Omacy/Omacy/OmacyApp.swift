import SwiftUI

@main
struct OmacyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Window("Preview", id: "preview") {
            PreviewViewRepresentable()
                .ignoresSafeArea()
        }
        .defaultSize(width: 960, height: 600)

        Window("Art", id: "config") {
            ConfigView()
        }
        .defaultSize(width: 560, height: 640)
    }
}
