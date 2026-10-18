// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Centre.h"

@interface CPanel : NSPanel @end
@interface CBackdrop : NSView @end
@interface CHairline : NSView @end
@interface CEdgeView : NSView @end
@interface CFooterBar : NSView @end
@interface CChip : NSView
@property (nonatomic, copy) NSString *text;
- (CGFloat)fittingWidth;
@end
@interface CKeyHints : NSView
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *hints;   // @[@[label, key1, key2…], …]
@end
@interface CRowView : NSView
@property (nonatomic) BOOL selected;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *titleLabel, *kindLabel;
@property (nonatomic) CGFloat iconSize;          // 26 in results, 22 in the compact home lists
@property (nonatomic) NSInteger globalIndex;     // position in CApp.items (home lists)
- (void)setTitle:(NSString *)t subtitle:(NSString *)s;
- (void)setKind:(NSString *)kind shortcut:(NSString *)shortcut;
@end
@interface CGridView : NSView
@property (nonatomic, strong) NSArray<CItem *> *items;
@property (nonatomic) NSInteger selected;
@property (nonatomic) BOOL showShortcuts;   // ⌘ held: labels become ⌘1…⌘8
@property (nonatomic, copy) void (^onPick)(NSInteger);
@property (nonatomic, copy) void (^onHover)(NSInteger);
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@property (nonatomic, copy) NSImage *(^iconFor)(CItem *);
- (void)reload;
@end
@interface CQuickStrip : NSView
@property (nonatomic, strong) NSArray<CItem *> *items;
@property (nonatomic) NSInteger selected;            // local index, -1 = none
@property (nonatomic, copy) void (^onPick)(NSInteger);
@property (nonatomic, copy) void (^onHover)(NSInteger);
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@end
@interface CHomeList : NSView
@property (nonatomic, strong) NSArray *entries;      // NSString = section header, CItem = row
@property (nonatomic) NSInteger base;                // CApp.items index of the first row
@property (nonatomic) NSInteger selected;            // CApp.items index
@property (nonatomic, copy) NSImage *(^iconFor)(CItem *);
@property (nonatomic, copy) void (^onPick)(NSInteger);
@property (nonatomic, copy) void (^onHover)(NSInteger);
@property (nonatomic, strong) NSTrackingArea *hoverArea;
- (void)reload;
- (CGFloat)fittingHeight;
@end
@interface CMediaView : NSView
@property (nonatomic, strong) NSImageView *art;
@property (nonatomic, strong) NSTextField *titleL, *subL, *elapsedL, *remainL;
@property (nonatomic, strong) NSButton *prevB, *playB, *nextB;
@property (nonatomic) double progress;          // 0…1, negative hides the bar and times
@property (nonatomic) double duration;
@property (nonatomic) BOOL scrubbing, hoverBar;
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@property (nonatomic, copy) void (^onCommand)(int);
@property (nonatomic, copy) void (^onSeek)(double fraction);
- (void)setPlaying:(BOOL)p;
- (void)setElapsed:(double)el duration:(double)d;
@end
@interface CTable : NSTableView
@property (nonatomic, copy) void (^onHover)(NSInteger row);
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@end
@interface CField : NSTextField @end
