import SwiftUI

struct PreviewViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> OmacyHostView { OmacyHostView() }

    func updateNSView(_ nsView: OmacyHostView, context: Context) {
        nsView.refreshGeometry()
    }
}
