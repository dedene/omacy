import AppKit
import XCTest
@testable import Omacy

final class OmacyAppRouteTests: XCTestCase {
    func testArtEditorHeightIsCompactButRespectsSmallWindows() {
        XCTAssertEqual(ArtMetrics.editorHeight(availableHeight: 700), 220)
        XCTAssertEqual(ArtMetrics.editorHeight(availableHeight: 180), 148)
    }

    func testImagePasteShortcutPreservesTextEditing() {
        XCTAssertEqual(
            OmacyImagePasteAction.resolve(isEditingArt: true, hasImage: true),
            .forwardTextPaste
        )
        XCTAssertEqual(
            OmacyImagePasteAction.resolve(isEditingArt: false, hasImage: true),
            .importImage
        )
        XCTAssertEqual(
            OmacyImagePasteAction.resolve(isEditingArt: false, hasImage: false),
            .unavailable
        )
    }

    func testWindowSizingGrowsUndersizedFrameFromTopLeft() {
        let frame = NSRect(x: 50, y: 100, width: 919, height: 678)
        let grown = OmacyWindowSizing.grownFrame(frame)
        XCTAssertEqual(grown.size, NSSize(width: 1020, height: 700))
        XCTAssertEqual(grown.minX, frame.minX)
        XCTAssertEqual(grown.maxY, frame.maxY)
    }

    func testWindowSizingPreservesLargerFrame() {
        let frame = NSRect(x: 20, y: 30, width: 1280, height: 840)
        XCTAssertEqual(OmacyWindowSizing.grownFrame(frame), frame)
    }

    func testWorkspaceWindowIdentityPrefersMainIdentifierWithTitleFallback() {
        XCTAssertTrue(OmacyWindowSizing.isWorkspaceIdentity(title: "Different title", identifier: "SwiftUI.main"))
        XCTAssertTrue(OmacyWindowSizing.isWorkspaceIdentity(title: "Omacy", identifier: nil))
    }

    func testWorkspaceWindowIdentityRejectsUpdaterAndAlertWindows() {
        XCTAssertFalse(OmacyWindowSizing.isWorkspaceIdentity(title: "Software Update", identifier: "sparkle"))
        XCTAssertFalse(OmacyWindowSizing.isWorkspaceIdentity(title: "Save changes?", identifier: nil))
    }

    func testLegacyArtHostRoutesToWorkspace() throws {
        XCTAssertEqual(OmacyAppRoute.parse(try XCTUnwrap(URL(string: "omacy://art"))), .workspace)
    }

    func testLegacyArtPathRoutesToWorkspace() throws {
        XCTAssertEqual(OmacyAppRoute.parse(try XCTUnwrap(URL(string: "omacy:///art"))), .workspace)
    }

    func testUnknownAndForeignURLsAreIgnored() throws {
        XCTAssertNil(OmacyAppRoute.parse(try XCTUnwrap(URL(string: "omacy://settings"))))
        XCTAssertNil(OmacyAppRoute.parse(try XCTUnwrap(URL(string: "https://example.com/art"))))
    }

    func testLegacyArgumentIsRecognizedExactly() {
        XCTAssertTrue(OmacyAppRoute.containsLegacyArtArgument(["Omacy", "--art"]))
        XCTAssertFalse(OmacyAppRoute.containsLegacyArtArgument(["Omacy", "--artist"]))
    }

    func testSystemActionsSeparateInstallFromPreview() {
        XCTAssertEqual(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: false,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: false
            ),
            .init(showsInstall: true, installEnabled: true, previewEnabled: false)
        )
        XCTAssertEqual(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: false
            ),
            .init(showsInstall: false, installEnabled: false, previewEnabled: true)
        )
    }

    func testSystemActionsBlockPreviewDuringConflictsAndWork() {
        XCTAssertEqual(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: true,
                isBusy: false,
                hasDraftConflict: false
            ),
            .init(showsInstall: false, installEnabled: false, previewEnabled: false)
        )
        XCTAssertFalse(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: true,
                hasDraftConflict: false
            ).previewEnabled
        )
        XCTAssertFalse(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: true
            ).previewEnabled
        )
        XCTAssertFalse(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: false,
                hasInvalidFiles: true
            ).previewEnabled
        )
    }

    func testSaveIsEnabledOnlyForACleanDirtyDraft() {
        XCTAssertTrue(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: false,
                isDirty: true
            ).saveEnabled
        )
        XCTAssertFalse(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: false,
                hasInvalidFiles: true,
                isDirty: true
            ).saveEnabled
        )
        XCTAssertFalse(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: true,
                hasDraftConflict: false,
                isDirty: true
            ).saveEnabled
        )
        XCTAssertFalse(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: false,
                isBusy: false,
                hasDraftConflict: false,
                isDirty: false
            ).saveEnabled
        )
        // A registration conflict blocks install and preview, never saving the draft.
        XCTAssertTrue(
            OmacyWorkspaceSystemActions.resolve(
                isInstalled: true,
                hasRegistrationConflict: true,
                isBusy: false,
                hasDraftConflict: false,
                isDirty: true
            ).saveEnabled
        )
    }
}
