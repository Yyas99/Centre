// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// A floating, Plasma-style taskbar: launcher, pinned and running apps, tray, clock and show-desktop.
#import "Centre.h"

@class CApp;
@interface CTaskbar : NSObject
- (instancetype)initWithApp:(CApp *)app;
- (void)apply;                                     // show, hide or reposition from config
- (NSArray<NSString *> *)pinnedPaths;
- (void)setPinnedPaths:(NSArray<NSString *> *)paths;
- (NSArray<NSString *> *)defaultPins;              // Finder plus the apps kept in the Dock
- (NSView *)snapshotView;                          // --snapshot: the bar rendered offscreen
- (void)restoreDockNow;                            // on quit: put your own Dock settings back
- (void)useSampleApps:(NSArray<NSString *> *)paths running:(NSArray<NSString *> *)running active:(NSString *)active;   // README shots
@end
