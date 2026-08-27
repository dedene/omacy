import SwiftUI
import UniformTypeIdentifiers

struct PreviewViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> OmacyHostView { OmacyHostView() }
    func updateNSView(_ nsView: OmacyHostView, context: Context) { }
}

struct ConfigView: View {
    @State private var settings = OmacyStore.loadSettings()
    @State private var art = OmacyStore.loadArt()
    @State private var status = "Ready"
    @State private var importer = false

    var body: some View {
        Form {
            Section("Art") {
                TextEditor(text: $art)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                HStack {
                    Button("Restore default wordmark") {
                        art = OmacyStore.bundledArt
                        persist()
                    }
                    Button("Open PNG or SVG…") { importer = true }
                }
            }
            Section("Effect") {
                TextField("random or ttfx name", text: $settings.effect)
                ColorPicker(
                    "Background",
                    selection: Binding(
                        get: { color(from: settings.background) },
                        set: { settings.background = hex(from: $0) }
                    ),
                    supportsOpacity: false
                )
            }
            Section("Conversion") {
                Picker("Mode", selection: $settings.asciiMode) {
                    Text("Braille").tag("braille")
                    Text("Block").tag("block")
                }
                Stepper("Threshold \(settings.threshold)%", value: $settings.threshold, in: 0...100)
                Toggle("Invert", isOn: $settings.invert)
            }
            Section("Type") {
                Stepper("Font size \(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 8...48)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("Save") { persist() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 560)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.png, UTType(filenameExtension: "svg") ?? .xml]) { result in
            switch result {
            case .success(let url):
                convert(url)
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private func persist() {
        do {
            try OmacyStore.save(settings: settings, art: art)
            status = "Saved to App Group"
        } catch {
            status = error.localizedDescription
        }
    }

    private func convert(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            status = "Could not read file"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            status = "Could not read file"
            return
        }
        var cfg = OmacyAsciiConfig()
        cfg.mode = settings.asciiModeCode
        cfg.width = 80
        cfg.height = 26
        cfg.threshold = UInt8(settings.threshold)
        cfg.invert = settings.invert ? 1 : 0
        cfg.trim = 1
        var text: OpaquePointer?
        let statusCode = data.withUnsafeBytes { raw in
            omacy_ascii_from_bytes(&cfg, raw.bindMemory(to: UInt8.self).baseAddress, data.count, &text)
        }
        defer { omacy_text_free(text) }
        guard statusCode == OMACY_OK, let text, let ptr = omacy_text_utf8(text) else {
            status = "Conversion failed"
            return
        }
        let n = omacy_text_len(text)
        art = String(bytes: UnsafeBufferPointer(start: ptr, count: n).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? art
        persist()
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
