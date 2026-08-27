//
//  PreviewViewRepresentable.swift
//  Omacy
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  SwiftUI wrapper that lets the host app embed the AppKit-based PreviewView
//  inside a SwiftUI Window.
//

import SwiftUI

struct PreviewViewRepresentable: NSViewRepresentable {

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ nsView: PreviewView, context: Context) { }
}
