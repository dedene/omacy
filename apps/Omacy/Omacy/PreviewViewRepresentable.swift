import SwiftUI

struct PreviewViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.refreshGeometry()
    }
}
