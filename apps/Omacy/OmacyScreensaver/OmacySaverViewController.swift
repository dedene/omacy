//
//  OmacySaverViewController.swift
//  OmacyScreensaver
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Main view controller for the screensaver. Specified as
//  ScreenSaverViewControllerClass in Info.plist as
//  `$(PRODUCT_MODULE_NAME).OmacySaverViewController`.
//
//  Mirrors Apple's Arabesque.appex pattern. Prefer loadView(forFrame:isPreview:)
//  so each display and the Settings preview get the real frame; loadView() is
//  the fallback when the framework only calls the NSViewController path.
//

import AppKit
import ScreenSaver

private let logger = AppexLog.logger("ViewController")

@objc(OmacySaverViewController)
class OmacySaverViewController: ScreenSaverViewController {

    /// Strong reference so the framework can't drop our view while we still own it.
    private var saverView: OmacySaverView?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        logger.info("init(nibName:bundle:)")
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        logger.info("init(coder:)")
        super.init(coder: coder)
    }

    deinit {
        logger.info("deinit")
    }

    override func loadView() {
        logger.info("loadView()")
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        installView(frame: frame, isPreview: frame.width < 400)
    }

    override func loadView(forFrame frame: NSRect, isPreview: Bool) {
        logger.info("loadView(forFrame: \(frame.size.width, privacy: .public)x\(frame.size.height, privacy: .public), isPreview: \(isPreview))")
        installView(frame: frame, isPreview: isPreview)
    }

    private func installView(frame: NSRect, isPreview: Bool) {
        let view = OmacySaverView(frame: frame, isPreview: isPreview)
        saverView = view
        self.view = view ?? NSView(frame: frame)
    }
}
