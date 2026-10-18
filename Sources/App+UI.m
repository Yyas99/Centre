// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"

@implementation CApp (UI)

#pragma mark UI

- (void)buildUI {
    NSRect f = NSMakeRect(0, 0, kW, kSearchH);
    CPanel *p = [[CPanel alloc] initWithContentRect:f styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    p.level = NSStatusWindowLevel + 1;
    p.opaque = NO; p.backgroundColor = [NSColor clearColor]; p.hasShadow = YES;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
    p.hidesOnDeactivate = NO; p.delegate = self; p.animationBehavior = NSWindowAnimationBehaviorUtilityWindow;
    p.movableByWindowBackground = YES;
    p.acceptsMouseMovedEvents = YES;

    NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:f];
    fx.material = NSVisualEffectMaterialHUDWindow;
    if (@available(macOS 10.14, *)) fx.material = NSVisualEffectMaterialHUDWindow;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow; fx.state = NSVisualEffectStateActive;
    CGFloat R = kRadius;
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(R * 2 + 2, R * 2 + 2) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] set]; [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:R yRadius:R] fill]; return YES; }];
    mask.capInsets = NSEdgeInsetsMake(R, R, R, R); mask.resizingMode = NSImageResizingModeStretch;
    fx.maskImage = mask;
    fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    p.contentView = fx; self.fx = fx;

    CBackdrop *bd = [[CBackdrop alloc] initWithFrame:f]; bd.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [fx addSubview:bd];

    NSImageView *si = [[NSImageView alloc] initWithFrame:NSMakeRect(22, 0, 18, 18)];
    NSImage *mg = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
    si.image = [mg imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium]];
    si.contentTintColor = [NSColor secondaryLabelColor]; si.imageScaling = NSImageScaleProportionallyUpOrDown;
    [fx addSubview:si]; self.searchIcon = si;

    CField *t = [[CField alloc] initWithFrame:NSMakeRect(54, 0, kW - 54 - 22, 28)];
    t.font = [NSFont systemFontOfSize:21 weight:NSFontWeightRegular];
    t.bezeled = NO; t.bordered = NO; t.drawsBackground = NO; t.focusRingType = NSFocusRingTypeNone;
    t.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Search apps, files and commands" attributes:@{NSFontAttributeName: t.font, NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]}];
    t.delegate = self;
    [fx addSubview:t]; self.field = t;
    CChip *chip = [[CChip alloc] initWithFrame:NSZeroRect]; chip.hidden = YES;
    [fx addSubview:chip]; self.chip = chip;

    NSTextField *esc = [NSTextField labelWithString:@""]; esc.hidden = YES;   // kept for layout compatibility
    [fx addSubview:esc]; self.escPill = esc;

    CHairline *sep = [[CHairline alloc] initWithFrame:NSMakeRect(0, 0, kW, 1)];
    [fx addSubview:sep]; self.separator = sep;

    NSTextField *gt = [NSTextField labelWithAttributedString:sectionTitle(@"Most Used")];
    [fx addSubview:gt]; self.gridTitle = gt;
    CGridView *grid = [[CGridView alloc] initWithFrame:NSMakeRect(0, 0, kW, kCellH)];
    __weak CApp *ws = self;
    grid.iconFor = ^NSImage *(CItem *i) { return [ws iconFor:i]; };
    grid.onPick = ^(NSInteger i) { ws.selected = i; [ws runSelected:NO]; };
    grid.onHover = ^(NSInteger i) { [ws hoverSelect:i]; };
    [fx addSubview:grid]; self.grid = grid;

    CQuickStrip *qs = [[CQuickStrip alloc] initWithFrame:NSMakeRect(0, 0, kW, kQuickH)]; qs.selected = -1;
    qs.iconFor = ^NSImage *(CItem *i) { return [ws iconFor:i]; };
    qs.onPick = ^(NSInteger i) { ws.selected = ws.homeApps + i; [ws runSelected:NO]; };
    qs.onHover = ^(NSInteger i) { [ws hoverSelect:ws.homeApps + i]; };
    [fx addSubview:qs]; self.quick = qs;
    CHomeList *hl = [[CHomeList alloc] initWithFrame:NSMakeRect(0, 0, kW, 10)]; hl.selected = -1;
    hl.iconFor = ^NSImage *(CItem *i) { return [ws iconFor:i]; };
    hl.onPick = ^(NSInteger i) { ws.selected = i; [ws runSelected:NO]; };
    hl.onHover = ^(NSInteger i) { [ws hoverSelect:i]; };
    [fx addSubview:hl]; self.homeList = hl;

    CMediaView *mv = [[CMediaView alloc] initWithFrame:NSMakeRect(0, 0, kW, kMediaH)];
    mv.onCommand = ^(int cmd) { [ws mediaCommand:cmd]; };
    mv.onSeek = ^(double f) { [ws mediaSeek:f]; };
    mv.hidden = YES;
    [fx addSubview:mv]; self.media = mv;

    CFooterBar *footer = [[CFooterBar alloc] initWithFrame:NSMakeRect(0, 0, kW, kFooterH)];
    CHairline *fl = [[CHairline alloc] initWithFrame:NSMakeRect(0, kFooterH - 1, kW, 1)];
    [footer addSubview:fl];
    NSImageView *fi = [NSImageView imageViewWithImage:[NSApp applicationIconImage]];
    fi.frame = NSMakeRect(kInset - 1, floor((kFooterH - 18) / 2), 18, 18); fi.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSTextField *fL = [NSTextField labelWithString:@"Centre"];
    fL.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; fL.textColor = [NSColor tertiaryLabelColor];
    fL.frame = NSMakeRect(kInset + 24, floor((kFooterH - 16) / 2), 200, 16);
    NSTextField *fR = [NSTextField labelWithString:@""]; fR.hidden = YES;
    CKeyHints *hints = [[CKeyHints alloc] initWithFrame:NSMakeRect(120, 0, kW - 120 - 18, kFooterH - 1)];
    for (NSView *v in @[fi, fL, fR, hints]) [footer addSubview:v];
    [fx addSubview:footer]; self.footer = footer; self.footerLeft = fL; self.footerRight = fR; self.hints = hints; self.footerIcon = fi;

    CTable *tv = [[CTable alloc] initWithFrame:NSMakeRect(0, 0, kW, 10)];
    tv.onHover = ^(NSInteger r) { [ws hoverSelect:r]; };
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"]; col.width = kW; [tv addTableColumn:col];
    tv.headerView = nil; tv.rowHeight = kRowH; tv.backgroundColor = [NSColor clearColor];
    tv.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone; tv.intercellSpacing = NSMakeSize(0, 0);
    tv.dataSource = self; tv.delegate = self; tv.target = self; tv.action = @selector(rowClicked:);
    if (@available(macOS 11.0, *)) tv.style = NSTableViewStylePlain;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kW, 10)];
    sv.documentView = tv; sv.drawsBackground = NO; sv.hasVerticalScroller = NO; sv.hasHorizontalScroller = NO;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; sv.verticalScrollElasticity = NSScrollElasticityNone;
    [fx addSubview:sv]; self.scroll = sv; self.table = tv;
    CEdgeView *edge = [[CEdgeView alloc] initWithFrame:f]; edge.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [fx addSubview:edge];
    self.panel = p;

    // Holding ⌘ reveals the ⌘1…⌘9 shortcuts on rows and grid cells.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *e) {
        if (!self.panel.keyWindow) return e;
        BOOL cmd = (e.modifierFlags & NSEventModifierFlagCommand) != 0;
        if (cmd != self.cmdHeld) { self.cmdHeld = cmd; [self reloadTable]; }
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        if (!self.panel.keyWindow) return e;
        NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (e.keyCode == 53) {                              // Esc: clear what you typed first, close on the next press
            if (self.field.stringValue.length) { self.field.stringValue = @""; [self refresh]; } else [self hide];
            return nil;
        }
        if ((m & NSEventModifierFlagCommand) && (m & NSEventModifierFlagShift) && [e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"p"]) {
            [self togglePinSelected]; return nil;    // ⇧⌘P pins or unpins the selection to Home
        }
        if ((m & NSEventModifierFlagCommand) && e.charactersIgnoringModifiers.length == 1) {
            unichar c = [e.charactersIgnoringModifiers characterAtIndex:0];
            if (c >= '1' && c <= '9') { NSInteger idx = c - '1'; if (idx < (NSInteger)self.items.count) { self.selected = idx; [self runSelected:NO]; } return nil; }
            if (c == ',') { [self hide]; [self openSettings]; return nil; }
            if (self.field.stringValue.length == 0 && self.hasNow) {
                if (c == 'p') { [self mediaCommand:2]; return nil; }
                if (c == ']') { [self mediaCommand:4]; return nil; }
                if (c == '[') { [self mediaCommand:5]; return nil; }
            }
            if (c == '\r' || e.keyCode == 36) { [self runSelected:YES]; return nil; }
        }
        return e;
    }];
}

- (void)layoutForRows:(NSInteger)rows {
    BOOL home = self.gridMode && rows > 0;
    BOOL showMedia = self.hasNow && self.field.stringValue.length == 0 && ([self ytmMode] || ![self.config[@"showMediaPlayer"] isEqual:@NO]);
    CGFloat mediaH = showMedia ? kMediaH : 0;
    CGFloat appsH = home && self.homeApps > 0 ? kGridH : 0;
    CGFloat quickH = home && self.homeQuick > 0 ? kQuickH : 0;
    CGFloat listH = home ? [self.homeList fittingHeight] : 0;
    CGFloat tailH = (home && quickH > 0 && listH == 0) ? 10 : 0;   // breathing room when the pills are the last row
    CGFloat bodyH = mediaH + (home ? appsH + quickH + listH + tailH : (rows > 0 ? rows * kRowH + 12 : 0));
    CGFloat footH = bodyH > 0 ? kFooterH : 0;
    CGFloat H = kSearchH + bodyH + footH;
    NSRect fr = self.panel.frame;
    CGFloat top = fr.origin.y + fr.size.height;
    NSScreen *scr = self.panel.screen ?: NSScreen.mainScreen;     // tall home screens never run off the bottom
    if (scr && top - H < NSMinY(scr.visibleFrame) + 12) top = MIN(NSMinY(scr.visibleFrame) + 12 + H, NSMaxY(scr.visibleFrame) - 12);
    [self.panel setFrame:NSMakeRect(fr.origin.x, top - H, kW, H) display:YES animate:NO];
    [self.panel invalidateShadow];
    CGFloat sy = H - kSearchH;                                   // bottom of search row
    self.chip.text = self.modeLabel;
    CGFloat chipW = self.modeLabel.length ? [self.chip fittingWidth] : 0;
    self.chip.hidden = chipW == 0;
    self.chip.frame = NSMakeRect(kW - 20 - chipW, sy + floor((kSearchH - 24) / 2), chipW, 24);
    self.searchIcon.frame = NSMakeRect(22, sy + floor((kSearchH - 18) / 2) + 2, 18, 18);   // optically centred on the 20pt text
    self.field.frame = NSMakeRect(54, sy + floor((kSearchH - 26) / 2), kW - 54 - 22 - (chipW > 0 ? chipW + 12 : 0), 28);
    self.separator.frame = NSMakeRect(0, sy, kW, 1);
    self.separator.hidden = bodyH == 0;
    self.footer.frame = NSMakeRect(0, 0, kW, kFooterH); self.footer.hidden = footH == 0;
    self.scroll.hidden = home || rows == 0;
    self.grid.hidden = appsH == 0; self.gridTitle.hidden = appsH == 0;
    self.quick.hidden = quickH == 0;
    self.homeList.hidden = listH == 0;
    self.media.hidden = !showMedia;
    if (showMedia) self.media.frame = NSMakeRect(0, sy - mediaH, kW, mediaH);
    if (home) {
        CGFloat y = sy - mediaH;
        if (appsH > 0) {
            self.gridTitle.frame = NSMakeRect(kInset, y - 30, 200, 14);
            self.grid.frame = NSMakeRect(0, y - 32 - kCellH, kW, kCellH);
            y -= appsH;
        }
        if (quickH > 0) { self.quick.frame = NSMakeRect(0, y - quickH, kW, quickH); y -= quickH; }
        if (listH > 0) self.homeList.frame = NSMakeRect(0, y - listH, kW, listH);
    } else {
        self.scroll.frame = NSMakeRect(0, footH + 6, kW, MAX(bodyH - 12, 0));
    }
    CItem *sel = (self.selected >= 0 && self.selected < (NSInteger)self.items.count) ? self.items[self.selected] : nil;
    NSDictionary *verbs = @{ @"Application": @"Open Application", @"Recent": @"Open Application", @"Calculator": @"Copy Answer", @"Web": @"Search",
                             @"URL": @"Open Link", @"Link": @"Open Link", @"Clipboard": @"Paste", @"File": @"Open File", @"Process": @"Quit App",
                             @"Shell": @"Run", @"System Settings": @"Open Settings", @"Media": @"Control Playback", @"Password": @"Copy Password",
                             @"Dictionary": @"Open in Dictionary", @"Timer": @"Start Timer", @"Folder": @"Open Folder" };
    NSString *verb = sel ? (sel.verb ?: verbs[sel.kind ?: @""] ?: @"Run Command") : @"Open";
    if (sel && sel == self.armedItem) verb = @"Confirm";
    NSMutableArray *h = [NSMutableArray arrayWithObject:@[verb, @"↩"]];
    if (sel.altAction && sel.altAction != sel.action) {
        NSString *alt = sel.altHint.length ? [[sel.altHint stringByReplacingOccurrencesOfString:@"⌘↩" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"Alternate";
        [h addObject:@[alt, @"⌘", @"↩"]];
    }
    if (showMedia && !sel.altAction) [h addObject:@[@"Play/Pause", @"⌘", @"P"]];
    if ([self pinKeyFor:sel]) [h addObject:@[[self isPinned:sel] ? @"Unpin" : @"Pin", @"⇧", @"⌘", @"P"]];
    else [h addObject:@[@"Settings", @"⌘", @","]];
    self.hints.hints = h;
}

// Pointer moved onto a row / grid cell: it becomes the selection (Enter, footer hints and ⌘↩ follow it).
- (void)hoverSelect:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.items.count || i == self.selected) return;
    if (!self.gridMode) [self disarm];
    if (self.gridMode) { [self homeSelect:i]; return; }
    self.selected = i; [self reloadTable];
}

- (void)reloadTable {
    if (self.gridMode) {
        NSInteger n = (NSInteger)self.items.count, a = MIN(self.homeApps, n), q = MIN(self.homeQuick, n - a);
        self.grid.items = [self.items subarrayWithRange:NSMakeRange(0, (NSUInteger)a)];
        self.quick.items = [self.items subarrayWithRange:NSMakeRange((NSUInteger)a, (NSUInteger)q)];
        self.homeList.entries = self.homeEntries; self.homeList.base = a + q;
    }
    [self layoutForRows:self.items.count];
    if (self.gridMode) { self.grid.showShortcuts = self.cmdHeld; [self.grid reload]; [self.homeList reload]; [self syncHomeSelection]; }
    else [self.table reloadData];
}

- (void)positionPanel {
    NSPoint mouse = [NSEvent mouseLocation]; NSScreen *scr = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(mouse, s.frame, NO)) scr = s;
    NSRect v = scr.visibleFrame;
    CGFloat x = v.origin.x + (v.size.width - kW) / 2;
    CGFloat top = v.origin.y + v.size.height - floor(v.size.height * 0.20);
    [self.panel setFrame:NSMakeRect(x, top - kSearchH, kW, kSearchH) display:NO];
}

- (void)show {
    [self loadConfig];
    self.previousApp = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (self.previousApp == NSRunningApplication.currentApplication && !self.panel.visible) self.previousApp = nil;
    [self captureContext];                        // selected text + the app in front, read before the panel takes focus
    self.windowList = nil; [self refreshWindowList];
    self.cmdHeld = NO;
    if ([NSDate date].timeIntervalSince1970 - self.lastScan > 120) [self scanApps];
    [self positionPanel];
    self.field.stringValue = @"";
    [self refresh];
    [self startRecentFilesQuery];
    self.panel.alphaValue = 0;                    // a short fade reads as "appearing", not "flashing"
    [self.panel makeKeyAndOrderFront:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.09; self.panel.animator.alphaValue = 1; } completionHandler:nil];
    [self.panel makeFirstResponder:self.field];
    [self refreshNowPlaying];
    [self.mediaTimer invalidate];
    __weak CApp *ws = self;
    self.mediaTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        if ([ws ytmMode]) [ws refreshYTM]; else if (!ws.media.hidden) [ws updateMediaView]; }];
}
- (void)hide { [self.panel orderOut:nil]; [self stopFileSearch]; [self.mediaTimer invalidate]; self.mediaTimer = nil; }


- (void)toggle { if (self.panel.visible && self.panel.keyWindow) [self hide]; else [self show]; }

- (void)windowDidResignKey:(NSNotification *)n { if (self.panel.visible) [self hide]; }

// First ↩ on an irreversible command shows what will happen; a second ↩ within 4 s runs it.
- (void)armItem:(CItem *)i {
    [self disarm];
    self.armedItem = i; self.armedSubtitle = i.subtitle; self.armedAt = [NSDate date];
    i.subtitle = i.confirm;
    if (self.gridMode) [self.homeList reload]; else [self.table reloadData];
    [self syncHomeSelectionIfNeeded];
    [self layoutForRows:self.items.count];
}
- (void)disarm {
    CItem *i = self.armedItem; if (!i) return;
    i.subtitle = self.armedSubtitle; self.armedItem = nil; self.armedSubtitle = nil;
    if (self.gridMode) { [self.homeList reload]; [self syncHomeSelectionIfNeeded]; } else [self.table reloadData];
}
- (void)syncHomeSelectionIfNeeded { if (self.gridMode) [self syncHomeSelection]; }

- (void)runSelected:(BOOL)alt {
    if (self.selected < 0 || self.selected >= (NSInteger)self.items.count) return;
    CItem *i = self.items[self.selected];
    if (i.confirm.length && !(self.armedItem == i && [self.armedAt timeIntervalSinceNow] > -4)) { [self armItem:i]; return; }
    [self disarm];
    if (i.key.length) [self recordUse:i.key];          // feeds Recent Commands
    CAction a = alt ? (i.altAction ?: i.action) : i.action;
    if (!(i.keepsPanel && !alt)) [self hide];        // rows that lead to another mode keep the panel open
    if (a) a();
}

- (void)rowClicked:(id)s { NSInteger r = self.table.clickedRow; if (r >= 0) { self.selected = r; [self runSelected:NO]; } }

- (void)moveSelection:(NSInteger)d {
    if (!self.items.count) return;
    [self disarm];
    NSInteger old = self.selected;
    self.selected = (self.selected + d + (NSInteger)self.items.count) % (NSInteger)self.items.count;
    if (self.gridMode) [self syncHomeSelection];
    else {
        NSMutableIndexSet *rows = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)self.selected];
        if (old >= 0 && old < (NSInteger)self.items.count) [rows addIndex:(NSUInteger)old];
        [self.table reloadDataForRowIndexes:rows columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.table.numberOfColumns)]];
    }
    [self layoutForRows:self.items.count];
}
@end
