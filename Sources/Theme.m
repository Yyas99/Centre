// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Centre.h"

#pragma mark - Design tokens

// One accent, the icy core of the app icon. Used sparingly: the text caret and the active-mode chip.
NSColor *cAccent(void) {
    static NSColor *c; static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSColor colorWithName:@"CentreIce" dynamicProvider:^NSColor *(NSAppearance *ap) {
            BOOL dark = [ap bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
            return dark ? [NSColor colorWithSRGBRed:0.56 green:0.86 blue:1.00 alpha:1] : [NSColor colorWithSRGBRed:0.13 green:0.58 blue:0.92 alpha:1];
        }];
    });
    return c;
}
BOOL cIsDark(NSView *v) {
    return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}
// Selection fill + hairline shared by result rows, grid cells and the settings sidebar.
NSColor *cSelFill(NSView *v) { return cIsDark(v) ? [NSColor colorWithWhite:1 alpha:0.095] : [NSColor colorWithWhite:0 alpha:0.065]; }
NSColor *cSelEdge(NSView *v) { return cIsDark(v) ? [NSColor colorWithWhite:1 alpha:0.055] : [NSColor colorWithWhite:0 alpha:0.04]; }

NSColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
// System Settings–style tile colours (top, bottom) per result kind.
NSArray<NSColor *> *tileColors(NSString *kind) {
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *green = @[rgb(0.33, 0.81, 0.48), rgb(0.15, 0.63, 0.31)], *slate = @[rgb(0.50, 0.62, 0.81), rgb(0.33, 0.45, 0.66)];
        map = @{ @"System":     @[rgb(0.58, 0.59, 0.62), rgb(0.40, 0.41, 0.44)],
                 @"Media":      @[rgb(1.00, 0.37, 0.43), rgb(0.89, 0.17, 0.29)],
                 @"Window":     @[rgb(0.36, 0.62, 1.00), rgb(0.15, 0.42, 0.93)],
                 @"Password":   @[rgb(0.56, 0.88, 1.00), rgb(0.18, 0.62, 0.92)],
                 @"Centre":     @[rgb(0.31, 0.32, 0.35), rgb(0.12, 0.13, 0.15)],
                 @"Web":        @[rgb(0.27, 0.70, 0.99), rgb(0.09, 0.50, 0.88)],
                 @"URL": green, @"Link": green,
                 @"Calculator": @[rgb(0.37, 0.38, 0.41), rgb(0.19, 0.20, 0.22)],
                 @"Clipboard":  @[rgb(0.29, 0.81, 0.76), rgb(0.09, 0.61, 0.59)],
                 @"Shell":      @[rgb(0.25, 0.26, 0.28), rgb(0.07, 0.07, 0.08)],
                 @"Files": slate, @"File": slate,
                 @"Dictionary": @[rgb(0.86, 0.36, 0.30), rgb(0.64, 0.19, 0.16)],
                 @"Timer":      @[rgb(0.36, 0.76, 0.82), rgb(0.14, 0.52, 0.60)],
                 @"Awake":      @[rgb(1.00, 0.82, 0.32), rgb(0.93, 0.62, 0.10)] };
    });
    return map[kind ?: @""] ?: map[@"System"];
}
// Rounded colour tile with a white SF Symbol; resolution-independent and cached.
NSImage *tileImage(NSString *symbol, NSString *kind) {
    static NSMutableDictionary *cache; if (!cache) cache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@|%@", symbol, kind];
    NSImage *hit = cache[key]; if (hit) return hit;
    NSArray<NSColor *> *c = tileColors(kind);
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold];
    NSImage *glyph = [[NSImage imageWithSystemSymbolName:symbol ?: @"circle" accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (!glyph) glyph = [[NSImage imageWithSystemSymbolName:@"circle" accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    NSSize gs = glyph.size;
    NSImage *white = [NSImage imageWithSize:gs flipped:NO drawingHandler:^BOOL(NSRect rr) {
        [glyph drawInRect:rr]; [[NSColor whiteColor] set]; NSRectFillUsingOperation(rr, NSCompositingOperationSourceAtop); return YES; }];
    NSImage *img = [NSImage imageWithSize:NSMakeSize(28, 28) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:7 yRadius:7];
        [[[NSGradient alloc] initWithStartingColor:c[0] endingColor:c[1]] drawInBezierPath:p angle:-90];
        [NSGraphicsContext saveGraphicsState];                       // lit hairline along the top edge
        [p addClip]; NSRectClip(NSMakeRect(0, r.size.height * 0.5, r.size.width, r.size.height * 0.5));
        NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:6.5 yRadius:6.5];
        hl.lineWidth = 1; [[NSColor colorWithWhite:1 alpha:0.2] setStroke]; [hl stroke];
        [NSGraphicsContext restoreGraphicsState];
        CGFloat k = MIN(1.0, 17.0 / MAX(MAX(gs.width, gs.height), 1));   // keep wide glyphs inside the tile
        NSRect gr = NSMakeRect(NSMidX(r) - gs.width * k / 2, NSMidY(r) - gs.height * k / 2, gs.width * k, gs.height * k);
        [white drawInRect:gr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        return YES;
    }];
    cache[key] = img;
    return img;
}

#pragma mark - HUD

// A small capsule that confirms an action the panel can't show because it has already closed ("Copied 31.2").
NSPanel *prepareHUD(NSString *text, NSString *symbol) {
    static NSPanel *hud; static NSTextField *label; static NSImageView *icon;
    const CGFloat H = 40;
    if (!hud) {
        hud = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, H) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered defer:NO];
        hud.level = NSStatusWindowLevel + 1; hud.opaque = NO; hud.backgroundColor = [NSColor clearColor]; hud.hasShadow = YES;
        hud.ignoresMouseEvents = YES; hud.releasedWhenClosed = NO;
        hud.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
        NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 200, H)];
        fx.material = NSVisualEffectMaterialHUDWindow; fx.blendingMode = NSVisualEffectBlendingModeBehindWindow; fx.state = NSVisualEffectStateActive;
        CGFloat R = H / 2;
        NSImage *mask = [NSImage imageWithSize:NSMakeSize(R * 2 + 2, R * 2 + 2) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [[NSColor blackColor] set]; [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:R yRadius:R] fill]; return YES; }];
        mask.capInsets = NSEdgeInsetsMake(R, R, R, R); mask.resizingMode = NSImageResizingModeStretch;
        fx.maskImage = mask; fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        icon = [NSImageView new]; icon.imageScaling = NSImageScaleProportionallyDown;
        label = [NSTextField labelWithString:@""]; label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [fx addSubview:icon]; [fx addSubview:label];
        hud.contentView = fx;
    }
    NSImage *g = [[NSImage imageWithSystemSymbolName:symbol ?: @"checkmark.circle.fill" accessibilityDescription:nil]
                  imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightSemibold]];
    icon.image = g; icon.contentTintColor = cAccent();
    label.stringValue = text ?: @"";
    [label sizeToFit];
    CGFloat tw = ceil(NSWidth(label.frame)) + 4, W = 16 + 18 + 8 + tw + 18;   // +4: label cells add inset padding
    icon.frame = NSMakeRect(16, (H - 18) / 2, 18, 18);
    label.frame = NSMakeRect(16 + 18 + 8, floor((H - label.intrinsicContentSize.height) / 2), tw, label.intrinsicContentSize.height);
    NSPoint mouse = [NSEvent mouseLocation]; NSScreen *scr = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *sc in NSScreen.screens) if (NSMouseInRect(mouse, sc.frame, NO)) scr = sc;
    NSRect v = scr.visibleFrame;
    [hud setFrame:NSMakeRect(floor(NSMidX(v) - W / 2), NSMaxY(v) - floor(v.size.height * 0.20) - H, W, H) display:NO];
    return hud;
}
void showHUD(NSString *text, NSString *symbol) { showHUDFor(text, symbol, 1.3); }
void showHUDFor(NSString *text, NSString *symbol, NSTimeInterval seconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSInteger generation;
        NSPanel *hud = prepareHUD(text, symbol);
        NSInteger mine = ++generation;
        hud.alphaValue = 0; [hud orderFrontRegardless];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.12; hud.animator.alphaValue = 1; } completionHandler:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (mine != generation) return;                       // a newer message took over
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.25; hud.animator.alphaValue = 0; }
                                completionHandler:^{ if (mine == generation) [hud orderOut:nil]; }];
        });
    });
}
