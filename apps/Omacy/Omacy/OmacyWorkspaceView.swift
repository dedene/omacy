import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OmacyImagePasteAction: Equatable {
    case importImage
    case forwardTextPaste
    case unavailable

    static func resolve(isEditingArt: Bool, hasImage: Bool) -> Self {
        if isEditingArt { return .forwardTextPaste }
        return hasImage ? .importImage : .unavailable
    }
}

struct OmacyWorkspaceSystemActions: Equatable {
    let showsInstall: Bool
    let installEnabled: Bool
    let previewEnabled: Bool
    let saveEnabled: Bool

    init(
        showsInstall: Bool,
        installEnabled: Bool,
        previewEnabled: Bool,
        saveEnabled: Bool = false
    ) {
        self.showsInstall = showsInstall
        self.installEnabled = installEnabled
        self.previewEnabled = previewEnabled
        self.saveEnabled = saveEnabled
    }

    static func resolve(
        isInstalled: Bool,
        hasRegistrationConflict: Bool,
        isBusy: Bool,
        hasDraftConflict: Bool,
        hasInvalidFiles: Bool = false,
        isDirty: Bool = false
    ) -> Self {
        // Saving over invalid files is refused, so the button stays off until
        // the user replaces them explicitly.
        let saveEnabled = isDirty && !isBusy && !hasInvalidFiles
        if hasRegistrationConflict {
            return .init(
                showsInstall: false, installEnabled: false, previewEnabled: false,
                saveEnabled: saveEnabled
            )
        }
        return .init(
            showsInstall: !isInstalled,
            installEnabled: !isInstalled && !isBusy,
            previewEnabled: isInstalled && !isBusy && !hasDraftConflict && !hasInvalidFiles,
            saveEnabled: saveEnabled
        )
    }
}

struct OmacyWorkspaceView: View {
    @ObservedObject var model: OmacyWorkspaceModel
    @ObservedObject var pluginManager: PluginManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var importer = false
    @State private var confirmReset = false
    @State private var detailsExpanded = false
    @State private var importError: String?
    @State private var isEditingArt = false

    private var systemActions: OmacyWorkspaceSystemActions {
        .resolve(
            isInstalled: pluginManager.isCurrentExtensionInstalled,
            hasRegistrationConflict: pluginManager.hasConflictingRegistrations,
            isBusy: model.isBusy || pluginManager.isLoading,
            hasDraftConflict: model.operationState == .externalConflict,
            hasInvalidFiles: model.hasInvalidFiles,
            isDirty: model.isDirty
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            readinessStrip
            Divider()
            HStack(spacing: 0) {
                ShuffleList(included: settingsBinding(\.effects), highlighted: $model.highlightedEffect)
                Divider()
                ArtCanvasColumn(
                    art: artBinding, isEditingArt: $isEditingArt,
                    previewArt: model.editor.draftArt,
                    highlighted: model.highlightedEffect, settings: model.editor.draftSettings,
                    background: canvasBackground, foreground: canvasForeground
                )
                Divider()
                inspector.frame(width: ArtMetrics.inspectorWidth)
            }
        }
        .frame(minWidth: ArtMetrics.minWindowWidth, minHeight: ArtMetrics.minWindowHeight)
        .onAppear { enforceWindowMinimumOnNextRunLoop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) {
            enforceWindowMinimum(from: $0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            enforceWindowMinimum(from: $0)
        }
        .background(OmacyWindowCloseGuard(
            isDirty: model.isDirty,
            save: { await model.save() },
            discard: { model.discardDraft() }
        ).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Screen Saver Settings…", action: openScreenSaverSettings)
                    .help("Open macOS Screen Saver settings")
                Button("Save") { Task { await model.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!systemActions.saveEnabled)
                    .help(model.hasInvalidFiles
                          ? "Replace Omacy’s invalid files before saving"
                          : "Write the current draft to ~/.config/omacy")
                if systemActions.showsInstall {
                    Button("Install") { install() }
                        .disabled(!systemActions.installEnabled)
                        .help("Register Omacy’s screen saver extension with macOS")
                }
                Button("Preview") { Task { await model.testScreenSaver() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!systemActions.previewEnabled)
                    .help(previewHelp)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshFromDisk()
            pluginManager.checkInstallationStatus()
            pluginManager.checkScreensaverStatus()
        }
        .onChange(of: model.editor.draftSettings.threshold) { _, _ in model.reconvertStagedImage() }
        .onChange(of: model.editor.draftSettings.asciiMode) { _, _ in model.reconvertStagedImage() }
        .onChange(of: model.editor.draftSettings.invert) { _, _ in model.reconvertStagedImage() }
        .alert("Reset Art and Settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current draft with Omacy’s defaults. Save to apply it to the screen saver.")
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.png, UTType(filenameExtension: "svg") ?? .xml]) { result in
            switch result {
            case .success(let url): importImage(url)
            case .failure(let error as CocoaError) where error.code == .userCancelled: break
            case .failure: importError = "The image couldn’t be opened. Choose the PNG or SVG again."
            }
        }
    }

    @ViewBuilder private var readinessStrip: some View {
        if let importError {
            statusBar(icon: "exclamationmark.triangle.fill", title: "Import failed", detail: importError, color: .red) {
                Button("Choose Again…") { self.importError = nil; importer = true }
            }
        } else if let conversionError = model.conversionError {
            statusBar(icon: "exclamationmark.triangle.fill", title: "Conversion failed", detail: conversionError, color: .red) {
                Button("Choose Again…") { model.dismissConversionError(); importer = true }
                Button("OK") { model.dismissConversionError() }
            }
        } else { switch model.operationState {
        case .externalConflict:
            statusBar(icon: "arrow.triangle.2.circlepath", title: "Files changed outside Omacy", detail: "Choose which version to keep.", color: .orange) {
                Button("Use File Changes") { model.reloadExternal() }
                    .help("Replace this draft with the version currently stored in the Omacy files.")
                Button("Keep My Changes") { Task { await model.overwriteMine() } }
                    .help("Save this draft over the version currently stored in the Omacy files.")
            }
        case .invalidFiles(let message):
            statusBar(
                icon: "exclamationmark.triangle.fill",
                title: "Omacy can’t read its saved files",
                detail: "Showing your last saved version. Saving is paused until you replace the files.",
                color: .orange
            ) { replaceFilesButton }
                .help(message)
        case .error(let message):
            statusBar(icon: "exclamationmark.triangle.fill", title: "Needs attention", detail: message, color: .red) {
                if model.hasInvalidFiles { replaceFilesButton }
            }
        case .working(let message):
            statusBar(icon: "hourglass", title: message, detail: nil, color: .accentColor) { ProgressView().controlSize(.small) }
        case .idle:
            if pluginManager.hasConflictingRegistrations {
                statusBar(icon: "exclamationmark.triangle.fill", title: "Multiple copies are registered", detail: "Repair registration before testing.", color: .orange) {
                    Button("Repair") { repair() }.disabled(pluginManager.isLoading)
                }
            } else if let message = pluginManager.lastError ?? pluginManager.screensaverError {
                statusBar(icon: "exclamationmark.triangle.fill", title: "Setup failed", detail: message, color: .red)
            } else if pluginManager.isCurrentExtensionInstalled {
                if pluginManager.currentDisplayStatus.isActiveOnAllCurrentDisplays {
                    statusBar(icon: "checkmark.circle.fill", title: "Installed", detail: "Preview opens the real macOS screen saver.", color: .green)
                } else {
                    statusBar(icon: "checkmark.circle.fill", title: "Installed", detail: "Preview will select Omacy on every display, then start it.", color: .green)
                }
            } else {
                statusBar(icon: "arrow.down.app.fill", title: "Installation required", detail: "Install Omacy to enable Preview.", color: .secondary)
            }
        } }
    }

    private var replaceFilesButton: some View {
        Button("Replace Files") { Task { await model.replaceInvalidFiles() } }
            .disabled(model.isBusy)
            .help("Overwrites both settings.json and screensaver.txt in ~/.config/omacy with what you see here.")
    }

    private func statusBar<Actions: View>(icon: String, title: String, detail: String?, color: Color, @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
                Text(title).fontWeight(.semibold)
                if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            actions()
        }
        .padding(.horizontal, 16).frame(minHeight: 44)
    }

    private var inspector: some View {
        Form {
            Section("Source") {
                Button("Open PNG or SVG…") { importer = true }
                Button("Paste Image") { pasteImage(showEmptyClipboardError: true) }
                Button("Reset…", role: .destructive) { confirmReset = true }
                    .disabled(!model.canReset)
            }
            Section("Conversion") {
                Picker("Mode", selection: settingsBinding(\.asciiMode)) {
                    Text("Block").tag("block")
                    Text("Braille").tag("braille")
                }.pickerStyle(.segmented)
                LabeledContent("Threshold", value: "\(model.editor.draftSettings.threshold)%")
                Slider(value: thresholdBinding, in: 0...100)
                    .accessibilityLabel("Threshold")
                    .accessibilityValue("\(model.editor.draftSettings.threshold) percent")
                Toggle("Invert", isOn: settingsBinding(\.invert))
            }
            Section("Look") {
                ColorPicker("Background", selection: backgroundBinding, supportsOpacity: false)
                Stepper("Font size \(Int(model.editor.draftSettings.fontSize)) pt", value: settingsBinding(\.fontSize), in: 8...OmacySettingsCodec.maximumFontSize)
            }
            Section { DisclosureGroup("Details", isExpanded: $detailsExpanded) { systemDetails } }
            Section {
                Text("Effects by Terminal Text Effects (ChrisBuilds), Rust engine ttfx.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .background {
            Button("Paste Image from Clipboard") { handlePasteShortcut() }
                .keyboardShortcut("v", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var systemDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Extension", value: pluginManager.isInstalled ? "Registered" : "Not registered")
            LabeledContent("Displays", value: displayStatusText)
            if let version = pluginManager.installedVersion { LabeledContent("Version", value: "v\(version)") }
            if let path = pluginManager.installedPath {
                LabeledContent("Path") { Text(path).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
            }
            if pluginManager.hasConflictingRegistrations {
                ForEach(pluginManager.registeredPaths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                Button("Repair Registration") { repair() }.disabled(pluginManager.isLoading)
            }
            if pluginManager.isInstalled {
                Button("Uninstall", role: .destructive) { Task { try? await pluginManager.uninstall() } }
                    .disabled(pluginManager.isLoading)
            }
        }
    }

    private var artBinding: Binding<String> { Binding(get: { model.editor.draftArt }, set: { model.editor.draftArt = $0 }) }
    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<OmacySettings, Value>) -> Binding<Value> {
        Binding(get: { model.editor.draftSettings[keyPath: keyPath] }, set: { model.editor.draftSettings[keyPath: keyPath] = $0 })
    }
    private var thresholdBinding: Binding<Double> {
        Binding(get: { Double(model.editor.draftSettings.threshold) }, set: { model.editor.draftSettings.threshold = Int($0.rounded()) })
    }
    private var backgroundBinding: Binding<Color> {
        Binding(get: { color(from: model.editor.draftSettings.background) }, set: { model.editor.draftSettings.background = hex(from: $0) })
    }
    private var canvasBackground: NSColor {
        let (r, g, b, a) = model.editor.draftSettings.backgroundRGBA
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
    private var canvasForeground: NSColor {
        let (r, g, b, _) = model.editor.draftSettings.backgroundRGBA
        return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) > 140 ? .black : .white
    }
    private func importImage(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            importError = "Omacy couldn’t access that file. Choose it again to grant access."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            model.importImage(try Data(contentsOf: url))
            importError = nil
        } catch {
            importError = "The image couldn’t be read. Check the file, then choose it again."
        }
    }
    private func handlePasteShortcut() {
        let pasteboard = NSPasteboard.general
        switch OmacyImagePasteAction.resolve(
            isEditingArt: isEditingArt,
            hasImage: clipboardImageData(from: pasteboard) != nil
        ) {
        case .importImage:
            pasteImage(showEmptyClipboardError: false)
        case .forwardTextPaste:
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.paste(nil)
        case .unavailable:
            break
        }
    }
    private func pasteImage(showEmptyClipboardError: Bool) {
        guard let data = clipboardImageData(from: .general) else {
            if showEmptyClipboardError {
                importError = "The clipboard doesn’t contain an image. Copy a screenshot or image, then try again."
            }
            return
        }
        model.importImage(data)
        importError = nil
    }
    private func clipboardImageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    private func repair() { Task { try? await pluginManager.repairRegistration() } }
    private func install() { Task { try? await pluginManager.install() } }
    private var previewHelp: String {
        pluginManager.isCurrentExtensionInstalled
            ? "Save pending changes and open the real macOS screen saver (⌘↩)"
            : "Install Omacy before previewing the screen saver"
    }
    private func openScreenSaverSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver") else { return }
        NSWorkspace.shared.open(url)
    }

    private func enforceWindowMinimumOnNextRunLoop() {
        DispatchQueue.main.async {
            guard let window = OmacyWindowSizing.workspaceWindow(in: NSApp) else { return }
            OmacyWindowSizing.enforce(on: window)
        }
    }

    private func enforceWindowMinimum(from notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == "Omacy",
              window.isVisible,
              window.screen != nil,
              window.styleMask.contains(.titled),
              window.level == .normal else { return }
        OmacyWindowSizing.enforce(on: window)
    }

    private var displayStatusText: String {
        switch pluginManager.currentDisplayStatus {
        case .activeOnAll(let count) where count == 0,
             .inactive(let count) where count == 0:
            return "Checking display status…"
        case .activeOnAll(let count): return "Active on all \(count)"
        case .activeOnSome(let active, let total): return "Active on \(active) of \(total)"
        case .inactive(let count): return "Inactive on all \(count)"
        }
    }

    private func color(from hex: String) -> Color {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return .black }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private func hex(from color: Color) -> String {
        let native = NSColor(color)
        guard let rgb = native.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255)
        )
    }
}
