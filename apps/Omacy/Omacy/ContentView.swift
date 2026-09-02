import SwiftUI

struct ContentView: View {
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var workspace: OmacyWorkspaceModel

    var body: some View {
        OmacyWorkspaceView(model: workspace, pluginManager: pluginManager)
    }
}
