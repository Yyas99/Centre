// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Views.h"

#pragma mark - Views

@implementation CPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// ---------- Panel chrome ----------

// Near-opaque layer over the vibrancy so busy wallpapers/windows don't muddy the panel.
@implementation CBackdrop
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r {
    // A cool, slightly lifted top fading to a deeper base: depth without a visible gradient band.
    NSGradient *g = cIsDark(self)
        ? [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.052 green:0.056 blue:0.064 alpha:0.78]     // obsidian glass
                                        endingColor:[NSColor colorWithSRGBRed:0.036 green:0.039 blue:0.045 alpha:0.84]]
        : [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.992 green:0.994 blue:0.998 alpha:0.90]
                                        endingColor:[NSColor colorWithSRGBRed:0.962 green:0.966 blue:0.974 alpha:0.92]];
    [g drawInRect:self.bounds angle:-90];
}
@end

@implementation CHairline
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r { [[[NSColor labelColor] colorWithAlphaComponent:0.09] setFill]; NSRectFill(self.bounds); }
@end

@implementation CEdgeView
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r {
    BOOL dark = cIsDark(self);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:kRadius - 0.5 yRadius:kRadius - 0.5];
    p.lineWidth = 1; [(dark ? [NSColor colorWithWhite:1 alpha:0.085] : [NSColor colorWithWhite:0 alpha:0.12]) setStroke]; [p stroke];
    if (dark) {   // glass: one lit line along the top edge, fading out into the corners
        NSColor *clear = [NSColor colorWithWhite:1 alpha:0], *lit = [NSColor colorWithWhite:1 alpha:0.17];
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:clear, 0.0, lit, 0.16, lit, 0.84, clear, 1.0, nil];
        [g drawInRect:NSMakeRect(kRadius * 0.6, self.bounds.size.height - 2, self.bounds.size.width - kRadius * 1.2, 1) angle:0];
    }
}
@end

// Quiet band behind the footer hints.
@implementation CFooterBar
- (void)drawRect:(NSRect)r { [(cIsDark(self) ? [NSColor colorWithWhite:1 alpha:0.025] : [NSColor colorWithWhite:0 alpha:0.022]) setFill]; NSRectFill(self.bounds); }   // its own lifted band
@end

// Active-mode token at the right of the search field ("Clipboard", "Files", "youtube.com"…).
@implementation CChip
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (NSDictionary *)attrs { return @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor labelColor]}; }
- (CGFloat)fittingWidth { return ceil([self.text ?: @"" sizeWithAttributes:[self attrs]].width) + 33; }
- (void)setText:(NSString *)t { _text = [t copy]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)r {
    if (!self.text.length) return;
    BOOL dark = cIsDark(self);
    NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:b.size.height / 2 yRadius:b.size.height / 2];
    [(dark ? [NSColor colorWithWhite:1 alpha:0.08] : [NSColor colorWithWhite:0 alpha:0.05]) setFill]; [p fill];
    p.lineWidth = 1; [(dark ? [NSColor colorWithWhite:1 alpha:0.10] : [NSColor colorWithWhite:0 alpha:0.08]) setStroke]; [p stroke];
    [cAccent() setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(12, NSMidY(self.bounds) - 3, 6, 6)] fill];
    NSDictionary *a = [self attrs]; NSSize s = [self.text sizeWithAttributes:a];
    [self.text drawAtPoint:NSMakePoint(23, NSMidY(self.bounds) - s.height / 2) withAttributes:a];
}
@end

// Footer hints drawn as "Label [key]" pairs with keycap chips, right-aligned.
@implementation CKeyHints
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)setHints:(NSArray *)h { _hints = h; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)r {
    NSDictionary *la = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSDictionary *ka = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    BOOL dark = cIsDark(self);
    NSColor *cap = dark ? [NSColor colorWithWhite:1 alpha:0.085] : [NSColor colorWithWhite:0 alpha:0.055];
    NSColor *capEdge = dark ? [NSColor colorWithWhite:1 alpha:0.06] : [NSColor colorWithWhite:0 alpha:0.075];
    CGFloat H = self.bounds.size.height, x = self.bounds.size.width;
    for (NSArray *h in [self.hints reverseObjectEnumerator]) {
        for (NSInteger k = (NSInteger)h.count - 1; k >= 1; k--) {
            NSString *key = h[k]; NSSize ks = [key sizeWithAttributes:ka];
            CGFloat w = MAX(20, ceil(ks.width) + 10); x -= w;
            NSRect kr = NSMakeRect(x, floor((H - 20) / 2), w, 20);
            NSBezierPath *kp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(kr, 0.5, 0.5) xRadius:5 yRadius:5];
            [cap setFill]; [kp fill]; kp.lineWidth = 1; [capEdge setStroke]; [kp stroke];
            [key drawAtPoint:NSMakePoint(NSMidX(kr) - ks.width / 2, NSMidY(kr) - ks.height / 2) withAttributes:ka];
            x -= 3;
        }
        NSString *lbl = h[0]; NSSize ls = [lbl sizeWithAttributes:la];
        x -= ls.width + 5;
        [lbl drawAtPoint:NSMakePoint(x, (H - ls.height) / 2) withAttributes:la];
        x -= 18;
    }
}
@end

// ---------- Result row ----------
@implementation CRowView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _iconSize = 26;
        _iconView = [NSImageView new]; _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _titleLabel = [NSTextField labelWithString:@""]; _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _kindLabel = [NSTextField labelWithString:@""];
        _kindLabel.font = [NSFont systemFontOfSize:12]; _kindLabel.textColor = [NSColor tertiaryLabelColor]; _kindLabel.alignment = NSTextAlignmentRight;
        _kindLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        for (NSView *v in @[_iconView, _titleLabel, _kindLabel]) [self addSubview:v];
    }
    return self;
}
- (void)setTitle:(NSString *)t subtitle:(NSString *)sub {
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:t ?: @""
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor labelColor]}];
    NSString *one = [[sub ?: @"" stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (one.length) [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:one]
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular], NSForegroundColorAttributeName: cSubtitle()}]];   // an alpha-adjusted system colour can freeze to one appearance
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [a addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, a.length)];
    _titleLabel.attributedStringValue = a;
}
- (void)setKind:(NSString *)kind shortcut:(NSString *)shortcut {
    if (shortcut.length) {
        _kindLabel.stringValue = shortcut;
        _kindLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
        _kindLabel.textColor = [NSColor secondaryLabelColor];
    } else {
        _kindLabel.stringValue = kind ?: @"";
        _kindLabel.font = [NSFont systemFontOfSize:12];
        _kindLabel.textColor = _selected ? [NSColor secondaryLabelColor] : [NSColor tertiaryLabelColor];
    }
}
- (void)layout {
    [super layout];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat is = _iconSize, ix = kInset + floor((26 - is) / 2), tx = kInset + 26 + 12;   // text column fixed whatever the icon size
    _iconView.frame = NSMakeRect(ix, floor((H - is) / 2), is, is);
    _kindLabel.frame = NSMakeRect(W - 26 - 140, floor((H - 16) / 2), 140, 16);
    _titleLabel.frame = NSMakeRect(tx, floor((H - 19) / 2), W - tx - 178, 19);
}
- (void)drawRect:(NSRect)r {
    if (_selected) {
        [cSelFill(self) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 10, 1.5) xRadius:10 yRadius:10] fill];
        NSBezierPath *e = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 10.5, 2) xRadius:9.5 yRadius:9.5];
        e.lineWidth = 1; [cSelEdge(self) setStroke]; [e stroke];
    }
}
@end

// ---------- Most-used grid ----------
@implementation CGridView
- (CGFloat)x0 { return floor((self.bounds.size.width - (CGFloat)self.items.count * kCellW) / 2); }   // the row of apps sits centred
- (void)reload {
    for (NSView *v in [self.subviews copy]) [v removeFromSuperview];
    NSInteger n = (NSInteger)self.items.count;
    for (NSInteger i = 0; i < n; i++) {
        CItem *it = self.items[i];
        NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect([self x0] + i * kCellW, 0, kCellW, kCellH)];
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect((kCellW - 50) / 2, kCellH - 50 - 8, 50, 50)];
        iv.imageScaling = NSImageScaleProportionallyUpOrDown;
        NSImage *img = self.iconFor ? self.iconFor(it) : nil;
        iv.image = img; if (img.template) iv.contentTintColor = [NSColor secondaryLabelColor];
        NSString *t = (self.showShortcuts && i < 9) ? [NSString stringWithFormat:@"\u2318%ld", (long)i + 1] : (it.title ?: @"");
        NSTextField *lbl = [NSTextField labelWithString:t];
        lbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]; lbl.alignment = NSTextAlignmentCenter;
        lbl.textColor = i == self.selected ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        lbl.lineBreakMode = NSLineBreakByTruncatingTail; lbl.frame = NSMakeRect(5, 8, kCellW - 10, 15);
        [cell addSubview:iv]; [cell addSubview:lbl];
        [self addSubview:cell];
    }
    [self setNeedsDisplay:YES];
}
- (void)setSelected:(NSInteger)s {
    _selected = s;
    NSInteger i = 0;
    for (NSView *cell in self.subviews) {
        for (NSView *v in cell.subviews) if ([v isKindOfClass:[NSTextField class]]) {
            ((NSTextField *)v).textColor = i == s ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        }
        i++;
    }
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)r {
    if (_selected >= 0 && _selected < (NSInteger)self.items.count) {
        NSRect b = NSMakeRect([self x0] + _selected * kCellW + 4, 1, kCellW - 8, kCellH - 2);
        BOOL dark = cIsDark(self);
        [(dark ? cIceFill() : cSelFill(self)) setFill];                    // the one lit thing: where you are
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:16 yRadius:16] fill];
        NSBezierPath *e = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:15.5 yRadius:15.5];
        e.lineWidth = 1; [(dark ? cIceEdge() : cSelEdge(self)) setStroke]; [e stroke];
    }
}
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = (NSInteger)floor((p.x - [self x0]) / kCellW);
    if (i >= 0 && i < (NSInteger)self.items.count && self.onPick) self.onPick(i);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = (NSInteger)floor((p.x - [self x0]) / kCellW);
    if (i >= 0 && i < (NSInteger)self.items.count && self.onHover) self.onHover(i);
}
@end

// ---------- Pinned: a row of pill buttons under Most Used ----------
static NSDictionary *pillAttrs(BOOL sel) {
    return @{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium],
             NSForegroundColorAttributeName: sel ? [NSColor labelColor] : [[NSColor labelColor] colorWithAlphaComponent:0.78]};
}
// Pinned commands sit on the app grid's own columns, as compact tiles: one rhythm from the apps down.
NSInteger quickStripFit(NSArray<CItem *> *items, CGFloat width) {
    NSInteger cols = (NSInteger)floor((width - 2 * kGridX) / kCellW);
    return MIN((NSInteger)items.count, cols);
}
@implementation CQuickStrip
- (NSDictionary *)attrs:(BOOL)sel { return pillAttrs(sel); }
- (NSArray<NSValue *> *)pillRects {
    NSMutableArray *r = [NSMutableArray new];
    NSInteger n = quickStripFit(self.items, self.bounds.size.width);
    CGFloat x0 = floor((self.bounds.size.width - (CGFloat)n * kCellW) / 2);      // centred, on the same column width as the apps
    for (NSInteger i = 0; i < n; i++) [r addObject:[NSValue valueWithRect:NSMakeRect(x0 + i * kCellW, 0, kCellW, self.bounds.size.height)]];
    return r;
}
- (void)setItems:(NSArray<CItem *> *)items { _items = items; [self setNeedsDisplay:YES]; }
- (void)setSelected:(NSInteger)s { _selected = s; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    BOOL dark = cIsDark(self);
    NSArray *rects = [self pillRects];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSUInteger i = 0; i < rects.count; i++) {
        NSRect b = [rects[i] rectValue]; BOOL sel = (NSInteger)i == self.selected;
        // A glass well, smaller than an app icon so the eye reads "commands" below "apps".
        NSRect well = NSMakeRect(round(NSMidX(b) - 18), NSMaxY(b) - 8 - 36, 36, 36);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(well, 0.5, 0.5) xRadius:11 yRadius:11];
        [(sel ? (dark ? cIceFill() : cSelFill(self)) : (dark ? [NSColor colorWithWhite:1 alpha:0.05] : [NSColor colorWithWhite:0 alpha:0.04])) setFill]; [p fill];
        p.lineWidth = 1; [(sel ? (dark ? cIceEdge() : cSelEdge(self)) : (dark ? [NSColor colorWithWhite:1 alpha:0.085] : [NSColor colorWithWhite:0 alpha:0.06])) setStroke]; [p stroke];
        CItem *it = self.items[i];
        NSColor *tint = sel ? [NSColor labelColor] : [[NSColor labelColor] colorWithAlphaComponent:0.78];
        NSImage *g = it.symbol ? tintedSymbol(it.symbol, 14, tint) : nil;
        if (!g && self.iconFor) g = self.iconFor(it);                 // pinned apps, folders and files use their real icons
        if (g.template) g = tintedSymbol(it.symbol ?: @"circle", 14, tint);
        NSSize gs = g.size.width > 0 ? g.size : NSMakeSize(18, 18);
        CGFloat box = it.symbol ? 18 : 22, k = MIN(box / MAX(MAX(gs.width, gs.height), 1), it.symbol ? 1.0 : 10.0);
        NSRect ir = NSMakeRect(round(NSMidX(well) - gs.width * k / 2), round(NSMidY(well) - gs.height * k / 2), gs.width * k, gs.height * k);
        [g drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:sel ? NSFontWeightSemibold : NSFontWeightMedium],
                            NSForegroundColorAttributeName: sel ? [NSColor labelColor] : [[NSColor labelColor] colorWithAlphaComponent:0.6], NSParagraphStyleAttributeName: ps};
        [it.title drawInRect:NSMakeRect(NSMinX(b) + 4, NSMinY(b) + 6, b.size.width - 8, 14) withAttributes:a];
    }
}
- (NSInteger)indexAt:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSArray *rects = [self pillRects];
    for (NSUInteger i = 0; i < rects.count; i++) if (NSPointInRect(p, [rects[i] rectValue])) return (NSInteger)i;
    return -1;
}
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent *)e { NSInteger i = [self indexAt:e]; if (i >= 0 && self.onPick) self.onPick(i); }
- (void)mouseMoved:(NSEvent *)e { NSInteger i = [self indexAt:e]; if (i >= 0 && self.onHover) self.onHover(i); }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
@end

// ---------- Home sections: Clipboard / Recent Files / Recent Commands ----------
@interface CHomeList () <NSDraggingSource>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CItem *> *rowItems;
@property (nonatomic) NSInteger downIndex, dragIndex;
@property (nonatomic) NSPoint downAt;
@end
@implementation CHomeList
- (BOOL)isFlipped { return YES; }
- (CGFloat)fittingHeight {
    CGFloat h = 0;
    for (id e in self.entries) h += [e isKindOfClass:[NSString class]] ? kHomeHeadH : kHomeRowH;
    return self.entries.count ? h + 8 : 0;
}
- (void)reload {
    for (NSView *v in [self.subviews copy]) [v removeFromSuperview];
    CGFloat y = 0, W = self.bounds.size.width; NSInteger idx = self.base;
    self.rowItems = [NSMutableDictionary new]; self.downIndex = -1;
    for (id e in self.entries) {
        if ([e isKindOfClass:[NSString class]]) {
            NSTextField *h = [NSTextField labelWithAttributedString:sectionTitle(e)];
            h.frame = NSMakeRect(kInset, y + 13, 300, 14);
            [self addSubview:h]; y += kHomeHeadH;
        } else {
            CItem *it = e;
            CRowView *r = [[CRowView alloc] initWithFrame:NSMakeRect(0, y, W, kHomeRowH)];
            r.iconSize = 22; r.globalIndex = idx; self.rowItems[@(idx)] = it; idx++; r.autoresizingMask = NSViewWidthSizable;
            [r setTitle:it.title subtitle:it.subtitle];
            NSImage *img = self.iconFor ? self.iconFor(it) : nil;
            r.iconView.image = img; r.iconView.contentTintColor = img.template ? [NSColor secondaryLabelColor] : nil;
            r.selected = (r.globalIndex == self.selected);
            [r setKind:(it.detail ?: @"") shortcut:nil];
            [self addSubview:r]; y += kHomeRowH;
        }
    }
}
- (void)setSelected:(NSInteger)s {
    _selected = s;
    for (NSView *v in self.subviews) if ([v isKindOfClass:[CRowView class]]) {
        CRowView *r = (CRowView *)v; BOOL on = r.globalIndex == s;
        if (r.selected == on) continue;
        r.selected = on; r.kindLabel.textColor = on ? [NSColor secondaryLabelColor] : [NSColor tertiaryLabelColor];
        [r setNeedsDisplay:YES];
    }
}
- (NSInteger)indexAt:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    for (NSView *v in self.subviews) if ([v isKindOfClass:[CRowView class]] && NSPointInRect(p, v.frame)) return ((CRowView *)v).globalIndex;
    return -1;
}
- (BOOL)mouseDownCanMoveWindow { return NO; }
// Rows that can be dragged out (shelf items) run on mouse-up instead, so a drag never also triggers them.
- (void)mouseDown:(NSEvent *)e {
    NSInteger i = [self indexAt:e]; if (i < 0) return;
    if (self.rowItems[@(i)].dragObject) { self.downIndex = i; self.downAt = e.locationInWindow; return; }
    if (self.onPick) self.onPick(i);
}
- (void)mouseDragged:(NSEvent *)e {
    if (self.downIndex < 0) return;
    if (hypot(e.locationInWindow.x - self.downAt.x, e.locationInWindow.y - self.downAt.y) < 4) return;
    CItem *it = self.rowItems[@(self.downIndex)];
    NSView *row = nil; for (NSView *v in self.subviews) if ([v isKindOfClass:[CRowView class]] && ((CRowView *)v).globalIndex == self.downIndex) row = v;
    self.dragIndex = self.downIndex; self.downIndex = -1;
    if (!it.dragObject || !row) return;
    NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:it.dragObject];
    NSImage *img = self.iconFor ? self.iconFor(it) : nil;
    NSRect fr = NSMakeRect(NSMinX(row.frame) + 12, NSMinY(row.frame) + 8, 28, 28);
    [di setDraggingFrame:fr contents:img ?: [NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:nil]];
    [self beginDraggingSessionWithItems:@[di] event:e source:self];
}
- (void)mouseUp:(NSEvent *)e {
    NSInteger i = self.downIndex; self.downIndex = -1;
    if (i >= 0 && [self indexAt:e] == i && self.onPick) self.onPick(i);
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c {
    return c == NSDraggingContextOutsideApplication ? NSDragOperationCopy | NSDragOperationGeneric : NSDragOperationNone;
}
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op {
    if (op != NSDragOperationNone && self.onDragOut) self.onDragOut(self.dragIndex);
    self.dragIndex = -1;
}
- (void)mouseMoved:(NSEvent *)e { NSInteger i = [self indexAt:e]; if (i >= 0 && self.onHover) self.onHover(i); }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
@end
@implementation CAmbient
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)setSegments:(NSArray<NSArray<NSString *> *> *)s {
    if ([s isEqualToArray:_segments]) return;
    _segments = [s copy]; [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)r {
    CGFloat H = self.bounds.size.height, room = self.bounds.size.width - 2 * kInset, gap = 26;
    NSColor *dim = [NSColor colorWithWhite:1 alpha:0.50], *glyph = [NSColor colorWithWhite:1 alpha:0.40];
    NSDictionary *lead = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.86]};
    NSDictionary *rest = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium], NSForegroundColorAttributeName: dim};
    // Measure first: keep what fits, then centre the line as a whole.
    NSMutableArray *parts = [NSMutableArray new]; CGFloat total = 0;
    for (NSArray<NSString *> *seg in self.segments) {
        NSDictionary *a = parts.count == 0 ? lead : rest;
        NSImage *g = seg[0].length ? tintedSymbol(seg[0], 10, glyph) : nil;
        NSSize ts = [seg[1] sizeWithAttributes:a];
        CGFloat w = (g ? g.size.width + 6 : 0) + ts.width, add = (parts.count ? gap : 0) + w;
        if (total + add > room) break;
        total += add; [parts addObject:@[seg[1], a, g ?: [NSNull null], @(ts.width), @(ts.height)]];
    }
    CGFloat x = floor((self.bounds.size.width - total) / 2);
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSArray *p = parts[i];
        if (i > 0) { [[NSColor colorWithWhite:1 alpha:0.10] setFill]; NSRectFill(NSMakeRect(x - gap / 2, floor(H / 2) - 4, 1, 9)); }
        if (p[2] != [NSNull null]) { NSImage *g = p[2]; [g drawInRect:NSMakeRect(x, round(H / 2 - g.size.height / 2), g.size.width, g.size.height)]; x += g.size.width + 6; }
        [p[0] drawAtPoint:NSMakePoint(x, round(H / 2 - [p[4] doubleValue] / 2)) withAttributes:p[1]];
        x += [p[3] doubleValue] + gap;
    }
}
@end

@implementation CMediaView
- (NSTextField *)timeLabel:(NSTextAlignment)al {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium]; l.textColor = [NSColor secondaryLabelColor]; l.alignment = al;
    return l;
}
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _art = [NSImageView new]; _art.imageScaling = NSImageScaleProportionallyUpOrDown;
        _art.wantsLayer = YES; _art.layer.cornerRadius = 8; _art.layer.masksToBounds = YES;
        _titleL = [NSTextField labelWithString:@""]; _titleL.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold]; _titleL.lineBreakMode = NSLineBreakByTruncatingTail;
        _subL = [NSTextField labelWithString:@""]; _subL.font = [NSFont systemFontOfSize:12]; _subL.textColor = [NSColor secondaryLabelColor]; _subL.lineBreakMode = NSLineBreakByTruncatingTail;
        _elapsedL = [self timeLabel:NSTextAlignmentLeft]; _remainL = [self timeLabel:NSTextAlignmentRight];
        _prevB = [self btn:@"backward.fill" size:14 tag:5];
        _playB = [self btn:@"play.fill" size:19 tag:2];
        _nextB = [self btn:@"forward.fill" size:14 tag:4];
        _closeB = [NSButton buttonWithImage:symSize(@"xmark", 8.5) target:self action:@selector(closeTapped)];   // hide until you play again
        _closeB.bordered = NO; _closeB.contentTintColor = [NSColor colorWithWhite:1 alpha:0.32]; _closeB.toolTip = @"Hide until something plays again";
        for (NSView *v in @[_art, _titleL, _subL, _elapsedL, _remainL, _prevB, _playB, _nextB, _closeB]) [self addSubview:v];
        _progress = -1;
    }
    return self;
}
- (NSButton *)btn:(NSString *)sym size:(CGFloat)pt tag:(NSInteger)tag {
    NSButton *b = [NSButton buttonWithImage:symSize(sym, pt) target:self action:@selector(tap:)];
    b.bezelStyle = NSBezelStyleRecessed; b.bordered = YES; b.showsBorderOnlyWhileMouseInside = YES;   // soft bezel on hover
    b.tag = tag; b.contentTintColor = [NSColor labelColor]; b.imageScaling = NSImageScaleNone;
    return b;
}
- (void)tap:(NSButton *)b { if (self.onCommand) self.onCommand((int)b.tag); }
- (void)closeTapped { if (self.onClose) self.onClose(); }
- (void)setPlaying:(BOOL)p { self.playB.image = symSize(p ? @"pause.fill" : @"play.fill", 19); }
- (NSRect)card { return NSMakeRect(12, 6, self.bounds.size.width - 24, self.bounds.size.height - 12); }
// Track rect between the two time labels; the hit area is taller than the drawn bar.
- (NSRect)barRect { return NSMakeRect(NSMaxX(self.elapsedL.frame) + 6, NSMinY([self card]) + 20, MAX(0, NSMinX(self.remainL.frame) - NSMaxX(self.elapsedL.frame) - 12), 4); }
- (NSRect)barHitRect { return NSInsetRect([self barRect], -4, -8); }
- (void)layout {
    [super layout];
    NSRect c = [self card];
    self.art.frame = NSMakeRect(c.origin.x + 16, c.origin.y + floor((c.size.height - 60) / 2), 60, 60);
    CGFloat ctrlW = 3 * 34 + 4;
    CGFloat tx = NSMaxX(self.art.frame) + 16, tw = NSMaxX(c) - ctrlW - tx - 24;
    self.titleL.frame = NSMakeRect(tx, NSMaxY(c) - 17 - 18, tw, 18);
    self.subL.frame = NSMakeRect(tx, NSMaxY(c) - 17 - 18 - 17, tw, 16);
    self.elapsedL.frame = NSMakeRect(tx, c.origin.y + 15, 46, 14);
    self.remainL.frame = NSMakeRect(tx + tw - 50, c.origin.y + 15, 50, 14);
    CGFloat cy = NSMidY(c) - 17, x = NSMaxX(c) - 16 - 34;
    self.nextB.frame = NSMakeRect(x, cy, 34, 34); x -= 35;
    self.playB.frame = NSMakeRect(x, cy, 34, 34); x -= 35;
    self.prevB.frame = NSMakeRect(x, cy, 34, 34);
    self.closeB.frame = NSMakeRect(NSMaxX(c) - 22, NSMaxY(c) - 21, 16, 16);
    self.closeB.hidden = self.onClose == nil;
}
- (void)setElapsed:(double)el duration:(double)d {
    self.duration = d;
    if (self.scrubbing) return;                       // the pointer owns the bar while dragging
    self.progress = d > 0 ? MIN(1.0, MAX(0.0, el / d)) : -1;
    [self updateTimes:el];
}
- (void)updateTimes:(double)el {
    BOOL show = self.progress >= 0 && self.duration > 0;
    self.elapsedL.hidden = self.remainL.hidden = !show;
    if (!show) return;
    self.elapsedL.stringValue = fmtTime(el);
    self.remainL.stringValue = [@"−" stringByAppendingString:fmtTime(MAX(0, self.duration - el))];
}
- (void)drawRect:(NSRect)r {
    NSRect c = [self card]; BOOL dark = cIsDark(self);
    [(dark ? [NSColor colorWithWhite:1 alpha:0.035] : [NSColor colorWithWhite:0 alpha:0.04]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:c xRadius:16 yRadius:16] fill];
    NSBezierPath *ce = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(c, 0.5, 0.5) xRadius:15.5 yRadius:15.5];
    ce.lineWidth = 1; [(dark ? (self.accent ? [self.accent colorWithAlphaComponent:0.28] : [NSColor colorWithWhite:1 alpha:0.065]) : cSelEdge(self)) setStroke]; [ce stroke];
    if (self.progress < 0 || self.duration <= 0) return;
    BOOL big = self.hoverBar || self.scrubbing;
    NSRect t = [self barRect]; if (big) t = NSInsetRect(t, 0, -1);
    CGFloat rad = t.size.height / 2;
    [(dark ? [NSColor colorWithWhite:1 alpha:0.14] : [NSColor colorWithWhite:0 alpha:0.12]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:t xRadius:rad yRadius:rad] fill];
    NSRect f = t; f.size.width = MAX(t.size.height, t.size.width * self.progress);
    [(self.accent ?: cAccent()) setFill]; [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];   // lit by the artwork
    if (big) {   // knob
        CGFloat kx = NSMinX(t) + t.size.width * self.progress;
        NSRect k = NSMakeRect(kx - 6, NSMidY(t) - 6, 12, 12);
        NSShadow *sh = [NSShadow new]; sh.shadowBlurRadius = 3; sh.shadowOffset = NSMakeSize(0, -1); sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
        [NSGraphicsContext saveGraphicsState]; [sh set];
        [[NSColor whiteColor] setFill]; [[NSBezierPath bezierPathWithOvalInRect:k] fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (double)fractionAt:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSRect t = [self barRect];
    return t.size.width > 0 ? MIN(1.0, MAX(0.0, (p.x - NSMinX(t)) / t.size.width)) : 0;
}
- (BOOL)mouseDownCanMoveWindow { return NO; }   // dragging the bar scrubs instead of moving the panel
- (void)mouseDown:(NSEvent *)e {
    if (self.progress < 0 || self.duration <= 0) return;
    if (!NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], [self barHitRect])) return;
    self.scrubbing = YES; [self mouseDragged:e];
}
- (void)mouseDragged:(NSEvent *)e {
    if (!self.scrubbing) return;
    self.progress = [self fractionAt:e]; [self updateTimes:self.progress * self.duration]; [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
    if (!self.scrubbing) return;
    self.scrubbing = NO; double f = [self fractionAt:e]; self.progress = f;
    if (self.onSeek) self.onSeek(f);
    [self setNeedsDisplay:YES];
}
- (void)mouseMoved:(NSEvent *)e {
    BOOL on = self.progress >= 0 && NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], [self barHitRect]);
    if (on != self.hoverBar) { self.hoverBar = on; [self setNeedsDisplay:YES]; }
}
- (void)mouseExited:(NSEvent *)e { if (self.hoverBar) { self.hoverBar = NO; [self setNeedsDisplay:YES]; } }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
@end

// Results table whose selection follows real mouse movement (rows sliding under a still pointer don't steal it).
@implementation CTable
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
- (void)mouseMoved:(NSEvent *)e {
    NSInteger r = [self rowAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (r >= 0 && self.onHover) self.onHover(r);
}
@end

@implementation CField
- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    NSText *ed = self.currentEditor;
    if (ok && [ed isKindOfClass:[NSTextView class]]) ((NSTextView *)ed).insertionPointColor = cAccent();
    return ok;
}
@end
