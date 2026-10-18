// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Settings.h"
#import "App.h"

#pragma mark - Settings window (System Settings–style)

@interface CFlipView : NSView @end
@implementation CFlipView
- (BOOL)isFlipped { return YES; }
@end

// Rounded, hairline-bordered group box. Colors resolve per appearance at draw time.
@interface CCard : NSView @end
@implementation CCard
- (void)drawRect:(NSRect)r {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [[[NSColor labelColor] colorWithAlphaComponent:0.045] setFill]; [p fill];
    [[[NSColor labelColor] colorWithAlphaComponent:0.10] setStroke]; p.lineWidth = 1; [p stroke];
}
@end

// One row inside a card, with an inset hairline above it (except the first row).
@interface CSetRow : NSView
@property (nonatomic) BOOL topLine;
@end
@implementation CSetRow
- (void)drawRect:(NSRect)r {
    if (!self.topLine) return;
    [[[NSColor labelColor] colorWithAlphaComponent:0.09] setFill];
    NSRectFillUsingOperation(NSMakeRect(14, self.bounds.size.height - 1, self.bounds.size.width - 14, 1), NSCompositingOperationSourceOver);
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

// Sidebar item: graphite icon tile + label, soft selection pill.
@interface CNavItem : NSView
@property (nonatomic, copy) NSString *title, *symbol, *kind;
@property (nonatomic) BOOL selected;
@property (nonatomic, copy) void (^onClick)(void);
@end
@implementation CNavItem
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
    NSRect b = self.bounds;
    if (self.selected) {
        [cSelFill(self) setFill]; [[NSBezierPath bezierPathWithRoundedRect:b xRadius:8 yRadius:8] fill];
    }
    NSRect tile = NSMakeRect(8, floor((b.size.height - 22) / 2), 22, 22);
    [tileImage(self.symbol, self.kind) drawInRect:tile fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSDictionary *at = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:self.selected ? NSFontWeightMedium : NSFontWeightRegular],
                         NSForegroundColorAttributeName: [NSColor labelColor]};
    NSSize ts = [self.title sizeWithAttributes:at];
    [self.title drawAtPoint:NSMakePoint(40, (b.size.height - ts.height) / 2) withAttributes:at];
}
- (void)mouseDown:(NSEvent *)e { if (self.onClick) self.onClick(); }
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
- (void)refresh { self.title = self.monitor ? @"Press shortcut…  (esc cancels)" : prettyHotkey(self.spec ?: @"cmd+space"); }
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
        NSTextField *s = setLabel(sub, 11, NSFontWeightRegular, [NSColor secondaryLabelColor]);
        s.lineBreakMode = NSLineBreakByTruncatingTail;
        [s setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [texts addArrangedSubview:s];
    }
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    [texts setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r addSubview:texts];
    NSMutableArray *cs = [@[[r.heightAnchor constraintEqualToConstant:sub.length ? 54 : 44],
                            [texts.leadingAnchor constraintEqualToAnchor:r.leadingAnchor constant:14],
                            [texts.centerYAnchor constraintEqualToAnchor:r.centerYAnchor]] mutableCopy];
    if (control) {
        control.translatesAutoresizingMaskIntoConstraints = NO;
        [control setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [r addSubview:control];
        [cs addObjectsFromArray:@[[control.trailingAnchor constraintEqualToAnchor:r.trailingAnchor constant:-14],
                                  [control.centerYAnchor constraintEqualToAnchor:r.centerYAnchor],
                                  [control.leadingAnchor constraintGreaterThanOrEqualToAnchor:texts.trailingAnchor constant:16]]];
    } else {
        [cs addObject:[texts.trailingAnchor constraintLessThanOrEqualToAnchor:r.trailingAnchor constant:-14]];
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

@interface CSettings ()
@property (nonatomic, weak) CApp *app;
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

static NSArray *settingsPages(void) {
    return @[@[@"General", @"gearshape.fill", @"System"], @[@"Search", @"magnifyingglass", @"Web"],
             @[@"Quick Links", @"link", @"Link"], @[@"Permissions", @"hand.raised.fill", @"Window"],
             @[@"Advanced", @"wrench.and.screwdriver.fill", @"Centre"]];
}
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
}

- (void)buildWindow {
    const CGFloat W = 780, H = 560, SB = 214;
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
    icon.frame = NSMakeRect(16, 44, 34, 34); icon.imageScaling = NSImageScaleProportionallyUpOrDown; [sc addSubview:icon];
    NSTextField *name = setLabel(@"Centre", 14, NSFontWeightSemibold, nil); name.frame = NSMakeRect(56, 45, 150, 18); [sc addSubview:name];
    NSTextField *ver = setLabel(@"Version 1.0", 11, NSFontWeightRegular, [NSColor secondaryLabelColor]); ver.frame = NSMakeRect(56, 63, 150, 14); [sc addSubview:ver];

    NSMutableArray *items = [NSMutableArray new];
    NSArray *pages = settingsPages();
    __weak CSettings *ws = self;
    for (NSUInteger i = 0; i < pages.count; i++) {
        CNavItem *it = [[CNavItem alloc] initWithFrame:NSMakeRect(10, 100 + i * 32, SB - 20, 30)];
        it.title = pages[i][0]; it.symbol = pages[i][1]; it.kind = pages[i][2];
        it.onClick = ^{ [ws showPage:(NSInteger)i]; };
        [sc addSubview:it]; [items addObject:it];
    }
    self.nav = items;

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
    [self.window makeFirstResponder:nil];
    self.page = i;
    for (NSUInteger k = 0; k < self.nav.count; k++) { self.nav[k].selected = ((NSInteger)k == i); [self.nav[k] setNeedsDisplay:YES]; }
    [self.pageStack removeFromSuperview]; [self.tables removeAllObjects];
    self.enginePopup = nil; self.customURL = nil; self.hotkeyButton = nil;

    NSStackView *st = [NSStackView new];
    st.orientation = NSUserInterfaceLayoutOrientationVertical; st.alignment = NSLayoutAttributeLeading; st.spacing = 8;
    st.edgeInsets = NSEdgeInsetsMake(46, 32, 36, 32); st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.doc addSubview:st];
    [NSLayoutConstraint activateConstraints:@[[st.topAnchor constraintEqualToAnchor:self.doc.topAnchor],
                                              [st.leadingAnchor constraintEqualToAnchor:self.doc.leadingAnchor],
                                              [st.trailingAnchor constraintEqualToAnchor:self.doc.trailingAnchor],
                                              [st.bottomAnchor constraintEqualToAnchor:self.doc.bottomAnchor]]];
    self.pageStack = st;
    NSTextField *title = setLabel(settingsPages()[i][0], 22, NSFontWeightBold, nil);
    [st addArrangedSubview:title]; [st setCustomSpacing:20 afterView:title];
    switch (i) {
        case 0: [self buildGeneral]; break;
        case 1: [self buildSearch]; break;
        case 2: [self buildLinks]; break;
        case 3: [self buildPermissions]; break;
        default: [self buildAdvanced]; break;
    }
    [self.doc layoutSubtreeIfNeeded];
    [self.doc scrollPoint:keep];
}

- (void)addFull:(NSView *)v {
    [self.pageStack addArrangedSubview:v];
    [v.widthAnchor constraintEqualToAnchor:self.pageStack.widthAnchor constant:-64].active = YES;
}
- (void)addHeader:(NSString *)t note:(NSString *)n {
    NSTextField *h = setLabel(t, 13, NSFontWeightSemibold, nil);
    [self.pageStack addArrangedSubview:h];
    if (n.length) {
        [self.pageStack setCustomSpacing:3 afterView:h];
        NSTextField *nt = [NSTextField wrappingLabelWithString:n];
        nt.font = [NSFont systemFontOfSize:11.5]; nt.textColor = [NSColor secondaryLabelColor]; nt.selectable = NO;
        [self addFull:nt];
        [self.pageStack setCustomSpacing:10 afterView:nt];
    } else {
        [self.pageStack setCustomSpacing:8 afterView:h];
    }
}
- (void)gap { NSView *last = self.pageStack.arrangedSubviews.lastObject; if (last) [self.pageStack setCustomSpacing:28 afterView:last]; }

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
    hk.onRecording = ^(BOOL on) { if (on) [ws.app unregisterHotKey]; else [ws.app registerHotKey]; };
    hk.onChange = ^(NSString *s) { [ws saveKey:@"hotkey" value:s]; };
    [hk refresh]; [hk.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
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
    [self addFull:setCard(@[setRow(@"Most used apps", @"Icon strip below the search field.", [self switchFor:@"showMostUsed" fallback:YES]),
                            setRow(@"Suggestions", @"Quick actions, clipboard and recents under Most Used.", [self switchFor:@"showHomeExtras" fallback:YES]),
                            setRow(@"Clipboard history", @"Last 100 copied texts, memory only. Type clip.", [self switchFor:@"clipboardHistory" fallback:YES]),
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
    runShell([NSString stringWithFormat:@"cd '%@' && /bin/bash ./setup-signing.sh 2>&1 | tee signing.log", [self.app sourceDir]], ^(NSString *out) {
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
            if (!ws || ws.page != 3 || !ws.window.visible) { [t invalidate]; return; }
            if (AXIsProcessTrusted()) { [t invalidate]; [ws showPage:3]; }
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
    NSMutableDictionary *c = [self.app.config mutableCopy] ?: [NSMutableDictionary new];
    if (v) c[k] = v; else [c removeObjectForKey:k];
    [self.app writeConfig:c];
}
- (void)saveTables {
    NSMutableDictionary *c = [self.app.config mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *sp = [NSMutableDictionary new];
    for (NSArray *r in self.prefixes) { NSString *k = r.count > 0 ? r[0] : @"", *u = r.count > 1 ? r[1] : @""; if (k.length && u.length > 8) sp[k] = u; }
    c[@"searchPrefixes"] = sp;
    NSMutableArray *links = [NSMutableArray new];
    for (NSArray *r in self.links) { NSString *n = r.count > 0 ? r[0] : @"", *u = r.count > 1 ? r[1] : @""; if (n.length && u.length > 8) [links addObject:@{@"name": n, @"url": u}]; }
    c[@"links"] = links;
    NSMutableArray *folders = [NSMutableArray new];
    for (NSArray *r in self.folders) { NSString *f = r.count > 0 ? r[0] : @""; if (f.length) [folders addObject:f]; }
    if (folders.count) c[@"appFolders"] = folders;
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

- (void)windowWillClose:(NSNotification *)n { [self.hotkeyButton stop]; [self.window makeFirstResponder:nil]; }
- (void)windowDidBecomeKey:(NSNotification *)n {
    // Coming back from System Settings: refresh the Permissions statuses (scroll position is kept).
    if (self.page == 3 && self.pageStack) [self showPage:3];
}
@end

