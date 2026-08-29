import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConfigView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var settings = OmacyStore.loadSettings()
    @State private var art = OmacyStore.loadArt()
    @State private var previewArt = OmacyStore.loadArt()
    @State private var highlighted = OmacyStore.loadSettings().effects.first
        ?? OmacyEffects.names[0]
    @State private var status = "Ready"
    @State private var importer = false
    @State private var confirmReset = false
    @State private var stagedImage: Data?
    @State private var reconvertTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            ShuffleList(included: $settings.effects, highlighted: $highlighted)
            Divider()
            ArtCanvasColumn(
                art: $art,
                previewArt: previewArt,
                highlighted: highlighted,
                settings: settings,
                background: canvasBackground,
                foreground: canvasForeground
            )
            Divider()
            inspector
                .frame(width: ArtMetrics.inspectorWidth)
        }
        .frame(minWidth: ArtMetrics.minWindowWidth, minHeight: ArtMetrics.minWindowHeight)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveAndClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            growWindowIfNeeded()
            if !OmacyEffects.names.contains(highlighted) {
                highlighted = settings.effects.first ?? OmacyEffects.names[0]
            }
            previewArt = art
        }
        .task { growWindowIfNeeded() }
        .onDisappear {
            reconvertTask?.cancel()
            previewTask?.cancel()
        }
        .onChange(of: settings.threshold) { _, _ in scheduleReconvert() }
        .onChange(of: settings.asciiMode) { _, _ in scheduleReconvert() }
        .onChange(of: settings.invert) { _, _ in scheduleReconvert() }
        .onChange(of: art) { _, new in schedulePreview(new) }
        .alert("Reset Art?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replace the current art with the Omarchy wordmark and restore all settings to their defaults.")
        }
        .fileImporter(
            isPresented: $importer,
            allowedContentTypes: [.png, UTType(filenameExtension: "svg") ?? .xml]
        ) { result in
            switch result {
            case .success(let url):
                convert(url)
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private var inspector: some View {
        Form {
            Section("Source") {
                Button("Open PNG or SVG…") { importer = true }
                Button("Reset…", role: .destructive) { confirmReset = true }
                    .disabled(isAtDefaults)
            }
            Section("Conversion") {
                Picker("Mode", selection: $settings.asciiMode) {
                    Text("Block").tag("block")
                    Text("Braille").tag("braille")
                }
                .pickerStyle(.segmented)
                LabeledContent("Threshold") {
                    Text("\(settings.threshold)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.threshold) },
                        set: { settings.threshold = Int($0.rounded()) }
                    ),
                    in: 0...100
                )
                .labelsHidden()
                .accessibilityLabel("Threshold")
                .accessibilityValue("\(settings.threshold) percent")
                Toggle("Invert", isOn: $settings.invert)
            }
            Section("Look") {
                ColorPicker(
                    "Background",
                    selection: Binding(
                        get: { color(from: settings.background) },
                        set: { settings.background = hex(from: $0) }
                    ),
                    supportsOpacity: false
                )
                Stepper(
                    "Font size \(Int(settings.fontSize)) pt",
                    value: $settings.fontSize,
                    in: 8...48
                )
            }
            if let error = OmacyStore.lastLoadError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            Section {
                if status != "Ready" {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
                Text("Effects by Terminal Text Effects (ChrisBuilds), Rust engine ttfx.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var canvasBackground: NSColor {
        let (r, g, b, a) = settings.backgroundRGBA
        return NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }

    private var canvasForeground: NSColor {
        let (r, g, b, _) = settings.backgroundRGBA
        let y = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
        return y > 0.55 ? .black : .white
    }

    private func growWindowIfNeeded() {
        DispatchQueue.main.async {
            guard let window = artWindow() else { return }
            ArtMetrics.growWindow(window, for: art)
        }
    }

    private func artWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "art" }
            ?? NSApp.windows.first { $0.title == "Art" }
    }

    private var isAtDefaults: Bool {
        settings == OmacySettings() && art == OmacyStore.bundledArt
    }

    @discardableResult
    private func persist(message: String = "Saved to App Group") -> Bool {
        do {
            settings.syncEngineEffect()
            try OmacyStore.save(settings: settings, art: art)
            status = message
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func saveAndClose() {
        reconvertTask?.cancel()
        guard persist() else { return }
        stagedImage = nil
        dismissWindow(id: "art")
    }

    private func resetToDefaults() {
        reconvertTask?.cancel()
        stagedImage = nil
        do {
            try OmacyStore.resetToDefaults()
            settings = OmacySettings()
            art = OmacyStore.bundledArt
            previewArt = art
            highlighted = settings.effects.first ?? OmacyEffects.names[0]
            status = "Reset to Omarchy wordmark"
            growWindowIfNeeded()
        } catch {
            status = error.localizedDescription
        }
    }

    private func scheduleReconvert() {
        guard stagedImage != nil else { return }
        reconvertTask?.cancel()
        reconvertTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            applyStagedConversion()
        }
    }

    private func convert(_ url: URL) {
        reconvertTask?.cancel()
        guard url.startAccessingSecurityScopedResource() else {
            status = "Could not read file"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            status = "Could not read file"
            return
        }
        stagedImage = data
        settings.asciiMode = "block"
        applyStagedConversion()
    }

    private func applyStagedConversion() {
        guard let data = stagedImage else { return }
        var cfg = OmacyAsciiConfig()
        cfg.mode = settings.asciiModeCode
        cfg.width = 80
        cfg.height = 26
        cfg.threshold = UInt8(settings.threshold)
        cfg.invert = settings.invert ? 1 : 0
        cfg.trim = 1
        var text: OpaquePointer?
        let statusCode = data.withUnsafeBytes { raw in
            omacy_ascii_from_bytes(
                &cfg,
                raw.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                &text
            )
        }
        defer { omacy_text_free(text) }
        guard statusCode == OMACY_OK, let text, let ptr = omacy_text_utf8(text) else {
            status = "Conversion failed"
            return
        }
        let n = omacy_text_len(text)
        art = String(
            bytes: UnsafeBufferPointer(start: ptr, count: n).map { UInt8(bitPattern: $0) },
            encoding: .utf8
        ) ?? art
        previewArt = art
        status = "Preview — Save to keep"
        growWindowIfNeeded()
    }

    private func schedulePreview(_ next: String) {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            previewArt = next
        }
    }

    private func color(from hex: String) -> Color {
        let t = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard t.count == 6, let n = UInt32(t, radix: 16) else { return .black }
        return Color(
            red: Double((n >> 16) & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double(n & 0xFF) / 255
        )
    }

    private func hex(from color: Color) -> String {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }
}
