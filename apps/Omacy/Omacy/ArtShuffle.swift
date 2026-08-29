import SwiftUI
import AppKit

struct ShuffleList: View {
    @Binding var included: [String]
    @Binding var highlighted: String

    private var selectedCount: Int {
        included.filter { OmacyEffects.names.contains($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effects in the shuffle:")
                .font(.subheadline.weight(.semibold))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(OmacyEffects.names, id: \.self) { name in
                        HStack(spacing: 8) {
                            Toggle("", isOn: includeBinding(name))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .accessibilityLabel(name)
                            Text(name)
                                .font(.body.monospaced())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(highlighted == name ? Color.accentColor : Color.clear)
                        .foregroundStyle(highlighted == name ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = name }
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            )
            HStack(spacing: 8) {
                Button("All") { included = OmacyEffects.names }
                Button("None") { soloHighlighted() }
                Text("\(selectedCount) of \(OmacyEffects.names.count) selected")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: ArtMetrics.listWidth)
    }

    private func includeBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { included.contains(name) },
            set: { on in
                if on {
                    if !included.contains(name) { included.append(name) }
                } else if included.count > 1 {
                    included.removeAll { $0 == name }
                }
            }
        )
    }

    private func soloHighlighted() {
        let keep = OmacyEffects.names.contains(highlighted) ? highlighted : OmacyEffects.names[0]
        included = [keep]
        highlighted = keep
    }
}

struct ArtCanvasColumn: View {
    @Binding var art: String
    var previewArt: String
    var highlighted: String
    var settings: OmacySettings
    var background: NSColor
    var foreground: NSColor

    var body: some View {
        GeometryReader { geo in
            let captionH = ArtMetrics.captionHeight
            let minEditor = ArtMetrics.minEditorHeight
            let idealPreview = geo.size.width * 9 / 16
            let maxPreview = max(120, geo.size.height - minEditor - captionH)
            let previewH = min(idealPreview, maxPreview)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Art — editable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ArtEditor(text: $art, background: background, foreground: foreground)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(.separator, lineWidth: 1)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .frame(height: geo.size.height - previewH - captionH)

                ZStack {
                    Color.black
                    EffectPreviewRepresentable(
                        art: previewArt,
                        effect: highlighted,
                        settings: settings
                    )
                    .aspectRatio(16 / 9, contentMode: .fit)
                }
                .frame(height: previewH)
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Text("Live preview of \(highlighted) — loops, does not shuffle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: captionH)
            }
        }
    }
}

struct EffectPreviewRepresentable: NSViewRepresentable {
    var art: String
    var effect: String
    var settings: OmacySettings

    func makeNSView(context: Context) -> OmacyHostView {
        let view = OmacyHostView()
        view.pin(art: art, effect: effect, background: settings.background, fontSize: settings.fontSize)
        return view
    }

    func updateNSView(_ view: OmacyHostView, context: Context) {
        view.pin(art: art, effect: effect, background: settings.background, fontSize: settings.fontSize)
    }
}
