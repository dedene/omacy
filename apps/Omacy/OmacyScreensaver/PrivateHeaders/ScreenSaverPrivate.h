//
//  ScreenSaverPrivate.h
//  AppexSaverExtension
//
//  Private API declarations for macOS screensaver extensions.
//  These classes exist in ScreenSaver.framework but are not publicly declared.
//  Discovered via reverse engineering Apple's screensaver appex bundles.
//

#import <ScreenSaver/ScreenSaver.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - ScreenSaverExtension

/// Principal class for modern screensaver app extensions.
/// Subclass this and specify it as NSExtensionPrincipalClass in Info.plist.
@interface ScreenSaverExtension : NSObject

- (instancetype)init;

@end

#pragma mark - ScreenSaverViewController

/// Main view controller for screensaver animation.
/// Specify your subclass name as ScreenSaverViewControllerClass in Info.plist.
@interface ScreenSaverViewController : NSViewController

/// The ScreenSaverView that provides the animation.
@property (nonatomic, weak, nullable) ScreenSaverView *representedView;

/// Whether the screensaver is currently animating.
@property (nonatomic, getter=isAnimating) BOOL animating;

/// Called to create the view for the given frame.
/// Swift name: loadView(forFrame:isPreview:)
- (void)loadViewForFrame:(NSRect)frame isPreview:(BOOL)isPreview NS_SWIFT_NAME(loadView(forFrame:isPreview:));

@end

#pragma mark - ScreenSaverConfigurationViewController

/// View controller for the screensaver configuration sheet.
/// Subclass this if SSEHasConfigureSheet is true in Info.plist.
@interface ScreenSaverConfigurationViewController : NSViewController

@end

NS_ASSUME_NONNULL_END
