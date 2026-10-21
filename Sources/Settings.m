// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Settings.h"
#import "App.h"
#import "Taskbar.h"

#pragma mark - Settings window (System Settings–style)

@interface CFlipView : NSView @end
@implementation CFlipView
- (BOOL)isFlipped { return YES; }
@end

// Settings tokens, shared with the launcher: the same cool surfaces, ice accent and tracked section labels.
static NSColor *setSurface(NSView *v) { return cIsDark(v) ? [NSColor colorWithSRGBRed:0.112 green:0.117 blue:0.132 alpha:1] : [NSColor colorWithSRGBRed:0.955 green:0.958 blue:0.967 alpha:1]; }
static NSColor *setCardFill(NSView *v) { return cIsDark(v) ? [NSColor colorWithSRGBRed:0.152 green:0.158 blue:0.176 alpha:1] : [NSColor whiteColor]; }
static NSColor *setCardEdge(NSView *v) { return cIsDark(v) ? [NSColor colorWithWhite:1 alpha:0.075] : [NSColor colorWithWhite:0 alpha:0.075]; }
static NSColor *setDivider(NSView *v) { return cIsDark(v) ? [NSColor colorWithWhite:1 alpha:0.065] : [NSColor colorWithWhite:0 alpha:0.07]; }

// The content side of the window: one calm surface instead of the default grey.
@interface CSetSurface : NSView @end
@implementation CSetSurface
- (void)drawRect:(NSRect)r { [setSurface(self) setFill]; NSRectFill(self.bounds); }   // bounds, not the dirty rect: views don't clip to bounds on macOS 14+
@end

// Grouped card, System Settings style: a lifted surface, hairline edge, soft shadow in light mode.
@interface CCard : NSView @end
@implementation CCard
- (void)drawRect:(NSRect)r {
    NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:12 yRadius:12];
    if (!cIsDark(self)) {
        NSShadow *sh = [NSShadow new]; sh.shadowBlurRadius = 3; sh.shadowOffset = NSMakeSize(0, -1); sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.06];
        [NSGraphicsContext saveGraphicsState]; [sh set]; [setCardFill(self) setFill]; [p fill]; [NSGraphicsContext restoreGraphicsState];
    } else { [setCardFill(self) setFill]; [p fill]; }
    p.lineWidth = 1; [setCardEdge(self) setStroke]; [p stroke];
}
@end

// One row inside a card, with a hairline above it (except the first row) that starts where the text starts.
@interface CSetRow : NSView
@property (nonatomic) BOOL topLine;
@end
@implementation CSetRow
- (void)drawRect:(NSRect)r {
    if (!self.topLine) return;
    [setDivider(self) setFill];
    NSRectFillUsingOperation(NSMakeRect(16, self.bounds.size.height - 1, self.bounds.size.width - 16, 1), NSCompositingOperationSourceOver);
}
@end

static NSImage *symSized(NSString *name, CGFloat pt, NSFontWeight w) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) return nil;
    return [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:w]];
}
static NSImage *tintedImage(NSImage *img, NSColor *c) {
    if (!img) return nil;
    return [NSImage imageWithSize:img.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [img drawInRect:r]; [c set]; NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop); return YES; }];
}

// Sidebar item: colour tile + label. Ice-tinted pill when selected, a faint one under the pointer.
@interface CNavItem : NSView
@property (nonatomic, copy) NSString *title, *symbol, *kind;
@property (nonatomic) BOOL selected, hover;
@property (nonatomic, copy) void (^onClick)(void);
@end
@implementation CNavItem
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
    NSRect b = self.bounds;
    if (self.selected || self.hover) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:8 yRadius:8];
        [(self.selected ? cSelFill(self) : [[NSColor labelColor] colorWithAlphaComponent:0.045]) setFill]; [p fill];
        if (self.selected) { p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:7.5 yRadius:7.5]; p.lineWidth = 1; [cSelEdge(self) setStroke]; [p stroke]; }
    }
    NSRect tile = NSMakeRect(8, floor((b.size.height - 22) / 2), 22, 22);
    [tileImage(self.symbol, self.kind) drawInRect:tile fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSDictionary *at = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:self.selected ? NSFontWeightSemibold : NSFontWeightRegular],
                         NSForegroundColorAttributeName: self.selected ? [NSColor labelColor] : [[NSColor labelColor] colorWithAlphaComponent:0.85]};
    NSSize ts = [self.title sizeWithAttributes:at];
    [self.title drawAtPoint:NSMakePoint(40, floor((b.size.height - ts.height) / 2)) withAttributes:at];
}
- (void)mouseDown:(NSEvent *)e { if (self.onClick) self.onClick(); }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { self.hover = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e { self.hover = NO; [self setNeedsDisplay:YES]; }
@end

// Click-to-record shortcut button.
@interface CHotkeyButton : NSButton
@property (nonatomic, copy) NSString *spec;
@property (nonatomic, copy) void (^onChange)(NSString *spec);
@property (nonatomic, copy) void (^onRecording)(BOOL recording);
@property (nonatomic, strong) id monitor;
- (void)refresh;
- (void)stop;
@end
@implementation CHotkeyButton
// Drawn as keycaps (⌘ ⇧ Space) like the launcher's footer; recording shows an ice outline and a prompt.
- (void)refresh {
    self.title = @""; self.bordered = NO; self.toolTip = self.monitor ? nil : @"Click to record a new shortcut";
    [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES];
}
- (NSArray<NSString *> *)caps {
    if (self.monitor) return @[];
    if (!self.spec.length) return @[];
    return [prettyHotkey(self.spec) componentsSeparatedByString:@" "];
}
- (NSDictionary *)capAttrs { return @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: [NSColor labelColor]}; }
- (NSString *)prompt { return self.monitor ? @"Type the shortcut…   esc cancels" : @"Record Shortcut"; }
- (NSSize)intrinsicContentSize {
    NSArray *caps = [self caps]; CGFloat w = 0;
    if (caps.count) { for (NSString *c in caps) w += MAX(26, ceil([c sizeWithAttributes:[self capAttrs]].width) + 14) + 4; w -= 4; }
    else w = ceil([[self prompt] sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}].width) + 24;
    return NSMakeSize(w + 4, 26);
}
- (void)drawRect:(NSRect)dirty {
    BOOL dark = cIsDark(self);
    NSArray *caps = [self caps];
    if (!caps.count) {
        NSRect b = NSInsetRect(self.bounds, 1.5, 1.5);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7];
        [(self.monitor ? [cAccent() colorWithAlphaComponent:0.12] : [[NSColor labelColor] colorWithAlphaComponent:0.05]) setFill]; [p fill];
        p.lineWidth = 1; [(self.monitor ? cAccent() : [[NSColor labelColor] colorWithAlphaComponent:0.15]) setStroke];
        if (!self.monitor) { CGFloat dash[] = {3, 2}; [p setLineDash:dash count:2 phase:0]; }
        [p stroke];
        NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSForegroundColorAttributeName: self.monitor ? [NSColor labelColor] : [NSColor secondaryLabelColor]};
        NSSize s = [[self prompt] sizeWithAttributes:a];
        [[self prompt] drawAtPoint:NSMakePoint(NSMidX(self.bounds) - s.width / 2, NSMidY(self.bounds) - s.height / 2) withAttributes:a];
        return;
    }
    CGFloat x = 2;
    for (NSString *c in caps) {
        NSSize s = [c sizeWithAttributes:[self capAttrs]];
        CGFloat w = MAX(26, ceil(s.width) + 14);
        NSRect k = NSMakeRect(x, 2, w, self.bounds.size.height - 4);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(k, 0.5, 0.5) xRadius:6 yRadius:6];
        [(dark ? [NSColor colorWithWhite:1 alpha:0.10] : [NSColor colorWithWhite:1 alpha:1]) setFill]; [p fill];
        p.lineWidth = 1; [(dark ? [NSColor colorWithWhite:1 alpha:0.10] : [NSColor colorWithWhite:0 alpha:0.14]) setStroke]; [p stroke];
        NSRect lip = NSMakeRect(NSMinX(k) + 3, NSMinY(k) + 0.5, w - 6, 1);           // a keycap's lower lip
        [(dark ? [NSColor colorWithWhite:0 alpha:0.35] : [NSColor colorWithWhite:0 alpha:0.10]) setFill]; NSRectFillUsingOperation(lip, NSCompositingOperationSourceOver);
        [c drawAtPoint:NSMakePoint(NSMidX(k) - s.width / 2, NSMidY(k) - s.height / 2) withAttributes:[self capAttrs]];
        x += w + 4;
    }
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]]; }
- (void)toggleRecord:(id)s {
    if (self.monitor) { [self stop]; return; }
    if (self.onRecording) self.onRecording(YES);
    __weak CHotkeyButton *ws = self;
    self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        if (e.keyCode == kVK_Escape) { [ws stop]; return nil; }
        NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString *key = nil;
        NSDictionary *map = hotkeyKeyMap();
        for (NSString *k in map) if ([map[k] integerValue] == (NSInteger)e.keyCode) { key = k; break; }
        if (!key || !(m & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl))) { NSBeep(); return nil; }
        NSMutableArray *parts = [NSMutableArray new];
        if (m & NSEventModifierFlagControl) [parts addObject:@"ctrl"];
        if (m & NSEventModifierFlagOption) [parts addObject:@"alt"];
        if (m & NSEventModifierFlagShift) [parts addObject:@"shift"];
        if (m & NSEventModifierFlagCommand) [parts addObject:@"cmd"];
        [parts addObject:key];
        ws.spec = [parts componentsJoinedByString:@"+"];
        [ws stop];
        if (ws.onChange) ws.onChange(ws.spec);
        return nil;
    }];
    [self refresh];
}
- (void)stop {
    if (!self.monitor) return;
    [NSEvent removeMonitor:self.monitor]; self.monitor = nil;
    [self refresh];
    if (self.onRecording) self.onRecording(NO);
}
@end

static NSTextField *setLabel(NSString *s, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *l = [NSTextField labelWithString:s ?: @""];
    l.font = [NSFont systemFontOfSize:size weight:w]; l.textColor = c ?: [NSColor labelColor];
    return l;
}

static CSetRow *setRow(NSString *title, NSString *sub, NSView *control) {
    CSetRow *r = [CSetRow new]; r.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *texts = [NSStackView stackViewWithViews:@[setLabel(title, 13, NSFontWeightRegular, nil)]];
    texts.orientation = NSUserInterfaceLayoutOrientationVertical; texts.alignment = NSLayoutAttributeLeading; texts.spacing = 2;
    if (sub.length) {
        NSTextField *s = setLabel(sub, 11.5, NSFontWeightRegular, [NSColor secondaryLabelColor]);
        s.lineBreakMode = NSLineBreakByTruncatingTail;
        [s setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [texts addArrangedSubview:s];
    }
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    [texts setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r addSubview:texts];
    NSMutableArray *cs = [@[[r.heightAnchor constraintEqualToConstant:sub.length ? 58 : 46],
                            [texts.leadingAnchor constraintEqualToAnchor:r.leadingAnchor constant:16],
                            [texts.centerYAnchor constraintEqualToAnchor:r.centerYAnchor]] mutableCopy];
    if (control) {
        control.translatesAutoresizingMaskIntoConstraints = NO;
        [control setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [r addSubview:control];
        [cs addObjectsFromArray:@[[control.trailingAnchor constraintEqualToAnchor:r.trailingAnchor constant:-16],
                                  [control.centerYAnchor constraintEqualToAnchor:r.centerYAnchor],
                                  [control.leadingAnchor constraintGreaterThanOrEqualToAnchor:texts.trailingAnchor constant:16]]];
    } else {
        [cs addObject:[texts.trailingAnchor constraintLessThanOrEqualToAnchor:r.trailingAnchor constant:-16]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    return r;
}

static CCard *setCard(NSArray<NSView *> *rows) {
    CCard *card = [CCard new]; card.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *prev = nil;
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSView *r = rows[i]; r.translatesAutoresizingMaskIntoConstraints = NO;
        if ([r isKindOfClass:[CSetRow class]]) ((CSetRow *)r).topLine = (i > 0);
        [card addSubview:r];
        [NSLayoutConstraint activateConstraints:@[[r.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
                                                  [r.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
                                                  [r.topAnchor constraintEqualToAnchor:prev ? prev.bottomAnchor : card.topAnchor]]];
        prev = r;
    }
    if (prev) [prev.bottomAnchor constraintEqualToAnchor:card.bottomAnchor].active = YES;
    return card;
}

static NSTextField *setField(NSString *value, NSString *placeholder, CGFloat width, id target, SEL action) {
    NSTextField *f = [NSTextField textFieldWithString:value ?: @""];
    f.placeholderString = placeholder; f.font = [NSFont systemFontOfSize:12];
    f.bezelStyle = NSTextFieldRoundedBezel; f.target = target; f.action = action;
    ((NSTextFieldCell *)f.cell).sendsActionOnEndEditing = YES;
    ((NSTextFieldCell *)f.cell).lineBreakMode = NSLineBreakByTruncatingMiddle;
    [f.widthAnchor constraintEqualToConstant:width].active = YES;
    return f;
}

@interface CSettings () <NSTextViewDelegate>
@property (nonatomic, weak) CApp *app;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *commands, *snips;   // editable copies of config "commands" / "snippets"
@property (nonatomic, strong) NSTimer *saveTimer;
@property (nonatomic, copy) NSString *focusID;        // field to focus after the page rebuilds (a just-added item)
@property (nonatomic, copy) NSString *recordKey;      // shortcut row to start recording after the page rebuilds
@property (nonatomic, strong) NSMutableArray *prefixes, *links, *folders;   // arrays of NSMutableArray<NSString*>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSTableView *> *tables;
@property (nonatomic, strong) NSArray<CNavItem *> *nav;
@property (nonatomic, strong) CFlipView *doc;
@property (nonatomic, strong) NSStackView *pageStack;
@property (nonatomic) NSInteger page;
@property (nonatomic, strong) NSPopUpButton *enginePopup;
@property (nonatomic, strong) NSTextField *customURL;
@property (nonatomic, strong) CHotkeyButton *hotkeyButton;
@property (nonatomic) BOOL axShown;   // Accessibility state the page was built with
@property (nonatomic, strong) NSTimer *axTimer;
@end

// name, symbol, tile colour, one-line purpose, sidebar group (shown before the first page of each group)
static NSArray *settingsPages(void) {
    return @[@[@"General", @"gearshape.fill", @"System", @"Your shortcut, startup and what Centre remembers.", @""],
             @[@"Home", @"house.fill", @"Clipboard", @"What you see the moment Centre opens.", @""],
             @[@"Taskbar", @"dock.rectangle", @"Context", @"A floating bar for your apps, tray and clock.", @""],
             @[@"Search", @"magnifyingglass", @"Web", @"Where searches go when nothing on your Mac matches.", @""],
             @[@"Commands", @"terminal.fill", @"Script", @"Scripts and flows that run like built-in commands.", @"Make It Yours"],
             @[@"Snippets", @"text.quote", @"Snippet", @"Text you paste anywhere in a keystroke.", @""],
             @[@"Shortcuts", @"command", @"Media", @"Global keys for anything Centre can run.", @""],
             @[@"Quick Links", @"link", @"Link", @"Websites you open by name.", @""],
             @[@"Permissions", @"hand.raised.fill", @"Window", @"What Centre can access, and how to fix what's missing.", @"System"],
             @[@"Advanced", @"wrench.and.screwdriver.fill", @"Centre", @"App folders, the config file and maintenance.", @""]];
}
static NSInteger pageIndex(NSString *name) {
    NSArray *p = settingsPages();
    for (NSUInteger i = 0; i < p.count; i++) if ([p[i][0] isEqualToString:name]) return (NSInteger)i;
    return 0;
}
static NSMutableArray *mutableList(id v) {
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *d in ([v isKindOfClass:[NSArray class]] ? v : @[]))
        if ([d isKindOfClass:[NSDictionary class]] && [d[@"id"] isKindOfClass:[NSString class]]) [r addObject:[d mutableCopy]];
    return r;
}
static NSString *shortID(void) { return [[NSUUID UUID].UUIDString substringToIndex:8].lowercaseString; }
static NSArray *searchEngines(void) {
    return @[@[@"DuckDuckGo", @"https://duckduckgo.com/?q=%s"], @[@"Google", @"https://www.google.com/search?q=%s"],
             @[@"Brave Search", @"https://search.brave.com/search?q=%s"], @[@"Bing", @"https://www.bing.com/search?q=%s"],
             @[@"Kagi", @"https://kagi.com/search?q=%s"], @[@"Custom", @""]];
}

@implementation CSettings

- (instancetype)initWithApp:(CApp *)app {
    if ((self = [super init])) { _app = app; _tables = [NSMutableDictionary new]; [self loadModel]; [self buildWindow]; }
    return self;
}

- (void)loadModel {
    NSDictionary *c = self.app.config;
    self.prefixes = [NSMutableArray new]; self.links = [NSMutableArray new]; self.folders = [NSMutableArray new];
    NSDictionary *sp = [c[@"searchPrefixes"] isKindOfClass:[NSDictionary class]] ? c[@"searchPrefixes"] : @{};
    for (NSString *k in [sp.allKeys sortedArrayUsingSelector:@selector(compare:)]) [self.prefixes addObject:[@[k, [sp[k] description]] mutableCopy]];
    for (NSDictionary *l in ([c[@"links"] isKindOfClass:[NSArray class]] ? c[@"links"] : @[]))
        if ([l isKindOfClass:[NSDictionary class]]) [self.links addObject:[@[[l[@"name"] description] ?: @"", [l[@"url"] description] ?: @""] mutableCopy]];
    for (NSString *f in ([c[@"appFolders"] isKindOfClass:[NSArray class]] ? c[@"appFolders"] : @[]))
        if ([f isKindOfClass:[NSString class]]) [self.folders addObject:[@[f] mutableCopy]];
    self.commands = mutableList(c[@"commands"]);
    self.snips = mutableList(c[@"snippets"]);
}

- (void)buildWindow {
    const CGFloat W = 860, H = 640, SB = 228;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden; w.title = @"Centre Settings";
    w.releasedWhenClosed = NO; w.delegate = self;
    NSView *root = w.contentView;

    NSVisualEffectView *side = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, SB, H)];
    side.material = NSVisualEffectMaterialSidebar; side.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    side.state = NSVisualEffectStateFollowsWindowActiveState; side.autoresizingMask = NSViewHeightSizable;
    [root addSubview:side];
    CFlipView *sc = [[CFlipView alloc] initWithFrame:side.bounds]; sc.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [side addSubview:sc];

    NSImageView *icon = [NSImageView imageViewWithImage:[NSApp applicationIconImage]];
    icon.frame = NSMakeRect(16, 46, 38, 38); icon.imageScaling = NSImageScaleProportionallyUpOrDown; [sc addSubview:icon];
    NSTextField *name = setLabel(@"Centre", 15, NSFontWeightSemibold, nil); name.frame = NSMakeRect(62, 48, 150, 19); [sc addSubview:name];
    NSTextField *ver = setLabel([@"Version " stringByAppendingString:[NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"2.0"], 11, NSFontWeightRegular, [NSColor tertiaryLabelColor]); ver.frame = NSMakeRect(62, 67, 150, 14); [sc addSubview:ver];

    NSMutableArray *items = [NSMutableArray new];
    NSArray *pages = settingsPages();
    __weak CSettings *ws = self;
    CGFloat y = 104;
    for (NSUInteger i = 0; i < pages.count; i++) {
        if ([pages[i][4] length]) {                               // group label: small tracked capitals, like the launcher
            y += 12;
            NSTextField *g = [NSTextField labelWithAttributedString:sectionTitle(pages[i][4])];
            g.frame = NSMakeRect(20, y, SB - 40, 14); [sc addSubview:g];
            y += 20;
        }
        CNavItem *it = [[CNavItem alloc] initWithFrame:NSMakeRect(10, y, SB - 20, 30)];
        it.title = pages[i][0]; it.symbol = pages[i][1]; it.kind = pages[i][2];
        it.onClick = ^{ [ws showPage:(NSInteger)i]; };
        [sc addSubview:it]; [items addObject:it];
        y += 32;
    }
    self.nav = items;

    CSetSurface *surface = [[CSetSurface alloc] initWithFrame:NSMakeRect(SB, 0, W - SB, H)];
    surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [root addSubview:surface];
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(SB, 0, 1, H)];
    line.boxType = NSBoxSeparator; line.autoresizingMask = NSViewHeightSizable; [root addSubview:line];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(SB + 1, 0, W - SB - 1, H)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES; sv.borderType = NSNoBorder;
    sv.automaticallyAdjustsContentInsets = NO; sv.contentInsets = NSEdgeInsetsMake(0, 0, 0, 0);
    CFlipView *doc = [CFlipView new]; doc.translatesAutoresizingMaskIntoConstraints = NO;
    sv.documentView = doc;
    [NSLayoutConstraint activateConstraints:@[[doc.leadingAnchor constraintEqualToAnchor:sv.contentView.leadingAnchor],
                                              [doc.trailingAnchor constraintEqualToAnchor:sv.contentView.trailingAnchor],
                                              [doc.topAnchor constraintEqualToAnchor:sv.contentView.topAnchor]]];
    [root addSubview:sv];
    self.doc = doc; self.window = w;
}

- (void)show {
    if (self.window.visible) [self flushEdits];              // reopening must not throw away the last half-second of typing
    [self.app loadConfig];
    [self loadModel];
    [self showPage:self.page];
    [NSApp activateIgnoringOtherApps:YES];
    if (!self.window.visible) [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

#pragma mark Page scaffolding

- (void)showPage:(NSInteger)i {
    // Rebuilding the page you're on keeps your scroll position; switching pages starts at the top.
    NSPoint keep = (i == self.page && self.pageStack) ? self.doc.enclosingScrollView.contentView.bounds.origin : NSZeroPoint;
    self.axShown = AXIsProcessTrusted();
    [self.hotkeyButton stop];
    for (NSView *v in self.pageStack.arrangedSubviews) [self stopRecordersIn:v];
    [self.window makeFirstResponder:nil];
    self.page = i;
    for (NSUInteger k = 0; k < self.nav.count; k++) { self.nav[k].selected = ((NSInteger)k == i); [self.nav[k] setNeedsDisplay:YES]; }
    [self.pageStack removeFromSuperview]; [self.tables removeAllObjects];
    self.enginePopup = nil; self.customURL = nil; self.hotkeyButton = nil;

    NSStackView *st = [NSStackView new];
    st.orientation = NSUserInterfaceLayoutOrientationVertical; st.alignment = NSLayoutAttributeLeading; st.spacing = 8;
    st.edgeInsets = NSEdgeInsetsMake(44, 36, 40, 36); st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.doc addSubview:st];
    [NSLayoutConstraint activateConstraints:@[[st.topAnchor constraintEqualToAnchor:self.doc.topAnchor],
                                              [st.leadingAnchor constraintEqualToAnchor:self.doc.leadingAnchor],
                                              [st.trailingAnchor constraintEqualToAnchor:self.doc.trailingAnchor],
                                              [st.bottomAnchor constraintEqualToAnchor:self.doc.bottomAnchor]]];
    self.pageStack = st;
    NSArray *pg = settingsPages()[i];
    NSImageView *tile = [NSImageView imageViewWithImage:tileImage(pg[1], pg[2])];
    tile.imageScaling = NSImageScaleProportionallyUpOrDown;
    [tile.widthAnchor constraintEqualToConstant:40].active = YES; [tile.heightAnchor constraintEqualToConstant:40].active = YES;
    NSTextField *title = setLabel(pg[0], 24, NSFontWeightBold, nil);
    NSTextField *purpose = setLabel(pg[3], 12.5, NSFontWeightRegular, [NSColor secondaryLabelColor]);
    NSStackView *words = [NSStackView stackViewWithViews:@[title, purpose]];
    words.orientation = NSUserInterfaceLayoutOrientationVertical; words.alignment = NSLayoutAttributeLeading; words.spacing = 1;
    NSStackView *head = [NSStackView stackViewWithViews:@[tile, words]]; head.spacing = 14; head.alignment = NSLayoutAttributeCenterY;
    [st addArrangedSubview:head]; [st setCustomSpacing:30 afterView:head];
    NSString *name = settingsPages()[i][0];
    if ([name isEqualToString:@"General"]) [self buildGeneral];
    else if ([name isEqualToString:@"Home"]) [self buildHomePage];
    else if ([name isEqualToString:@"Taskbar"]) [self buildTaskbar];
    else if ([name isEqualToString:@"Search"]) [self buildSearch];
    else if ([name isEqualToString:@"Commands"]) [self buildCommands];
    else if ([name isEqualToString:@"Snippets"]) [self buildSnippets];
    else if ([name isEqualToString:@"Shortcuts"]) [self buildShortcuts];
    else if ([name isEqualToString:@"Quick Links"]) [self buildLinks];
    else if ([name isEqualToString:@"Permissions"]) [self buildPermissions];
    else [self buildAdvanced];
    [self.doc layoutSubtreeIfNeeded];
    [self.doc scrollPoint:keep];
    if (self.focusID) {                                   // a just-added command or snippet: put the cursor in its name
        NSView *f = [self viewWithIdentifier:self.focusID in:self.doc]; self.focusID = nil;
        if (f) { [self.doc scrollRectToVisible:[self.doc convertRect:f.bounds fromView:f]]; [self.window makeFirstResponder:f]; }
    }
}

- (void)showPageNamed:(NSString *)name { [self showPage:pageIndex(name)]; }
// Snapshots only: example commands and snippets held in memory, never saved.
- (void)useSampleData {
    self.commands = [@[[@{@"id": @"s1", @"name": @"Focus", @"type": @"flow", @"icon": @"scope", @"script": @"# Clear the decks\nShow Desktop\nKeep Awake\nopen Notes"} mutableCopy],
                       [@{@"id": @"s2", @"name": @"Brew Search", @"type": @"shell", @"output": @"terminal", @"icon": @"mug", @"script": @"brew search {query}", @"keywords": @"homebrew"} mutableCopy]] mutableCopy];
    self.snips = [@[[@{@"id": @"n1", @"name": @"Email sign-off", @"keyword": @";sig", @"text": @"Kind regards,\nMax"} mutableCopy]] mutableCopy];
}
- (NSView *)viewWithIdentifier:(NSString *)ident in:(NSView *)v {
    if ([v.identifier isEqualToString:ident]) return v;
    for (NSView *s in v.subviews) { NSView *hit = [self viewWithIdentifier:ident in:s]; if (hit) return hit; }
    return nil;
}

- (void)addFull:(NSView *)v {
    [self.pageStack addArrangedSubview:v];
    [v.widthAnchor constraintEqualToAnchor:self.pageStack.widthAnchor constant:-72].active = YES;
}
- (void)addHeader:(NSString *)t note:(NSString *)n {
    NSTextField *h = [NSTextField labelWithAttributedString:sectionTitle(t)];
    [self.pageStack addArrangedSubview:h];
    if (n.length) {
        [self.pageStack setCustomSpacing:5 afterView:h];
        NSTextField *nt = [NSTextField wrappingLabelWithString:n];
        nt.font = [NSFont systemFontOfSize:12]; nt.textColor = [NSColor secondaryLabelColor]; nt.selectable = NO;
        [self addFull:nt];
        [self.pageStack setCustomSpacing:12 afterView:nt];
    } else {
        [self.pageStack setCustomSpacing:9 afterView:h];
    }
}
- (void)gap { NSView *last = self.pageStack.arrangedSubviews.lastObject; if (last) [self.pageStack setCustomSpacing:32 afterView:last]; }

- (NSSwitch *)switchFor:(NSString *)key fallback:(BOOL)def {
    NSSwitch *s = [NSSwitch new]; s.controlSize = NSControlSizeSmall;
    id v = self.app.config[key];
    s.state = (v ? [v boolValue] : def) ? NSControlStateValueOn : NSControlStateValueOff;
    s.identifier = key; s.target = self; s.action = @selector(switchChanged:);
    return s;
}
- (NSButton *)button:(NSString *)t target:(id)target action:(SEL)a {
    NSButton *b = [NSButton buttonWithTitle:t target:target action:a]; b.bezelStyle = NSBezelStyleRounded; return b;
}

#pragma mark Pages

- (void)buildGeneral {
    NSDictionary *c = self.app.config;
    __weak CSettings *ws = self;
    CHotkeyButton *hk = [CHotkeyButton buttonWithTitle:@"" target:nil action:nil];
    hk.target = hk; hk.action = @selector(toggleRecord:); hk.bezelStyle = NSBezelStyleRounded;
    hk.spec = [c[@"hotkey"] isKindOfClass:[NSString class]] ? c[@"hotkey"] : @"cmd+space";
    hk.onRecording = ^(BOOL on) {
        if (on) { [ws.app unregisterHotKey]; [ws.app unregisterCommandHotKeys]; } else { [ws.app registerHotKey]; [ws.app registerCommandHotKeys]; } };
    hk.onChange = ^(NSString *s) { [ws saveKey:@"hotkey" value:s]; };
    [hk refresh];
    self.hotkeyButton = hk;

    NSSwitch *login = [self switchFor:@"launchAtLogin" fallback:NO];
    login.state = [self.app launchesAtLogin] ? NSControlStateValueOn : NSControlStateValueOff;   // what macOS actually has
    login.action = @selector(loginChanged:);

    [self addHeader:@"Launcher" note:nil];
    [self addFull:setCard(@[setRow(@"Keyboard shortcut", self.app.hotkeyFailed ? @"⚠︎ Taken by another app — click and press a different combination."
                                                                               : @"Click, then press the new combination.", hk),
                            setRow(@"Launch at login", @"Starts quietly in the background.", login),
                            setRow(@"Show in menu bar", @"Adds the Centre icon to the menu bar.", [self switchFor:@"showMenuBarIcon" fallback:NO])])];
    [self gap];


    [self addHeader:@"Behaviour" note:nil];
    [self addFull:setCard(@[setRow(@"Clipboard history", @"Last 100 copied texts, memory only. Type clip.", [self switchFor:@"clipboardHistory" fallback:YES]),
                            setRow(@"File results", @"Include Spotlight file matches in search.", [self switchFor:@"fileResults" fallback:YES])])];
    [self gap];

    // Browser details only matter once YouTube Music control is on.
    NSString *browser = [self.app ytmBrowser];
    BOOL ytm = [self.app.config[@"mediaYTM"] boolValue];
    [self addHeader:@"Media" note:ytm ? [NSString stringWithFormat:@"YouTube Music control needs two one-time permissions: allow Centre to control %@ when macOS asks, and in %@ turn on View › Developer › Allow JavaScript from Apple Events.", browser, browser] : nil];
    NSMutableArray *mediaRows = [@[setRow(@"Control any media player", @"Whatever last played: a video, podcast or another app.", [self switchFor:@"showMediaPlayer" fallback:YES]),
                                  setRow(@"Control YouTube Music", @"Always targets the YouTube Music tab, even while a video plays.", [self switchFor:@"mediaYTM" fallback:NO])] mutableCopy];
    if (ytm) [mediaRows addObject:setRow(@"Browser", @"Where YouTube Music runs. Starts Liked Music if no tab is open.", setField(browser, browser, 150, self, @selector(ytmBrowserChanged:)))];
    [self addFull:setCard(mediaRows)];
    [self gap];

}

- (void)buildSearch {
    NSArray *eng = searchEngines();
    NSString *cur = [self.app.config[@"webSearch"] isKindOfClass:[NSString class]] ? self.app.config[@"webSearch"] : eng[0][1];
    NSInteger sel = (NSInteger)eng.count - 1;
    for (NSUInteger i = 0; i + 1 < eng.count; i++) if ([eng[i][1] isEqualToString:cur]) sel = (NSInteger)i;
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray *e in eng) [pop addItemWithTitle:e[0]];
    [pop selectItemAtIndex:sel]; pop.target = self; pop.action = @selector(engineChanged:);
    NSTextField *custom = setField(cur, @"https://example.com/search?q=%s", 290, self, @selector(customChanged:));
    custom.enabled = (sel == (NSInteger)eng.count - 1);
    self.enginePopup = pop; self.customURL = custom;

    [self addHeader:@"Web search" note:@"Used when nothing else matches."];
    [self addFull:setCard(@[setRow(@"Search engine", nil, pop), setRow(@"Search URL", @"%s becomes your query.", custom)])];
    [self gap];
    [self addHeader:@"Keyword shortcuts" note:@"Type a keyword, a space, then your query — “yt lofi” searches YouTube. Double-click a cell to edit."];
    [self addFull:[self tableCardTag:1 columns:@[@[@"Keyword", @110], @[@"Search URL", @340]] height:200]];
}

- (void)buildLinks {
    [self addHeader:@"Quick links" note:@"Type a link's name in Centre to open it. Double-click a cell to edit."];
    [self addFull:[self tableCardTag:2 columns:@[@[@"Name", @150], @[@"URL", @300]] height:300]];
}

#pragma mark Permissions

// Signed with a real certificate (stable identity) rather than ad-hoc (new identity every build)?
static BOOL hasStableSignature(void) {
    SecCodeRef code = NULL; SecStaticCodeRef st = NULL; CFDictionaryRef info = NULL; BOOL ok = NO;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &st) == errSecSuccess &&
        SecCodeCopySigningInformation(st, kSecCSSigningInformation, &info) == errSecSuccess && info) {
        NSArray *certs = ((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoCertificates];
        ok = [certs isKindOfClass:[NSArray class]] && certs.count > 0;
    }
    if (info) CFRelease(info);
    if (st) CFRelease(st);
    if (code) CFRelease(code);
    return ok;
}
// Apple Events permission for System Events, checked without prompting.
static OSStatus automationStatus(void) {
    NSAppleEventDescriptor *t = [NSAppleEventDescriptor descriptorWithBundleIdentifier:@"com.apple.systemevents"];
    return AEDeterminePermissionToAutomateTarget(t.aeDesc, typeWildCard, typeWildCard, false);
}

- (NSView *)status:(NSString *)text ok:(BOOL)ok action:(NSButton *)b {
    NSImage *g = tintedImage(symSized(ok ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill", 13, NSFontWeightRegular),
                             ok ? [NSColor systemGreenColor] : [NSColor systemOrangeColor]);
    NSStackView *st = [NSStackView stackViewWithViews:@[[NSImageView imageViewWithImage:g], setLabel(text, 12, NSFontWeightMedium, [NSColor secondaryLabelColor])]];
    st.spacing = 5;
    if (b) { [st addArrangedSubview:b]; [st setCustomSpacing:12 afterView:st.arrangedSubviews[1]]; }
    return st;
}
- (NSButton *)privacyButton:(NSString *)anchor {
    NSButton *b = [self button:@"Open Settings" target:self action:@selector(openPrivacy:)]; b.identifier = anchor; return b;
}
- (void)openPrivacy:(NSButton *)b {
    openURLString([@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:b.identifier]);
}
- (void)askAutomation:(NSButton *)b {
    b.enabled = NO; b.title = @"Asking…";
    __weak CSettings *ws = self;   // the first real Apple Event is what makes macOS show its prompt
    runOsa(@"tell application \"System Events\" to return name of first process whose frontmost is true", ^(NSString *o) { [ws showPage:ws.page]; });
}
- (void)setupSigning:(NSButton *)b {
    b.enabled = NO; b.title = @"Setting up…";
    __weak CSettings *ws = self;
    runShell([NSString stringWithFormat:@"cd %@ && /bin/bash ./setup-signing.sh 2>&1 | tee signing.log", shellQuote([self.app sourceDir])], ^(NSString *out) {
        if ([out containsString:@"Signing identity ready."]) { [ws.app rebuild]; return; }   // re-sign with it and relaunch
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *al = [NSAlert new]; al.messageText = @"Couldn't set up signing";
        al.informativeText = out.length > 1500 ? [out substringFromIndex:out.length - 1500] : (out.length ? out : @"The setup script produced no output.");
        [al runModal];
        b.enabled = YES; b.title = @"Try Again";
    });
}

- (void)buildPermissions {
    BOOL sig = hasStableSignature();
    [self addHeader:@"Keep permissions after rebuilds"
               note:@"Every rebuild used to get a throwaway signature, so macOS treated Centre as a new app and asked for access again. A private signing certificate, made once on this Mac, gives every build the same identity. macOS asks for your password once, then for each permission one last time."];
    [self addFull:setCard(@[setRow(@"Stable signature", sig ? @"Rebuilds keep their permissions." : @"Creates a certificate in your login keychain.",
                                   [self status:sig ? @"On" : @"Off" ok:sig action:sig ? nil : [self button:@"Set Up…" target:self action:@selector(setupSigning:)]])])];
    [self gap];

    BOOL ax = AXIsProcessTrusted();
    [self.axTimer invalidate]; self.axTimer = nil;
    if (!ax) {
        __weak CSettings *ws = self;
        self.axTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
            if (!ws || ws.page != pageIndex(@"Permissions") || !ws.window.visible) { [t invalidate]; return; }
            if (AXIsProcessTrusted()) { [t invalidate]; [ws showPage:ws.page]; }
        }];
    }
    BOOL docs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self.app sourceDir] error:nil] != nil;
    OSStatus ae = automationStatus();
    NSString *aeText = ae == noErr ? @"Allowed" : ae == errAEEventNotPermitted ? @"Denied" : @"Not asked yet";
    NSButton *aeB = ae == noErr ? nil : ae == errAEEventNotPermitted ? [self privacyButton:@"Privacy_Automation"]
                                                                     : [self button:@"Allow…" target:self action:@selector(askAutomation:)];
    [self addHeader:@"Access" note:@"Statuses refresh when you come back from System Settings."];
    [self addFull:setCard(@[
        setRow(@"Accessibility", ax ? @"Window snapping and pasting from clipboard history." : @"Grant resets Centre's old entry, then turn the new switch on.",
               [self status:ax ? @"Granted" : @"Not granted" ok:ax action:ax ? nil : [self button:@"Grant…" target:self.app action:@selector(grantAX)]]),
        setRow(@"Documents folder", @"Centre lives here and rebuilds when its source changes.",
               [self status:docs ? @"Granted" : @"Not granted" ok:docs action:docs ? nil : [self privacyButton:@"Privacy_FilesAndFolders"]]),
        setRow(@"Automation", @"Sleep, dark mode, empty trash.", [self status:aeText ok:ae == noErr action:aeB])])];
}

- (void)buildAdvanced {
    [self addHeader:@"App folders" note:@"Centre indexes applications in these folders and one level of subfolders."];
    [self addFull:[self tableCardTag:3 columns:@[@[@"Folder", @460]] height:150]];
    [self gap];
    NSTextField *editor = setField([self.app.config[@"editor"] isKindOfClass:[NSString class]] ? self.app.config[@"editor"] : @"Zed", @"Zed", 150, self, @selector(editorChanged:));
    [self addHeader:@"Maintenance" note:nil];
    [self addFull:setCard(@[setRow(@"Config file", [self.app.configPath stringByAbbreviatingWithTildeInPath], [self button:@"Reveal" target:self action:@selector(revealConfig:)]),
                            setRow(@"Text editor", @"Used by “Open config.json”.", editor),
                            setRow(@"App index", @"Scan app folders again now.", [self button:@"Rescan" target:self action:@selector(rescan:)]),
                            setRow(@"Usage ranking", @"Forget launch counts behind Most Used.", [self button:@"Reset" target:self action:@selector(resetUsage:)]),
                            setRow(@"Rebuild Centre", @"Recompile from Sources and relaunch.", [self button:@"Rebuild" target:self.app action:@selector(rebuild)])])];
}

#pragma mark Shared bits for list pages

- (void)stopRecordersIn:(NSView *)v {
    if ([v isKindOfClass:[CHotkeyButton class]]) [(CHotkeyButton *)v stop];
    for (NSView *s in v.subviews) [self stopRecordersIn:s];
}
- (NSButton *)iconButton:(NSString *)sym tip:(NSString *)tip action:(SEL)a tag:(NSInteger)tag {
    NSButton *b = [NSButton buttonWithImage:symSized(sym, 12, NSFontWeightMedium) target:self action:a];
    b.bordered = NO; b.tag = tag; b.toolTip = tip; b.contentTintColor = [NSColor secondaryLabelColor];
    [b.widthAnchor constraintEqualToConstant:22].active = YES;
    return b;
}
// A pull-down "Add…" button listing everything runnable, grouped (Commands, Your Commands, Snippets, Apps, Folders…).
- (NSPopUpButton *)catalogPopup:(NSString *)title action:(SEL)a {
    NSPopUpButton *pb = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [pb addItemWithTitle:title];
    for (NSArray *g in [self.app catalogGroups]) {
        NSMenu *sub = [[NSMenu alloc] initWithTitle:g[0]];
        for (NSArray *e in g[1]) {
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:e[0] action:a keyEquivalent:@""];
            mi.target = self; mi.representedObject = e[1]; [sub addItem:mi];
        }
        if (!sub.numberOfItems) continue;
        NSMenuItem *gi = [[NSMenuItem alloc] initWithTitle:g[0] action:nil keyEquivalent:@""];
        gi.submenu = sub; [pb.menu addItem:gi];
    }
    return pb;
}
- (NSView *)toolbar:(NSArray<NSView *> *)views {
    NSStackView *st = [NSStackView stackViewWithViews:views]; st.spacing = 8;
    return st;
}
static NSString *keyKind(NSString *k) {
    if ([k hasPrefix:@"cmd:"]) return @"Command";
    if ([k hasPrefix:@"custom:"]) return @"Your command";
    if ([k hasPrefix:@"snip:"]) return @"Snippet";
    if ([k hasPrefix:@"tx:"]) return @"Text transform";
    if ([k hasPrefix:@"x-apple"]) return @"System Settings";
    if ([k hasPrefix:@"/"]) {
        BOOL dir = NO; [[NSFileManager defaultManager] fileExistsAtPath:k isDirectory:&dir];
        if ([k.pathExtension isEqualToString:@"app"]) return @"App";
        NSString *parent = [k.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath];
        if ([parent isEqualToString:@"/"]) return dir ? @"Folder" : @"File";
        return [(dir ? @"Folder in " : @"File in ") stringByAppendingString:parent];
    }
    return @"Link";
}

#pragma mark Home

- (void)buildHomePage {
    NSArray *keys = [self.app pinnedKeys];
    [self addHeader:@"Pinned" note:@"Buttons under Most Used. In Centre, select any command, app, folder or snippet and press ⇧⌘P to pin or unpin it. As many as fit on one row are shown."];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSButton *up = [self iconButton:@"chevron.up" tip:@"Move left" action:@selector(movePin:) tag:(NSInteger)i];
        NSButton *down = [self iconButton:@"chevron.down" tip:@"Move right" action:@selector(movePin:) tag:(NSInteger)i];
        NSButton *rm = [self iconButton:@"minus.circle" tip:@"Unpin" action:@selector(removePin:) tag:(NSInteger)i];
        up.identifier = @"up"; down.identifier = @"down"; up.enabled = i > 0; down.enabled = i + 1 < keys.count;
        NSStackView *ctl = [NSStackView stackViewWithViews:@[up, down, rm]]; ctl.spacing = 4;
        [rows addObject:setRow([self.app titleForKey:keys[i]], keyKind(keys[i]), ctl)];
    }
    if (!rows.count) [rows addObject:setRow(@"Nothing pinned", @"Add commands, apps, folders or snippets below.", nil)];
    [self addFull:setCard(rows)];
    [self.pageStack setCustomSpacing:10 afterView:self.pageStack.arrangedSubviews.lastObject];
    [self.pageStack addArrangedSubview:[self toolbar:@[[self catalogPopup:@"Add…" action:@selector(addPin:)],
                                                      [self button:@"Restore Defaults" target:self action:@selector(resetPins:)]]]];
    [self gap];
    BOOL legacyOff = [self.app.config[@"showHomeExtras"] isEqual:@NO];
    [self addHeader:@"Sections" note:@"What Home shows. Rows are trimmed so Home always fits one glance."];
    [self addFull:setCard(@[setRow(@"Most used apps", @"Icon row below the search field.", [self switchFor:@"showMostUsed" fallback:YES]),
                            setRow(@"Pinned", @"The buttons above.", [self switchFor:@"homePinned" fallback:!legacyOff]),
                            setRow(@"Selected text and app actions", @"Acts on what you selected, or on the browser or Finder window you came from.", [self switchFor:@"homeContext" fallback:!legacyOff]),
                            setRow(@"Clipboard", @"Your latest copies.", [self switchFor:@"homeClipboard" fallback:!legacyOff]),
                            setRow(@"Recent files", @"Files you opened anywhere on this Mac.", [self switchFor:@"homeFiles" fallback:!legacyOff]),
                            setRow(@"Recent commands", @"Commands, snippets and links you ran.", [self switchFor:@"homeCommands" fallback:!legacyOff])])];
}
- (void)movePin:(NSButton *)b {
    NSMutableArray *k = [[self.app pinnedKeys] mutableCopy]; NSInteger i = b.tag, j = i + ([b.identifier isEqualToString:@"up"] ? -1 : 1);
    if (i < 0 || j < 0 || i >= (NSInteger)k.count || j >= (NSInteger)k.count) return;
    [k exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j];
    [self.app setPinnedKeys:k]; [self showPage:self.page];
}
- (void)removePin:(NSButton *)b {
    NSMutableArray *k = [[self.app pinnedKeys] mutableCopy];
    if (b.tag < 0 || b.tag >= (NSInteger)k.count) return;
    [k removeObjectAtIndex:(NSUInteger)b.tag];
    [self.app setPinnedKeys:k]; [self showPage:self.page];
}
- (void)addPin:(NSMenuItem *)mi {
    NSMutableArray *k = [[self.app pinnedKeys] mutableCopy];
    if (![k containsObject:mi.representedObject]) [k addObject:mi.representedObject];
    [self.app setPinnedKeys:k]; [self showPage:self.page];
}
- (void)resetPins:(id)s { [self.app setPinnedKeys:[self.app defaultPins]]; [self showPage:self.page]; }

#pragma mark Taskbar

// A pop-up whose items map to config values; saved like a switch.
- (NSPopUpButton *)choice:(NSArray<NSArray<NSString *> *> *)pairs key:(NSString *)key fallback:(NSString *)def {
    NSString *cur = [self.app.config[key] isKindOfClass:[NSString class]] ? self.app.config[key] : def;
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray *pr in pairs) { [p addItemWithTitle:pr[0]]; p.lastItem.representedObject = pr[1]; if ([pr[1] isEqualToString:cur]) [p selectItem:p.lastItem]; }
    p.identifier = key; p.target = self; p.action = @selector(choiceChanged:);
    return p;
}
- (void)choiceChanged:(NSPopUpButton *)p {
    [self saveKey:p.identifier value:p.selectedItem.representedObject];
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPage:self.page]; });   // subtitles describe the current choice
}

- (void)buildTaskbar {
    CTaskbar *tb = self.app.taskbar;
    NSDictionary *c = self.app.config;
    [self addHeader:@"Bar" note:nil];
    BOOL top = [c[@"taskbarPosition"] isEqual:@"top"];
    [self addFull:setCard(@[setRow(@"Show the taskbar", @"On your main display, on every Space. Hidden while an app is full screen.", [self switchFor:@"taskbarEnabled" fallback:YES]),
                            setRow(@"Position", top ? @"Just under the menu bar." : @"Along the bottom, above the Dock while the Dock shows.",
                                   [self choice:@[@[@"Bottom", @"bottom"], @[@"Top", @"top"]] key:@"taskbarPosition" fallback:@"bottom"]),
                            setRow(@"Size", nil, [self choice:@[@[@"Compact", @"compact"], @[@"Standard", @"normal"], @[@"Large", @"large"]] key:@"taskbarSize" fallback:@"normal"]),
                            setRow(@"Floating", @"Rounded, with a gap from the screen edge. Off: edge to edge.", [self switchFor:@"taskbarFloating" fallback:YES]),
                            setRow(@"Auto-hide", top ? @"Slides away until the pointer reaches the menu bar." : @"Slides away until the pointer touches the bottom edge.", [self switchFor:@"taskbarAutoHide" fallback:NO])])];
    [self gap];

    NSString *dock = [c[@"taskbarDock"] isKindOfClass:[NSString class]] ? c[@"taskbarDock"] : @"keep";
    NSString *dockNote = [dock isEqualToString:@"off"] ? @"Never shows. Restored when you turn the bar off."
                       : [dock isEqualToString:@"autohide"] ? @"Slides up only when you point at the bottom edge."
                       : @"Left exactly as you set it in System Settings.";
    [self addHeader:@"macOS Dock" note:@"Centre remembers your own Dock settings and puts them back when the taskbar is off or Centre quits."];
    [self addFull:setCard(@[setRow(@"While the taskbar is on, the Dock", dockNote,
                                   [self choice:@[@[@"Stays as it is", @"keep"], @[@"Hides automatically", @"autohide"], @[@"Is turned off", @"off"]] key:@"taskbarDock" fallback:@"keep"])])];
    [self gap];

    [self addHeader:@"Apps" note:nil];
    [self addFull:setCard(@[setRow(@"Show app names", @"Icon and name for each app, like a classic task list.", [self switchFor:@"taskbarLabels" fallback:NO])])];
    [self gap];

    [self addHeader:@"Tray" note:@"Scroll on the speaker to change the volume; click it to mute. Click the clock for a calendar. Right-click anything in the tray for its settings."];
    [self addFull:setCard(@[setRow(@"Now playing", @"Artwork and title; click to play or pause.", [self switchFor:@"taskbarMedia" fallback:YES]),
                            setRow(@"Volume", nil, [self switchFor:@"taskbarVolume" fallback:YES]),
                            setRow(@"Wi-Fi", nil, [self switchFor:@"taskbarWifi" fallback:YES]),
                            setRow(@"Battery", @"Percentage beside the icon.", [self switchFor:@"taskbarBattery" fallback:YES]),
                            setRow(@"Date under the time", nil, [self switchFor:@"taskbarDate" fallback:YES]),
                            setRow(@"24-hour time", nil, [self switchFor:@"taskbar24h" fallback:NO]),
                            setRow(@"Seconds", nil, [self switchFor:@"taskbarSeconds" fallback:NO]),
                            setRow(@"Show desktop button", @"At the far end: hides every app, click again to bring them back.", [self switchFor:@"taskbarDesktop" fallback:YES])])];
    [self gap];
    [self addHeader:@"Pinned apps" note:@"Drag icons on the taskbar to reorder them. Right-click any app there to pin, unpin, hide, quit or jump to one of its windows."];
    NSArray *pins = tb ? [tb pinnedPaths] : @[];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger i = 0; i < pins.count; i++) {
        NSButton *up = [self iconButton:@"chevron.up" tip:@"Move left" action:@selector(moveBarPin:) tag:(NSInteger)i];
        NSButton *down = [self iconButton:@"chevron.down" tip:@"Move right" action:@selector(moveBarPin:) tag:(NSInteger)i];
        NSButton *rm = [self iconButton:@"minus.circle" tip:@"Unpin" action:@selector(removeBarPin:) tag:(NSInteger)i];
        up.identifier = @"up"; down.identifier = @"down"; up.enabled = i > 0; down.enabled = i + 1 < pins.count;
        NSStackView *ctl = [NSStackView stackViewWithViews:@[up, down, rm]]; ctl.spacing = 4;
        NSString *p = pins[i];
        [rows addObject:setRow([[NSFileManager defaultManager] displayNameAtPath:p].stringByDeletingPathExtension, [p.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath], ctl)];
    }
    if (!rows.count) [rows addObject:setRow(@"Nothing pinned", @"Running apps still appear; pin the ones you want to keep.", nil)];
    [self addFull:setCard(rows)];
    [self.pageStack setCustomSpacing:10 afterView:self.pageStack.arrangedSubviews.lastObject];
    NSPopUpButton *add = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [add addItemWithTitle:@"Add App…"];
    for (CItem *a in [self.app.apps sortedArrayUsingComparator:^NSComparisonResult(CItem *x, CItem *y) { return [x.title localizedCaseInsensitiveCompare:y.title]; }]) {
        if (![a.path hasPrefix:@"/"] || [pins containsObject:a.path]) continue;
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:a.title action:@selector(addBarPin:) keyEquivalent:@""]; mi.target = self; mi.representedObject = a.path;
        NSImage *ic = [[[NSWorkspace sharedWorkspace] iconForFile:a.path] copy]; ic.size = NSMakeSize(16, 16); mi.image = ic;
        [add.menu addItem:mi];
    }
    [self.pageStack addArrangedSubview:[self toolbar:@[add, [self button:@"Match the Dock" target:self action:@selector(resetBarPins:)]]]];
}
- (void)moveBarPin:(NSButton *)b {
    NSMutableArray *k = [[self.app.taskbar pinnedPaths] mutableCopy]; NSInteger i = b.tag, j = i + ([b.identifier isEqualToString:@"up"] ? -1 : 1);
    if (i < 0 || j < 0 || i >= (NSInteger)k.count || j >= (NSInteger)k.count) return;
    [k exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j];
    [self.app.taskbar setPinnedPaths:k]; [self showPage:self.page];
}
- (void)removeBarPin:(NSButton *)b {
    NSMutableArray *k = [[self.app.taskbar pinnedPaths] mutableCopy];
    if (b.tag < 0 || b.tag >= (NSInteger)k.count) return;
    [k removeObjectAtIndex:(NSUInteger)b.tag]; [self.app.taskbar setPinnedPaths:k]; [self showPage:self.page];
}
- (void)addBarPin:(NSMenuItem *)mi {
    NSMutableArray *k = [[self.app.taskbar pinnedPaths] mutableCopy];
    if (![k containsObject:mi.representedObject]) [k addObject:mi.representedObject];
    [self.app.taskbar setPinnedPaths:k]; [self showPage:self.page];
}
- (void)resetBarPins:(id)s { [self.app.taskbar setPinnedPaths:[self.app.taskbar defaultPins]]; [self showPage:self.page]; }
#pragma mark Commands and snippets (cards edited in place, saved as you type)

- (NSStackView *)cardStack:(NSArray<NSView *> *)views {
    NSStackView *st = [NSStackView stackViewWithViews:views];
    st.orientation = NSUserInterfaceLayoutOrientationVertical; st.alignment = NSLayoutAttributeLeading; st.spacing = 10;
    st.edgeInsets = NSEdgeInsetsMake(14, 14, 12, 14);
    return st;
}
- (NSView *)wrapInCard:(NSStackView *)st {
    CCard *card = [CCard new]; card.translatesAutoresizingMaskIntoConstraints = NO;
    st.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:st];
    [NSLayoutConstraint activateConstraints:@[[st.leadingAnchor constraintEqualToAnchor:card.leadingAnchor], [st.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
                                              [st.topAnchor constraintEqualToAnchor:card.topAnchor], [st.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]]];
    return card;
}
- (NSScrollView *)scriptView:(NSString *)text ident:(NSString *)ident height:(CGFloat)h mono:(BOOL)mono {
    NSScrollView *sv = [NSTextView scrollableTextView];
    NSTextView *tv = sv.documentView;
    tv.font = mono ? [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular] : [NSFont systemFontOfSize:12.5];
    tv.string = text ?: @""; tv.identifier = ident; tv.delegate = self; tv.richText = NO; tv.allowsUndo = YES;
    tv.automaticQuoteSubstitutionEnabled = NO; tv.automaticDashSubstitutionEnabled = NO; tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO; tv.textContainerInset = NSMakeSize(4, 6);
    // A soft inset well instead of the old bezel: rounded, hairline, a shade off the card.
    BOOL dark = [self.window.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
    sv.borderType = NSNoBorder; sv.drawsBackground = NO; sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.autohidesScrollers = YES; sv.scrollerStyle = NSScrollerStyleOverlay;
    tv.drawsBackground = YES;
    tv.backgroundColor = dark ? [NSColor colorWithSRGBRed:0.112 green:0.117 blue:0.132 alpha:1] : [NSColor colorWithSRGBRed:0.968 green:0.970 blue:0.977 alpha:1];
    tv.insertionPointColor = cAccent();
    sv.wantsLayer = YES; sv.layer.cornerRadius = 8; sv.layer.masksToBounds = YES; sv.layer.borderWidth = 1;
    sv.layer.borderColor = (dark ? [NSColor colorWithWhite:1 alpha:0.09] : [NSColor colorWithWhite:0 alpha:0.10]).CGColor;
    [sv.heightAnchor constraintEqualToConstant:h].active = YES;
    return sv;
}
- (NSPopUpButton *)popup:(NSArray<NSString *> *)titles selected:(NSInteger)sel ident:(NSString *)ident action:(SEL)a {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [p addItemsWithTitles:titles]; [p selectItemAtIndex:MAX(0, sel)];
    p.identifier = ident; p.target = self; p.action = a;
    return p;
}
- (NSTextField *)hint:(NSString *)t {
    NSTextField *h = [NSTextField wrappingLabelWithString:t];
    h.font = [NSFont systemFontOfSize:11]; h.textColor = [NSColor secondaryLabelColor]; h.selectable = NO;
    return h;
}
- (NSMutableDictionary *)entry:(NSString *)cid in:(NSArray<NSMutableDictionary *> *)list {
    for (NSMutableDictionary *d in list) if ([d[@"id"] isEqualToString:cid]) return d;
    return nil;
}

static NSArray *outputModes(void) { return @[@[@"Show result", @"hud"], @[@"Copy result", @"copy"], @[@"Paste result", @"paste"], @[@"Open in Terminal", @"terminal"], @[@"Run silently", @"silent"]]; }
static NSArray *commandTypes(void) { return @[@[@"Shell", @"shell"], @[@"AppleScript", @"applescript"], @[@"Flow", @"flow"]]; }
static NSInteger indexOfValue(NSArray *pairs, NSString *v) { for (NSUInteger i = 0; i < pairs.count; i++) if ([pairs[i][1] isEqualToString:v]) return (NSInteger)i; return 0; }
static NSArray *pairTitles(NSArray *pairs) { NSMutableArray *r = [NSMutableArray new]; for (NSArray *p in pairs) [r addObject:p[0]]; return r; }

- (void)buildCommands {
    [self addHeader:@"Your commands" note:@"A shell or AppleScript script, or a flow that runs several commands in a row. Each one shows up in search, can be pinned to Home and can get its own shortcut. In scripts, {query} is what you type after the command's name and {clipboard} is the clipboard."];
    NSPopUpButton *ex = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [ex addItemWithTitle:@"Add Example"];
    for (NSString *t in @[@"Local IP Address", @"New Note", @"Search Homebrew", @"Restart the Dock", @"Focus (a flow)"]) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:t action:@selector(addExample:) keyEquivalent:@""]; mi.target = self; [ex.menu addItem:mi];
    }
    [self.pageStack addArrangedSubview:[self toolbar:@[[self button:@"New Command" target:self action:@selector(addCommand:)], ex]]];
    [self.pageStack setCustomSpacing:14 afterView:self.pageStack.arrangedSubviews.lastObject];
    if (!self.commands.count) [self addFull:setCard(@[setRow(@"No commands yet", @"Start with an example, or write your own.", nil)])];
    for (NSMutableDictionary *c in self.commands) {
        NSString *cid = c[@"id"], *type = c[@"type"] ?: @"shell";
        BOOL flow = [type isEqualToString:@"flow"];
        NSTextField *name = setField(c[@"name"], @"Name", 220, self, @selector(listFieldChanged:)); name.identifier = [cid stringByAppendingString:@"|name|cmd"];
        NSPopUpButton *tp = [self popup:pairTitles(commandTypes()) selected:indexOfValue(commandTypes(), type) ident:[cid stringByAppendingString:@"|type|cmd"] action:@selector(listPopupChanged:)];
        NSPopUpButton *op = [self popup:pairTitles(outputModes()) selected:indexOfValue(outputModes(), c[@"output"] ?: @"hud") ident:[cid stringByAppendingString:@"|output|cmd"] action:@selector(listPopupChanged:)];
        op.hidden = flow;
        NSStackView *r1 = [NSStackView stackViewWithViews:@[name, tp, op]]; r1.spacing = 8;
        NSTextField *icon = setField(c[@"icon"], @"Icon (SF Symbol name)", 170, self, @selector(listFieldChanged:)); icon.identifier = [cid stringByAppendingString:@"|icon|cmd"];
        NSTextField *kw = setField(c[@"keywords"], @"Other words that find it", 220, self, @selector(listFieldChanged:)); kw.identifier = [cid stringByAppendingString:@"|keywords|cmd"];
        NSImageView *preview = [NSImageView imageViewWithImage:tileImage([self.app iconForCommand:c], flow ? @"Flow" : @"Script")];
        preview.identifier = [cid stringByAppendingString:@"|preview"];
        [preview.widthAnchor constraintEqualToConstant:22].active = YES; [preview.heightAnchor constraintEqualToConstant:22].active = YES;
        NSStackView *r2 = [NSStackView stackViewWithViews:@[preview, icon, kw]]; r2.spacing = 8;
        NSScrollView *script = [self scriptView:c[@"script"] ident:[cid stringByAppendingString:@"|script|cmd"] height:flow ? 104 : 88 mono:YES];
        NSTextField *h = [self hint:flow ? @"One step per line: a command's name (Keep Awake, Show Desktop, your commands, snippets), or  wait 2 · open Notes · quit Slack · paste text · url https://… · shell command. Lines starting with # are notes."
                                         : @"Shell runs in your login shell (Homebrew and your PATH work). Test runs it once now with an empty {query}."];
        NSButton *test = [self button:@"Test" target:self action:@selector(testCommand:)]; test.identifier = cid;
        NSButton *del = [self button:@"Delete" target:self action:@selector(deleteEntry:)]; del.identifier = [cid stringByAppendingString:@"|cmd"];
        NSView *spacer = [NSView new]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *r3 = [NSStackView stackViewWithViews:@[spacer, test, del]]; r3.spacing = 8;
        NSStackView *st = [self cardStack:@[r1, r2, script, h, r3]];
        for (NSView *v in @[script, h, r3]) [v.widthAnchor constraintEqualToAnchor:st.widthAnchor constant:-28].active = YES;
        [self addFull:[self wrapInCard:st]];
        [self.pageStack setCustomSpacing:14 afterView:self.pageStack.arrangedSubviews.lastObject];
    }
}

- (void)buildSnippets {
    [self addHeader:@"Your snippets" note:@"Text you paste anywhere: find it by name or keyword in Centre (type its exact keyword to jump straight to it), or type  snip. Placeholders: {date} {time} {datetime} {weekday} {iso} {clipboard} {uuid}."];
    [self.pageStack addArrangedSubview:[self toolbar:@[[self button:@"New Snippet" target:self action:@selector(addSnippet:)]]]];
    [self.pageStack setCustomSpacing:14 afterView:self.pageStack.arrangedSubviews.lastObject];
    if (!self.snips.count) [self addFull:setCard(@[setRow(@"No snippets yet", @"Addresses, replies, sign-offs — anything you type often.", nil)])];
    for (NSMutableDictionary *s in self.snips) {
        NSString *sid = s[@"id"];
        NSTextField *name = setField(s[@"name"], @"Name", 240, self, @selector(listFieldChanged:)); name.identifier = [sid stringByAppendingString:@"|name|snip"];
        NSTextField *kw = setField(s[@"keyword"], @"Keyword, e.g. ;addr", 150, self, @selector(listFieldChanged:)); kw.identifier = [sid stringByAppendingString:@"|keyword|snip"];
        NSView *spacer = [NSView new]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *del = [self button:@"Delete" target:self action:@selector(deleteEntry:)]; del.identifier = [sid stringByAppendingString:@"|snip"];
        NSStackView *r1 = [NSStackView stackViewWithViews:@[name, kw, spacer, del]]; r1.spacing = 8;
        NSScrollView *text = [self scriptView:s[@"text"] ident:[sid stringByAppendingString:@"|text|snip"] height:84 mono:NO];
        NSStackView *st = [self cardStack:@[r1, text]];
        for (NSView *v in @[r1, text]) [v.widthAnchor constraintEqualToAnchor:st.widthAnchor constant:-28].active = YES;
        [self addFull:[self wrapInCard:st]];
        [self.pageStack setCustomSpacing:14 afterView:self.pageStack.arrangedSubviews.lastObject];
    }
}

- (NSMutableArray *)listFor:(NSString *)which { return [which isEqualToString:@"snip"] ? self.snips : self.commands; }

// Identifiers are "<id>|<field>|cmd" or "<id>|<field>|snip".
- (void)setListValue:(id)v forIdentifier:(NSString *)ident {
    NSArray *p = [ident componentsSeparatedByString:@"|"]; if (p.count != 3) return;
    NSMutableDictionary *d = [self entry:p[0] in:[self listFor:p[2]]]; if (!d) return;
    if ([v isKindOfClass:[NSString class]] && ![v length] && ![p[1] isEqualToString:@"script"] && ![p[1] isEqualToString:@"text"]) [d removeObjectForKey:p[1]];
    else d[p[1]] = v;
    [self scheduleSave];
}
- (void)listFieldChanged:(NSTextField *)f {
    NSString *v = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([f.identifier containsString:@"|name|"] && !v.length) v = @"Untitled";
    NSArray *p = [f.identifier componentsSeparatedByString:@"|"];
    NSString *old = p.count == 3 ? ([self entry:p[0] in:[self listFor:p[2]]][p[1]] ?: @"") : @"";
    if ([old isEqualToString:v]) return;                            // leaving a field unchanged does nothing
    [self setListValue:v forIdentifier:f.identifier];
    if ([p[1] isEqualToString:@"icon"]) {                           // update the preview tile in place (no page rebuild under your cursor)
        NSImageView *pv = (NSImageView *)[self viewWithIdentifier:[p[0] stringByAppendingString:@"|preview"] in:self.doc];
        NSDictionary *c = [self entry:p[0] in:self.commands];
        if (pv && c) pv.image = tileImage([self.app iconForCommand:c], [c[@"type"] isEqual:@"flow"] ? @"Flow" : @"Script");
    }
}
- (void)listPopupChanged:(NSPopUpButton *)p {
    NSArray *pairs = [p.identifier containsString:@"|type|"] ? commandTypes() : outputModes();
    [self setListValue:pairs[(NSUInteger)p.indexOfSelectedItem][1] forIdentifier:p.identifier];
    if ([p.identifier containsString:@"|type|"]) { [self saveLists]; dispatch_async(dispatch_get_main_queue(), ^{ [self showPage:self.page]; }); }   // flows hide the output menu
}
- (void)textDidChange:(NSNotification *)n {
    NSTextView *tv = n.object;
    if (tv.identifier) [self setListValue:[tv.string copy] forIdentifier:tv.identifier];
}
- (void)scheduleSave {
    [self.saveTimer invalidate];
    __weak CSettings *ws = self;
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *t) { ws.saveTimer = nil; [ws saveLists]; }];
}
- (void)saveLists {
    NSMutableDictionary *c = [self.app mutableConfig];
    c[@"commands"] = [self.commands copy]; c[@"snippets"] = [self.snips copy];
    [self.app writeConfig:c];
}

- (void)addCommand:(id)s {
    NSMutableDictionary *c = [@{@"id": shortID(), @"name": @"New Command", @"type": @"shell", @"script": @"", @"output": @"hud"} mutableCopy];
    [self.commands insertObject:c atIndex:0]; [self saveLists];
    self.focusID = [c[@"id"] stringByAppendingString:@"|name|cmd"];
    [self showPage:self.page];
}
- (void)addExample:(NSMenuItem *)mi {
    NSDictionary *ex = @{
        @"Local IP Address": @{@"name": @"Local IP Address", @"type": @"shell", @"script": @"ipconfig getifaddr en0 || ipconfig getifaddr en1", @"output": @"copy", @"icon": @"wifi", @"keywords": @"ip address network"},
        @"New Note": @{@"name": @"New Note", @"type": @"applescript", @"output": @"hud", @"icon": @"note.text", @"keywords": @"notes write jot",
                       @"script": @"tell application \"Notes\"\n\tmake new note with properties {body:{query}}\nend tell\nreturn \"Note saved\""},
        @"Search Homebrew": @{@"name": @"Brew Search", @"type": @"shell", @"script": @"brew search {query}", @"output": @"terminal", @"icon": @"mug", @"keywords": @"homebrew install package"},
        @"Restart the Dock": @{@"name": @"Restart Dock", @"type": @"shell", @"script": @"killall Dock", @"output": @"silent", @"icon": @"dock.rectangle"},
        @"Focus (a flow)": @{@"name": @"Focus", @"type": @"flow", @"icon": @"scope", @"keywords": @"deep work concentrate",
                             @"script": @"# Clear the decks and keep the Mac awake\nShow Desktop\nKeep Awake\nopen Notes"} };
    NSMutableDictionary *c = [ex[mi.title] mutableCopy]; if (!c) return;
    c[@"id"] = shortID();
    [self.commands insertObject:c atIndex:0]; [self saveLists]; [self showPage:self.page];
}
- (void)addSnippet:(id)s {
    NSMutableDictionary *n = [@{@"id": shortID(), @"name": @"New Snippet", @"keyword": @"", @"text": @""} mutableCopy];
    [self.snips insertObject:n atIndex:0]; [self saveLists];
    self.focusID = [n[@"id"] stringByAppendingString:@"|name|snip"];
    [self showPage:self.page];
}
- (void)testCommand:(NSButton *)b {
    [self.window makeFirstResponder:nil];
    if (self.saveTimer) { [self.saveTimer invalidate]; self.saveTimer = nil; [self saveLists]; }
    NSDictionary *c = [self entry:b.identifier in:self.commands]; if (c) [self.app runCustom:c arg:@""];
}
- (void)deleteEntry:(NSButton *)b {
    NSArray *p = [b.identifier componentsSeparatedByString:@"|"]; if (p.count != 2) return;
    NSMutableArray *list = [self listFor:p[1]];
    NSMutableDictionary *d = [self entry:p[0] in:list]; if (!d) return;
    NSAlert *al = [NSAlert new];
    al.messageText = [NSString stringWithFormat:@"Delete “%@”?", d[@"name"] ?: d[@"keyword"] ?: @"this"];
    al.informativeText = @"Its pin and shortcut go too.";
    [al addButtonWithTitle:@"Delete"]; [al addButtonWithTitle:@"Cancel"];
    if (@available(macOS 11.0, *)) al.buttons.firstObject.hasDestructiveAction = YES;
    [al beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        [list removeObject:d];
        NSString *key = [([p[1] isEqualToString:@"snip"] ? @"snip:" : @"custom:") stringByAppendingString:p[0]];
        NSMutableDictionary *c = [self.app mutableConfig];
        c[@"commands"] = [self.commands copy]; c[@"snippets"] = [self.snips copy];
        NSMutableArray *pins = [[self.app pinnedKeys] mutableCopy]; [pins removeObject:key]; c[@"pinned"] = pins;
        NSMutableDictionary *hk = [([c[@"hotkeys"] isKindOfClass:[NSDictionary class]] ? c[@"hotkeys"] : @{}) mutableCopy]; [hk removeObjectForKey:key]; c[@"hotkeys"] = hk;
        [self.app writeConfig:c];
        [self showPage:self.page];
    }];
}

#pragma mark Shortcuts

- (void)buildShortcuts {
    NSDictionary *hk = [self.app.config[@"hotkeys"] isKindOfClass:[NSDictionary class]] ? self.app.config[@"hotkeys"] : @{};
    [self addHeader:@"Command shortcuts" note:@"Run anything without opening Centre: a command, your script or flow, a snippet, a text transform, an app or a folder. Works everywhere while Centre is running. Irreversible commands need the shortcut twice."];
    NSArray *keys = [hk.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[self.app titleForKey:a] localizedCaseInsensitiveCompare:[self.app titleForKey:b]]; }];
    NSMutableArray *rows = [NSMutableArray new];
    __weak CSettings *ws = self;
    CHotkeyButton *toRecord = nil;
    for (NSString *key in keys) {
        CHotkeyButton *b = [CHotkeyButton buttonWithTitle:@"" target:nil action:nil];
        b.target = b; b.action = @selector(toggleRecord:); b.bezelStyle = NSBezelStyleRounded;
        b.spec = [hk[key] isKindOfClass:[NSString class]] ? hk[key] : @"";
        b.onRecording = ^(BOOL on) {
            if (on) { [ws.app unregisterHotKey]; [ws.app unregisterCommandHotKeys]; } else { [ws.app registerHotKey]; [ws.app registerCommandHotKeys]; } };
        b.onChange = ^(NSString *spec) { [ws setShortcut:spec forKey:key]; };
        [b refresh];
        NSButton *rm = [self iconButton:@"minus.circle" tip:@"Remove shortcut" action:@selector(removeShortcut:) tag:0]; rm.identifier = key;
        NSStackView *ctl = [NSStackView stackViewWithViews:@[b, rm]]; ctl.spacing = 6;
        BOOL taken = [self.app.hotKeyFailures containsObject:key];
        [rows addObject:setRow([self.app titleForKey:key], taken ? @"⚠︎ Another app owns this shortcut — record a different one." : keyKind(key), ctl)];
        if ([key isEqualToString:self.recordKey]) toRecord = b;
    }
    if (!rows.count) [rows addObject:setRow(@"No shortcuts yet", @"Pick something below, then press the keys you want.", nil)];
    [self addFull:setCard(rows)];
    [self.pageStack setCustomSpacing:10 afterView:self.pageStack.arrangedSubviews.lastObject];
    [self.pageStack addArrangedSubview:[self toolbar:@[[self catalogPopup:@"Add Shortcut…" action:@selector(addShortcut:)]]]];
    self.recordKey = nil;
    if (toRecord) dispatch_async(dispatch_get_main_queue(), ^{ [toRecord toggleRecord:nil]; });
}
- (void)setShortcut:(NSString *)spec forKey:(NSString *)key {
    NSMutableDictionary *hk = [([self.app.config[@"hotkeys"] isKindOfClass:[NSDictionary class]] ? self.app.config[@"hotkeys"] : @{}) mutableCopy];
    hk[key] = spec ?: @"";
    [self saveKey:@"hotkeys" value:hk];
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPage:self.page]; });   // shows a conflict warning if macOS refused it
}
- (void)addShortcut:(NSMenuItem *)mi {
    NSString *key = mi.representedObject;
    NSMutableDictionary *hk = [([self.app.config[@"hotkeys"] isKindOfClass:[NSDictionary class]] ? self.app.config[@"hotkeys"] : @{}) mutableCopy];
    if (!hk[key]) hk[key] = @"";
    [self saveKey:@"hotkeys" value:hk];
    self.recordKey = key;
    [self showPage:self.page];
}
- (void)removeShortcut:(NSButton *)b {
    NSMutableDictionary *hk = [([self.app.config[@"hotkeys"] isKindOfClass:[NSDictionary class]] ? self.app.config[@"hotkeys"] : @{}) mutableCopy];
    [hk removeObjectForKey:b.identifier];
    [self saveKey:@"hotkeys" value:hk];
    [self showPage:self.page];
}

#pragma mark Tables

- (NSView *)tableCardTag:(NSInteger)tag columns:(NSArray *)cols height:(CGFloat)h {
    CCard *card = [CCard new]; card.translatesAutoresizingMaskIntoConstraints = NO;

    // Column titles
    CSetRow *head = [CSetRow new]; head.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat x = 16;
    for (NSArray *c in cols) {
        NSTextField *l = setLabel(c[0], 11, NSFontWeightMedium, [NSColor secondaryLabelColor]);
        l.frame = NSMakeRect(x, 7, [c[1] doubleValue], 14); [head addSubview:l];
        x += [c[1] doubleValue] + 10;
    }

    NSTableView *tv = [NSTableView new]; tv.tag = tag; tv.dataSource = self; tv.delegate = self;
    tv.headerView = nil; tv.rowHeight = 22; tv.intercellSpacing = NSMakeSize(10, 6);
    tv.backgroundColor = [NSColor clearColor]; tv.gridStyleMask = NSTableViewGridNone; tv.focusRingType = NSFocusRingTypeNone;
    tv.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    if (@available(macOS 11.0, *)) tv.style = NSTableViewStylePlain;
    for (NSUInteger i = 0; i < cols.count; i++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
        col.width = [cols[i][1] doubleValue]; col.editable = YES;
        NSTextFieldCell *cell = [[NSTextFieldCell alloc] initTextCell:@""];
        cell.font = [NSFont systemFontOfSize:12.5]; cell.lineBreakMode = NSLineBreakByTruncatingMiddle; cell.editable = YES;
        col.dataCell = cell;
        [tv addTableColumn:col];
    }
    NSScrollView *sv = [NSScrollView new]; sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.documentView = tv; sv.drawsBackground = NO; sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES; sv.borderType = NSNoBorder;

    // +/- bar
    CSetRow *bar = [CSetRow new]; bar.translatesAutoresizingMaskIntoConstraints = NO; bar.topLine = YES;
    NSButton *add = [NSButton buttonWithImage:symSized(@"plus", 12, NSFontWeightMedium) target:self action:@selector(addRow:)];
    NSButton *rem = [NSButton buttonWithImage:symSized(@"minus", 12, NSFontWeightMedium) target:self action:@selector(removeRow:)];
    for (NSButton *b in @[add, rem]) { b.bordered = NO; b.tag = tag; b.contentTintColor = [NSColor secondaryLabelColor]; b.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:b]; }
    NSTextField *hint = setLabel(tag == 3 ? @"" : @"Double-click to edit · ↩ to confirm", 10.5, NSFontWeightRegular, [NSColor tertiaryLabelColor]);
    hint.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:hint];

    head.topLine = NO;
    CSetRow *headLine = [CSetRow new]; headLine.translatesAutoresizingMaskIntoConstraints = NO; headLine.topLine = YES;
    for (NSView *v in @[head, headLine, sv, bar]) [card addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [head.topAnchor constraintEqualToAnchor:card.topAnchor], [head.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [head.trailingAnchor constraintEqualToAnchor:card.trailingAnchor], [head.heightAnchor constraintEqualToConstant:28],
        [headLine.topAnchor constraintEqualToAnchor:head.bottomAnchor], [headLine.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:-14],
        [headLine.trailingAnchor constraintEqualToAnchor:card.trailingAnchor], [headLine.heightAnchor constraintEqualToConstant:1],
        [sv.topAnchor constraintEqualToAnchor:headLine.bottomAnchor constant:2], [sv.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:6],
        [sv.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-6], [sv.heightAnchor constraintEqualToConstant:h],
        [bar.topAnchor constraintEqualToAnchor:sv.bottomAnchor constant:2], [bar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:-14],
        [bar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor], [bar.heightAnchor constraintEqualToConstant:32],
        [bar.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [add.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:26], [add.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [rem.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:14], [rem.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-14], [hint.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor]]];
    self.tables[@(tag)] = tv;
    [tv reloadData];
    return card;
}

- (NSMutableArray *)rowsForTag:(NSInteger)t { return t == 1 ? self.prefixes : t == 2 ? self.links : self.folders; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)[self rowsForTag:t.tag].count; }
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    NSArray *row = [self rowsForTag:t.tag][r]; NSInteger i = c.identifier.integerValue;
    return i < (NSInteger)row.count ? row[i] : @"";
}
- (void)tableView:(NSTableView *)t setObjectValue:(id)v forTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    NSMutableArray *rows = [self rowsForTag:t.tag];
    if (r < 0 || r >= (NSInteger)rows.count) return;
    NSMutableArray *row = rows[r]; NSInteger i = c.identifier.integerValue;
    NSString *s = [[v description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.tag == 1 && i == 0) s = [[s lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
    while ((NSInteger)row.count <= i) [row addObject:@""];
    row[i] = s;
    [self saveTables];
}

- (void)addRow:(NSButton *)b {
    NSInteger t = b.tag;
    if (t == 3) {
        NSOpenPanel *p = [NSOpenPanel openPanel];
        p.canChooseDirectories = YES; p.canChooseFiles = NO; p.allowsMultipleSelection = YES; p.prompt = @"Add Folder";
        [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
            if (r != NSModalResponseOK) return;
            for (NSURL *u in p.URLs) [self.folders addObject:[@[[u.path stringByAbbreviatingWithTildeInPath]] mutableCopy]];
            [self.tables[@3] reloadData]; [self saveTables];
        }];
        return;
    }
    NSMutableArray *rows = [self rowsForTag:t];
    [rows addObject:[(t == 1 ? @[@"", @"https://"] : @[@"", @"https://"]) mutableCopy]];
    NSTableView *tv = self.tables[@(t)]; [tv reloadData];
    NSInteger r = (NSInteger)rows.count - 1;
    [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)r] byExtendingSelection:NO];
    [tv scrollRowToVisible:r];
    [tv editColumn:0 row:r withEvent:nil select:YES];
}
- (void)removeRow:(NSButton *)b {
    NSTableView *tv = self.tables[@(b.tag)]; NSInteger r = tv.selectedRow;
    NSMutableArray *rows = [self rowsForTag:b.tag];
    if (r < 0 || r >= (NSInteger)rows.count) { NSBeep(); return; }
    [tv abortEditing];
    [rows removeObjectAtIndex:(NSUInteger)r];
    [tv reloadData]; [self saveTables];
}

#pragma mark Saving

- (void)saveKey:(NSString *)k value:(id)v {
    NSMutableDictionary *c = [self.app mutableConfig];
    if (v) c[k] = v; else [c removeObjectForKey:k];
    [self.app writeConfig:c];
}
- (void)saveTables {
    NSMutableDictionary *c = [self.app mutableConfig];
    NSMutableDictionary *sp = [NSMutableDictionary new];
    for (NSArray *r in self.prefixes) { NSString *k = r.count > 0 ? r[0] : @"", *u = r.count > 1 ? r[1] : @""; if (k.length && u.length > 8) sp[k] = u; }
    c[@"searchPrefixes"] = sp;
    NSMutableArray *links = [NSMutableArray new];
    for (NSArray *r in self.links) { NSString *n = r.count > 0 ? r[0] : @"", *u = r.count > 1 ? r[1] : @""; if (n.length && u.length > 8) [links addObject:@{@"name": n, @"url": u}]; }
    c[@"links"] = links;
    NSMutableArray *folders = [NSMutableArray new];
    for (NSArray *r in self.folders) { NSString *f = r.count > 0 ? r[0] : @""; if (f.length) [folders addObject:f]; }
    c[@"appFolders"] = folders;                            // empty means "the default folders" (see -scanApps)
    [self.app writeConfig:c];
}

- (void)switchChanged:(NSSwitch *)s {
    [self saveKey:s.identifier value:@(s.state == NSControlStateValueOn)];
    if ([s.identifier isEqualToString:@"mediaYTM"]) [self showPage:self.page];   // reveal or hide the browser row
}
- (void)loginChanged:(NSSwitch *)s {
    BOOL on = s.state == NSControlStateValueOn;
    [self saveKey:@"launchAtLogin" value:@(on)];
    [self.app setLaunchAtLogin:on];
}
- (void)engineChanged:(NSPopUpButton *)p {
    NSArray *eng = searchEngines(); NSInteger i = p.indexOfSelectedItem;
    BOOL custom = (i == (NSInteger)eng.count - 1);
    self.customURL.enabled = custom;
    if (custom) { [self.window makeFirstResponder:self.customURL]; return; }
    self.customURL.stringValue = eng[i][1];
    [self saveKey:@"webSearch" value:eng[i][1]];
}
- (void)customChanged:(NSTextField *)f {
    NSString *s = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!f.enabled || ![s containsString:@"%s"]) return;
    [self saveKey:@"webSearch" value:s];
}
- (void)ytmBrowserChanged:(NSTextField *)f {
    NSString *s = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length) [self saveKey:@"ytmBrowser" value:s];
}
- (void)editorChanged:(NSTextField *)f {
    NSString *s = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length) [self saveKey:@"editor" value:s];
}
- (void)revealConfig:(id)s { [[NSWorkspace sharedWorkspace] selectFile:self.app.configPath inFileViewerRootedAtPath:@""]; }
- (void)rescan:(NSButton *)b { [self.app scanApps]; b.title = @"Done"; b.enabled = NO; }
- (void)resetUsage:(NSButton *)b { [self.app resetUsage]; b.title = @"Done"; b.enabled = NO; }

#pragma mark Window

- (void)windowDidResignKey:(NSNotification *)n { [self stopRecordersIn:self.doc]; [self.hotkeyButton stop]; }
- (void)flushEdits {
    [self.window makeFirstResponder:nil];
    if (self.saveTimer) { [self.saveTimer invalidate]; self.saveTimer = nil; [self saveLists]; }
}
- (void)windowWillClose:(NSNotification *)n {
    [self stopRecordersIn:self.doc];
    [self.hotkeyButton stop];
    [self.window makeFirstResponder:nil];            // ends any edit in progress so it gets saved
    if (self.saveTimer) { [self.saveTimer invalidate]; self.saveTimer = nil; [self saveLists]; }
}
- (void)windowDidBecomeKey:(NSNotification *)n {
    // Coming back from System Settings: refresh the Permissions statuses (scroll position is kept).
    if (self.page == pageIndex(@"Permissions") && self.pageStack) [self showPage:self.page];
}
@end

