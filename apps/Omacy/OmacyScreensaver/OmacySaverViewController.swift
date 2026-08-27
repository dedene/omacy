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
//  Mirrors Apple's Arabesque.appex pattern: only override the standard
//  init(nibName:bundle:), init(coder:), and loadView(); let the framework
//  drive everything else.
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

    /// Called by the framework to create the view.
    override func loadView() {
        logger.info("loadView()")

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let isPreview = frame.width < 400

        let view = OmacySaverView(frame: frame, isPreview: isPreview)
        saverView = view
        self.view = view ?? NSView(frame: frame)
    }
}
