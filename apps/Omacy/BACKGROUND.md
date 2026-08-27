# macOS Appex Screensaver — Technical Background

This document captures what's known about developing screensavers for macOS Sonoma and later using the modern ExtensionKit (`.appex`) format. It is meant as a companion to the sample code in this repository.

---

## 1. Architecture

### `.appex` vs. legacy `.saver`

Modern macOS (Sonoma+) supports screensavers packaged as ExtensionKit `.appex` bundles in addition to the legacy `.saver` plug-in format. Apple's own first-party savers (Hello, Arabesque, Drift, Monterey, Ventura, Shell, Flurry) all use the appex format.

| | `.appex` | `.saver` |
|---|---|---|
| **Bundle type** | `CFBundlePackageType = XPC!` | `CFBundlePackageType = BNDL` |
| **Process model** | Separate sandboxed XPC process | Loaded into `legacyScreenSaver.appex` |
| **Framework** | `ScreenSaver.framework` + ExtensionKit | `ScreenSaver.framework` |
| **Min macOS** | 14.0 (Sonoma) | All supported macOS |
| **Distribution** | Embedded inside a host `.app`, registered via `pluginkit` | Standalone `.saver` file |

### Extension Point

- **Identifier:** `com.apple.screensaver`
- **Version:** `1.0`

### Process Isolation

Each appex screensaver runs in its own sandboxed process. The framework handles all inter-process communication via XPC; you don't write XPC code yourself. View rendering, input events, and lifecycle messages all flow through the framework transparently.

---

## 2. Class Hierarchy

### Public API (`ScreenSaver.framework`)

| Class | Purpose |
|-------|---------|
| `ScreenSaverView` | Your main view. NSView subclass with `animateOneFrame()`, `startAnimation()`, `stopAnimation()`, `draw(_:)`. |
| `ScreenSaverDefaults` | `UserDefaults` subclass for screensaver preferences. |

### ExtensionKit classes used by appex screensavers

These are still partly underdocumented; their declarations live in `OmacyScreensaver/PrivateHeaders/ScreenSaverPrivate.h` in this repo. On recent SDKs the symbols are also available without the bridging header.

| Class | Purpose |
|-------|---------|
| `ScreenSaverExtension` | Principal class. Set as `NSExtensionPrincipalClass` in Info.plist. |
| `ScreenSaverViewController` | View controller managing the screensaver view. Set as `ScreenSaverViewControllerClass` in Info.plist. |
| `ScreenSaverConfigurationViewController` | Base class for the optional configuration sheet. |

---

## 3. Info.plist Configuration

### `NSExtension` dictionary

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.screensaver</string>
    <key>NSExtensionPointVersion</key>
    <string>1.0</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).YourScreenSaverExtension</string>
</dict>
```

### Root-level screensaver keys

| Key | Type | Description |
|-----|------|-------------|
| `ScreenSaverViewControllerClass` | String | Fully-qualified name of the main view controller. |
| `ScreenSaverConfigurationSheetViewControllerClass` | String | Fully-qualified name of the configuration sheet controller. |
| `SSEHasConfigureSheet` | Boolean | Whether the screensaver has a configuration UI. |
| `SSENeedsAnimationTimer` | Boolean | Whether the framework should drive a per-frame animation timer (see §5). |

Use `$(PRODUCT_MODULE_NAME).ClassName` so the module prefix tracks your target name automatically.

---

## 4. Apple's Built-in Screensavers (Reference)

Located in `/System/Library/ExtensionKit/Extensions/`.

| Name | Principal Class | View Controller | Has Config |
|------|-----------------|-----------------|------------|
| Arabesque | `Arabesque.ArabesqueExtension` | `ArabesqueViewController` | No |
| Flurry | `Flurry.FlurryExtension` | `FlurryViewController` | Yes |
| Drift | `Drift.FlowExtension` | `FlowViewController` | Yes |
| Hello | `Hello.HelloExtension` | `HelloViewController` | Yes |
| Monterey | `Monterey.CanyonExtension` | `CanyonViewController` | No |
| Ventura | `Ventura.PetalExtension` | `PetalViewController` | No |
| Shell | `Shell.ShellExtension` | `ShellViewController` | No |

**Naming conventions** Apple uses:

- Principal class: `Module.ModuleExtension` (e.g. `Arabesque.ArabesqueExtension`)
- View controller: `ModuleViewController`
- View class: `Module.ModuleView`

---

## 5. Rendering: three valid approaches

There is no single "right" way to render an appex screensaver. Pick whichever fits your animation model.

### A. Direct CALayer animation (what this sample uses)

Manipulate the backing CALayer directly — either with `CABasicAnimation` (Aerial's fallback and this sample's `OmacyCanaryAnimator`) or with your own `Timer` updating layer properties. Set `SSENeedsAnimationTimer = false` because the layer or your timer drives frames itself.

```swift
class YourScreenSaverView: ScreenSaverView {
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let layer = self.layer, window != nil else { return }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = NSColor.red.cgColor
        animation.toValue = NSColor.blue.cgColor
        animation.duration = 2.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "demo")
    }
}
```

### B. Traditional `ScreenSaverView` overrides

Override `startAnimation()`, `stopAnimation()`, `animateOneFrame()`, and `draw(_:)`. These **do** get called by the framework when `SSENeedsAnimationTimer = true`; they're the same calls a `.saver` plug-in would receive.

```swift
class YourScreenSaverView: ScreenSaverView {
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
    }

    override func animateOneFrame() {
        super.animateOneFrame()
        // Update model state, then trigger a redraw:
        setNeedsDisplay(bounds)
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        // ...your drawing here...
    }
}
```

### C. SwiftUI via `NSHostingView`

You can host SwiftUI inside an appex screensaver by wrapping your SwiftUI root view in `NSHostingView` and adding it as a subview of the `ScreenSaverView`. The [Aerial](https://github.com/AerialScreensaver/Aerial) screensaver uses this pattern for weather, music, and clock overlays painted on top of its video player.

```swift
import SwiftUI

class YourScreenSaverView: ScreenSaverView {
    private var hosting: NSHostingView<YourSwiftUIView>?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true

        let host = NSHostingView(rootView: YourSwiftUIView())
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = host
    }
}
```

Note that SwiftUI is hosted *inside* the `ScreenSaverView`; it is not the principal class. The principal class must still be a `ScreenSaverExtension` subclass.

### View controller setup

The view controller overrides `loadView()` to instantiate and assign the screensaver view:

```swift
@objc(YourViewController)
class YourViewController: ScreenSaverViewController {
    override func loadView() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let isPreview = frame.width < 400
        self.view = YourScreenSaverView(frame: frame, isPreview: isPreview)
            ?? NSView(frame: frame)
    }
}
```

---

## 6. Registration and Discovery

### Using `pluginkit`

```bash
# Register an appex
pluginkit -a /path/to/YourScreensaver.app/Contents/PlugIns/YourScreensaver.appex

# List all registered screensavers
pluginkit -m -v -p com.apple.screensaver

# Unregister
pluginkit -r /path/to/YourScreensaver.appex
```

In production the appex must be embedded inside an application bundle:

```
YourApp.app/Contents/PlugIns/YourScreensaver.appex
```

You typically ship the host app to `/Applications/`, and macOS picks the appex up automatically (or your host app calls `pluginkit -a` on first launch, as this sample does in `PluginManager.swift`).

---

## 7. Thumbnails

### Required dimensions

System Settings displays screensaver thumbnails at a specific landscape aspect ratio. Square images won't appear.

| Scale | Dimensions |
|-------|------------|
| 1x | 107 × 65 |
| 2x | 214 × 130 |

### Asset catalog setup

Place thumbnails in an asset catalog imageset named `thumbnail`:

```
Assets.xcassets/
└── thumbnail.imageset/
    ├── Contents.json
    ├── thumbnail.png      (107 × 65)
    └── thumbnail@2x.png   (214 × 130)
```

`Contents.json`:

```json
{
  "images": [
    { "filename": "thumbnail.png",    "idiom": "universal", "scale": "1x" },
    { "filename": "thumbnail@2x.png", "idiom": "universal", "scale": "2x" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

Some Apple screensavers ship both explicit PNGs in `Resources/` and entries inside the compiled `Assets.car`; the explicit PNGs appear to take priority when present.

### Caching

macOS caches screensaver thumbnails aggressively. If yours doesn't appear after changes:

1. Rebuild and re-register: `pluginkit -a /path/to/Extension.appex`
2. Close and reopen System Settings
3. Log out and back in if the cached version persists

---

## References

- `ScreenSaver.framework` headers in the macOS SDK
- Apple's built-in screensaver extensions at `/System/Library/ExtensionKit/Extensions/`
- ExtensionKit documentation in the Xcode SDK
- [Aerial](https://github.com/AerialScreensaver/Aerial) — full appex screensaver using approaches A and C together
- [ScreenSaverMinimal](https://github.com/AerialScreensaver/ScreenSaverMinimal) — same author's sample for the legacy `.saver` format
