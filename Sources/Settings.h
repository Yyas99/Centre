// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Centre.h"

@class CApp;
@interface CSettings : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow *window;
- (instancetype)initWithApp:(CApp *)app;
- (void)show;
- (void)showPage:(NSInteger)i;
@end

