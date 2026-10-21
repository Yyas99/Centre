// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// The taskbar: one floating bar along the bottom of the main display, in the spirit of KDE Plasma's panel.
//   [C] | pinned + running apps (indicator under each, active one lit) ……… now playing · volume · Wi-Fi · battery · clock | desktop
// Everything is drawn by one view (CTBView) from a list of items, so layout, hover and hit-testing share one source of truth.
#import "Taskbar.h"
#import "App.h"
#import "Settings.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <dlfcn.h>

// Metrics follow Settings › Taskbar (size, floating, position, app names); set in -apply before any layout or drawing.
static CGFloat gBarH = 48, gBarGap = 8, gTaskW = 44, gTaskIcon = 30, gBarRadius = 14;
static BOOL gTop = NO, gLabels = NO;

#pragma mark - Audio (CoreAudio: instant, no AppleScript round trip)

static AudioDeviceID outputDevice(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    AudioDeviceID d = 0; UInt32 sz = sizeof d;
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &d) == noErr ? d : 0;
}
static BOOL readVolume(float *vol, BOOL *muted) {
    AudioDeviceID d = outputDevice(); if (!d) return NO;
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    Float32 v = 0; UInt32 sz = sizeof v;
    if (!AudioObjectHasProperty(d, &a) || AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &v) != noErr) return NO;
    AudioObjectPropertyAddress m = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    UInt32 mu = 0; sz = sizeof mu;
    if (AudioObjectHasProperty(d, &m)) AudioObjectGetPropertyData(d, &m, 0, NULL, &sz, &mu);
    *vol = v; *muted = mu != 0;
    return YES;
}
static void writeMute(BOOL on) {
    AudioDeviceID d = outputDevice(); if (!d) return;
    AudioObjectPropertyAddress m = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    UInt32 v = on ? 1 : 0;
    if (AudioObjectHasProperty(d, &m)) AudioObjectSetPropertyData(d, &m, 0, NULL, sizeof v, &v);
}
static void writeVolume(float v) {
    AudioDeviceID d = outputDevice(); if (!d) return;
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster};
    Float32 f = MIN(MAX(v, 0), 1);
    if (AudioObjectHasProperty(d, &a)) AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof f, &f);
    writeMute(f <= 0.001);
}

#pragma mark - Model

typedef NS_ENUM(NSInteger, CTBKind) { CTBStart, CTBTask, CTBMedia, CTBPrev, CTBPlay, CTBNext, CTBVolume, CTBWifi, CTBBattery, CTBClock, CTBDesktop };

@interface CTBItem : NSObject
@property (nonatomic) CTBKind kind;
@property (nonatomic) NSRect rect;
@property (nonatomic, copy) NSString *path, *title;
@property (nonatomic, strong) NSRunningApplication *app;
@property (nonatomic) BOOL pinned;
@property (nonatomic) BOOL sampleRunning, sampleActive;   // README screenshots: running state without real apps
@property (nonatomic, strong) id win;                    // one window of the app (AXUIElementRef) when windows aren't grouped
@property (nonatomic) BOOL minimized;
@end
@implementation CTBItem @end

@interface CTaskbar () <NSPopoverDelegate>
@property (nonatomic, weak) CApp *app;
@property (nonatomic, strong) NSPanel *bar, *tip;
@property (nonatomic, strong) NSTextField *tipLabel;
@property (nonatomic, strong) NSView *barView;
@property (nonatomic, strong) NSArray<CTBItem *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *icons;
@property (nonatomic) pid_t lastFront;                  // the app in front, ignoring Centre itself
@property (nonatomic) float volume; @property (nonatomic) BOOL muted, hasVolume;
@property (nonatomic) NSInteger battery; @property (nonatomic) BOOL charging, onPower, hasBattery, online;
@property (nonatomic, copy) NSString *clockText, *dateText;
@property (nonatomic, strong) NSTimer *tick, *tipTimer, *hideTimer;
@property (nonatomic) NSUInteger ticks;
@property (nonatomic) BOOL hiddenAway, menuOpen;      // auto-hide state; a menu or popover is open
@property (nonatomic) BOOL fullScreenAway;             // stepped aside for a full-screen app
@property (nonatomic, strong) id globalMouse, localMouse;
@property (nonatomic) CGFloat marqueeOverflow;          // how much of the playing title doesn't fit (set while drawing)
@property (nonatomic) CFTimeInterval marqueeStart;
@property (nonatomic, strong) NSTimer *marqueeTimer;
@property (nonatomic) CGFloat marqueeShown;
@property (nonatomic, strong) NSRunningApplication *peekFront;           // the app in front before "show desktop"
@property (nonatomic, strong) NSArray<NSRunningApplication *> *peeked;   // apps hidden by "show desktop", restored on the next click
@property (nonatomic, strong) NSPopover *calendar;
@property (nonatomic) BOOL built;
@property (nonatomic, copy) NSString *appliedDock;      // Dock mode last applied this session
@property (nonatomic, strong) NSMutableArray *pendingFit;   // windows resized or created, checked once they settle
@property (nonatomic, strong) NSTimer *fitTimer;
@property (nonatomic) NSRect sweptFrame;                     // bar frame windows were last fitted to
@property (nonatomic, strong) NSMutableSet<NSNumber *> *stuck;   // pids that ignored Quit
@property (nonatomic, strong) NSMapTable *refused;           // window → the frame it snapped back to after a trim
@property (nonatomic, strong) NSArray<NSString *> *sampleApps, *sampleRunningApps;
@property (nonatomic, copy) NSString *sampleActiveApp;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *observers;               // pid → AXObserver: windows opening, closing, minimising
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray *> *winOrder;         // pid → windows in first-seen order, so buttons don't shuffle on focus
@property (nonatomic, strong) id focusedWin;                                               // the front app's focused window
- (void)layoutItems;
- (void)clickItem:(CTBItem *)it;
- (void)menuForItem:(CTBItem *)it event:(NSEvent *)e;
- (void)scrollOnItem:(CTBItem *)it event:(NSEvent *)e;
- (void)hoverItem:(CTBItem *)it;
- (void)movePinned:(NSString *)path toIndex:(NSInteger)idx;
- (BOOL)isActive:(CTBItem *)it;
- (CGFloat)marqueeOffset;
- (NSImage *)iconForPath:(NSString *)p;
- (BOOL)wants:(NSString *)key fallback:(BOOL)def;
- (void)windowsChanged;
- (void)windowNeedsFit:(id)win;
@end

static NSArray<NSDictionary *> *appWindows(NSRunningApplication *r);
static CGRect axFrame(AXUIElementRef w);

#pragma mark - Bar chrome

// Tint over the blur, plus a lit top edge — the same glass as the launcher panel.
@interface CTBBackdrop : NSView @end
@implementation CTBBackdrop
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r {
    BOOL dark = cIsDark(self);
    NSColor *tint = dark ? [NSColor colorWithSRGBRed:0.085 green:0.090 blue:0.105 alpha:0.74] : [NSColor colorWithSRGBRed:0.975 green:0.977 blue:0.985 alpha:0.80];
    NSColor *edge = dark ? [NSColor colorWithWhite:1 alpha:0.11] : [NSColor colorWithWhite:0 alpha:0.10];
    if (gBarRadius <= 0) {                                       // edge-to-edge: one hairline on the side facing the screen
        [tint setFill]; NSRectFill(self.bounds);
        [edge setFill]; NSRectFillUsingOperation(NSMakeRect(0, gTop ? 0 : self.bounds.size.height - 1, self.bounds.size.width, 1), NSCompositingOperationSourceOver);
        return;
    }
    NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:gBarRadius - 0.5 yRadius:gBarRadius - 0.5];
    [tint setFill]; [p fill];
    p.lineWidth = 1; [edge setStroke]; [p stroke];
    if (dark) {
        NSColor *clear = [NSColor colorWithWhite:1 alpha:0], *lit = [NSColor colorWithWhite:1 alpha:0.13];
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:clear, 0.0, lit, 0.25, lit, 0.75, clear, 1.0, nil];
        [g drawInRect:NSMakeRect(gBarRadius, self.bounds.size.height - 1.5, self.bounds.size.width - gBarRadius * 2, 1) angle:0];
    }
}
@end

@interface CTBView : NSView
- (NSInteger)indexAt:(NSPoint)p;
@property (nonatomic, weak) CTaskbar *owner;
@property (nonatomic) NSInteger hover, press;
@property (nonatomic) NSPoint downAt;
@property (nonatomic) BOOL dragging;
@end

#pragma mark - The bar view

@implementation CTBView

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)viewDidChangeEffectiveAppearance { [self setNeedsDisplay:YES]; }

- (NSInteger)indexAt:(NSPoint)p {
    NSArray *items = self.owner.items;
    for (NSUInteger i = 0; i < items.count; i++) if (NSPointInRect(p, [items[i] rect])) return (NSInteger)i;
    return -1;
}

static void drawSymbol(NSString *name, CGFloat pt, NSColor *c, NSPoint center) {
    NSImage *g = tintedSymbol(name, pt, c);
    if (!g) return;
    NSSize s = g.size;
    [g drawInRect:NSMakeRect(round(center.x - s.width / 2), round(center.y - s.height / 2), s.width, s.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
}

- (void)drawRect:(NSRect)dirty {
    CTaskbar *o = self.owner; BOOL dark = cIsDark(self);
    NSColor *ink = [[NSColor labelColor] colorWithAlphaComponent:0.88];
    NSArray<CTBItem *> *items = o.items;
    CGFloat H = self.bounds.size.height, sepIn = round(H * 0.27);
    BOOL sepDrawn = NO;
    for (NSUInteger i = 0; i < items.count; i++) {
        CTBItem *it = items[i]; NSRect r = it.rect;
        if (NSIsEmptyRect(r)) continue;
        if (!sepDrawn && it.kind >= CTBMedia && it.kind <= CTBClock) {
            [[[NSColor labelColor] colorWithAlphaComponent:0.12] setFill];
            NSRectFillUsingOperation(NSMakeRect(NSMinX(r) - 7, sepIn, 1, H - sepIn * 2), NSCompositingOperationSourceOver);
            sepDrawn = YES;
        }
        BOOL hover = (NSInteger)i == self.hover, press = (NSInteger)i == self.press;
        BOOL active = it.kind == CTBTask && [o isActive:it];
        // Hover / active plate
        if (hover || active || press) {
            NSRect plate = NSInsetRect(r, 2, 5);
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:9 yRadius:9];
            NSColor *fill = active ? cSelFill(self) : [[NSColor labelColor] colorWithAlphaComponent:press ? 0.13 : 0.075];
            if (active && hover) fill = [cSelFill(self) blendedColorWithFraction:0.25 ofColor:[NSColor colorWithWhite:dark ? 1 : 0 alpha:1]];
            [fill setFill]; [p fill];
            if (active) { p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(plate, 0.5, 0.5) xRadius:8.5 yRadius:8.5]; p.lineWidth = 1; [cSelEdge(self) setStroke]; [p stroke]; }
        }
        switch (it.kind) {
            case CTBStart: {
                NSImage *ic = [NSApp applicationIconImage];
                CGFloat s = MIN(28, gTaskIcon - 2) - (press ? 2 : 0);
                [ic drawInRect:NSMakeRect(NSMidX(r) - s / 2, NSMidY(r) - s / 2, s, s) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
                // hairline after the launcher, like Plasma's separator
                [[[NSColor labelColor] colorWithAlphaComponent:0.12] setFill];
                NSRectFillUsingOperation(NSMakeRect(NSMaxX(r) + 5, sepIn, 1, H - sepIn * 2), NSCompositingOperationSourceOver);
                break;
            }
            case CTBTask: {
                NSImage *ic = [o iconForPath:it.path];
                CGFloat s = press && !self.dragging ? gTaskIcon - 3 : gTaskIcon;
                CGFloat lift = hover && !press ? 1 : 0, away = gTop ? -1 : 1;     // nudge the icon away from its indicator
                BOOL named = gLabels && r.size.width > gTaskW + 4;       // wider than an icon slot means it carries its name
                CGFloat ix = named ? NSMinX(r) + 10 : round(NSMidX(r) - s / 2);
                NSRect ir = NSMakeRect(ix, round(NSMidY(r) - s / 2 + (2 + lift) * away), s, s);
                BOOL hidden = it.app.hidden || it.minimized;
                CGFloat alpha = (it.app && hidden) ? 0.5 : (self.dragging && press ? 0.75 : 1);
                [ic drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha];
                if (named) {
                    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
                    NSDictionary *na = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:active ? NSFontWeightSemibold : NSFontWeightRegular],
                                         NSForegroundColorAttributeName: [ink colorWithAlphaComponent:alpha * 0.9], NSParagraphStyleAttributeName: ps};
                    CGFloat tx = NSMaxX(ir) + 8;
                    [it.title drawInRect:NSMakeRect(tx, NSMidY(ir) - 8, NSMaxX(r) - tx - 8, 16) withAttributes:na];
                }
                if (it.app || it.sampleRunning) {                 // running: a short line; in front: a longer ice line
                    CGFloat w = active ? (named ? 24 : 16) : 5;
                    NSRect line = NSMakeRect(round(NSMidX(named ? ir : r) - w / 2), gTop ? H - 10 : 7, w, 3);
                    [(active ? cAccent() : [[NSColor labelColor] colorWithAlphaComponent:hidden ? 0.25 : 0.5]) setFill];
                    [[NSBezierPath bezierPathWithRoundedRect:line xRadius:1.5 yRadius:1.5] fill];
                }
                break;
            }
            case CTBMedia: {
                NSRect art = NSMakeRect(NSMinX(r) + 8, NSMidY(r) - 13, 26, 26);
                NSImage *img = o.app.nowArt;
                if (img) {
                    [NSGraphicsContext saveGraphicsState];
                    [[NSBezierPath bezierPathWithRoundedRect:art xRadius:6 yRadius:6] addClip];
                    [img drawInRect:art fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
                    [NSGraphicsContext restoreGraphicsState];
                } else {
                    [tileImage(@"music.note", @"Media") drawInRect:art fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
                }
                if (hover) {                                      // hovering the art shows what a click will do
                    [[NSColor colorWithWhite:0 alpha:0.45] setFill];
                    [[NSBezierPath bezierPathWithRoundedRect:art xRadius:6 yRadius:6] fill];
                    drawSymbol(o.app.isPlaying ? @"pause.fill" : @"play.fill", 11, [NSColor whiteColor], NSMakePoint(NSMidX(art), NSMidY(art)));
                }
                CGFloat tx = NSMaxX(art) + 8, tw = NSMaxX(r) - tx - 8;
                NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
                NSDictionary *ta = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSForegroundColorAttributeName: ink, NSParagraphStyleAttributeName: ps};
                NSDictionary *sa = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5], NSForegroundColorAttributeName: [NSColor secondaryLabelColor], NSParagraphStyleAttributeName: ps};
                NSString *sub = o.app.nowArtist.length ? o.app.nowArtist : (o.app.nowApp ?: @"");
                NSString *title = o.app.nowTitle ?: @"";
                NSRect tr = NSMakeRect(tx, NSMidY(r) + (sub.length ? 0 : -8), tw, 16);
                NSDictionary *plain = @{NSFontAttributeName: ta[NSFontAttributeName], NSForegroundColorAttributeName: ink};
                CGFloat over = ceil([title sizeWithAttributes:plain].width) - tw;
                o.marqueeOverflow = MAX(0, over);
                if (over <= 0) [title drawInRect:tr withAttributes:ta];
                else {                                           // too long: a slow carousel, with soft edges where text runs out of view
                    CGFloat off = [o marqueeOffset];
                    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
                    CGContextSaveGState(cg);
                    CGContextClipToRect(cg, NSRectToCGRect(tr));
                    CGContextBeginTransparencyLayerWithRect(cg, NSRectToCGRect(tr), NULL);
                    [title drawAtPoint:NSMakePoint(tx - off, tr.origin.y) withAttributes:plain];
                    CGContextSetBlendMode(cg, kCGBlendModeDestinationOut);
                    NSGradient *fade = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:1] endingColor:[NSColor colorWithWhite:0 alpha:0]];
                    if (off > 0.5) [fade drawInRect:NSMakeRect(tx, tr.origin.y, 14, 16) angle:0];
                    if (off < over - 0.5) [fade drawInRect:NSMakeRect(NSMaxX(tr) - 14, tr.origin.y, 14, 16) angle:180];
                    CGContextEndTransparencyLayer(cg);
                    CGContextRestoreGState(cg);
                }
                if (sub.length) [sub drawInRect:NSMakeRect(tx, NSMidY(r) - 14, tw, 14) withAttributes:sa];
                break;
            }
            case CTBPrev: case CTBPlay: case CTBNext: {
                NSString *sym = it.kind == CTBPrev ? @"backward.fill" : it.kind == CTBNext ? @"forward.fill" : o.app.isPlaying ? @"pause.fill" : @"play.fill";
                drawSymbol(sym, it.kind == CTBPlay ? 13 : 11, ink, NSMakePoint(NSMidX(r), NSMidY(r)));
                break;
            }
            case CTBVolume: {
                NSString *sym = !o.hasVolume ? @"speaker.fill" : (o.muted || o.volume < 0.01) ? @"speaker.slash.fill" : o.volume < 0.34 ? @"speaker.wave.1.fill" : o.volume < 0.67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
                drawSymbol(sym, 13, o.muted ? [NSColor secondaryLabelColor] : ink, NSMakePoint(NSMidX(r), NSMidY(r)));
                if (hover && o.hasVolume) {                       // a thin level bar under the icon while you hover or scroll
                    NSRect track = NSMakeRect(NSMidX(r) - 10, gTop ? H - 11.5 : 9, 20, 2.5);
                    [[[NSColor labelColor] colorWithAlphaComponent:0.15] setFill]; [[NSBezierPath bezierPathWithRoundedRect:track xRadius:1.25 yRadius:1.25] fill];
                    NSRect fillR = track; fillR.size.width = MAX(2.5, track.size.width * (o.muted ? 0 : o.volume));
                    [cAccent() setFill]; [[NSBezierPath bezierPathWithRoundedRect:fillR xRadius:1.25 yRadius:1.25] fill];
                }
                break;
            }
            case CTBWifi:
                drawSymbol(o.online ? @"wifi" : @"wifi.slash", 13, o.online ? ink : [NSColor secondaryLabelColor], NSMakePoint(NSMidX(r), NSMidY(r)));
                break;
            case CTBBattery: {
                NSInteger b = o.battery;
                NSString *sym = o.charging ? @"battery.100.bolt" : b > 80 ? @"battery.100" : b > 55 ? @"battery.75" : b > 30 ? @"battery.50" : b > 12 ? @"battery.25" : @"battery.0";
                NSColor *c = (!o.charging && !o.onPower && b <= 15) ? [NSColor systemRedColor] : ink;
                drawSymbol(sym, 14, c, NSMakePoint(NSMinX(r) + 18, NSMidY(r)));
                NSDictionary *a = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium], NSForegroundColorAttributeName: c};
                NSString *t = [NSString stringWithFormat:@"%ld%%", (long)b];
                NSSize ts = [t sizeWithAttributes:a];
                [t drawAtPoint:NSMakePoint(NSMinX(r) + 33, NSMidY(r) - ts.height / 2) withAttributes:a];
                break;
            }
            case CTBClock: {
                NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
                NSDictionary *ta = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: ink, NSParagraphStyleAttributeName: ps};
                NSDictionary *da = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor secondaryLabelColor], NSParagraphStyleAttributeName: ps};
                BOOL date = o.dateText.length > 0;
                [o.clockText drawInRect:NSMakeRect(NSMinX(r), date ? NSMidY(r) - 1 : NSMidY(r) - 9, r.size.width, 18) withAttributes:ta];
                if (date) [o.dateText drawInRect:NSMakeRect(NSMinX(r), NSMidY(r) - 15, r.size.width, 14) withAttributes:da];
                break;
            }
            case CTBDesktop: {
                [[[NSColor labelColor] colorWithAlphaComponent:0.12] setFill];
                NSRectFillUsingOperation(NSMakeRect(NSMinX(r) - 3, sepIn, 1, H - sepIn * 2), NSCompositingOperationSourceOver);
                drawSymbol(o.peeked.count ? @"macwindow.on.rectangle" : @"rectangle.inset.filled", 12, hover ? ink : [NSColor secondaryLabelColor], NSMakePoint(NSMidX(r), NSMidY(r)));
                break;
            }
        }
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i == self.hover) return;
    self.hover = i; [self setNeedsDisplay:YES];
    [self.owner hoverItem:i >= 0 ? self.owner.items[i] : nil];
}
- (void)mouseExited:(NSEvent *)e { self.hover = -1; [self setNeedsDisplay:YES]; [self.owner hoverItem:nil]; }
- (void)mouseDown:(NSEvent *)e {
    self.downAt = [self convertPoint:e.locationInWindow fromView:nil];
    self.press = [self indexAt:self.downAt]; self.dragging = NO;
    [self.owner hoverItem:nil];
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)e {
    if (self.press < 0 || self.press >= (NSInteger)self.owner.items.count) return;
    CTBItem *it = self.owner.items[self.press];
    if (it.kind != CTBTask || !it.pinned) return;               // only pinned apps reorder
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (!self.dragging && fabs(p.x - self.downAt.x) < 6) return;
    self.dragging = YES;
    // The slot under the pointer, among pinned apps only
    NSInteger target = 0, n = 0;
    for (CTBItem *x in self.owner.items) if (x.kind == CTBTask && x.pinned) { if (p.x > NSMidX(x.rect)) target = n + 1; n++; }
    NSInteger from = (NSInteger)[[self.owner pinnedPaths] indexOfObject:it.path];
    if (target > from) target--;                                   // removing it first shifts later slots left
    if (from != NSNotFound && target != from) {
        [self.owner movePinned:it.path toIndex:target];
        for (NSUInteger k = 0; k < self.owner.items.count; k++) if (self.owner.items[k].pinned && [self.owner.items[k].path isEqualToString:it.path]) { self.press = (NSInteger)k; break; }
    }
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    NSInteger was = self.press; BOOL dragged = self.dragging;
    self.press = -1; self.dragging = NO; [self setNeedsDisplay:YES];
    if (dragged) { [self.owner setPinnedPaths:[self.owner pinnedPaths]]; return; }   // save the new order
    if (i >= 0 && i == was) [self.owner clickItem:self.owner.items[i]];
}
- (void)rightMouseDown:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    [self.owner hoverItem:nil];
    if (i >= 0) [self.owner menuForItem:self.owner.items[i] event:e];
}
- (void)otherMouseDown:(NSEvent *)e { [self rightMouseDown:e]; }
- (void)scrollWheel:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0) [self.owner scrollOnItem:self.owner.items[i] event:e];
}
@end

#pragma mark - Controller

@implementation CTaskbar

- (instancetype)initWithApp:(CApp *)app {
    if ((self = [super init])) {
        _app = app; _icons = [NSMutableDictionary new]; _items = @[];
        _observers = [NSMutableDictionary new]; _winOrder = [NSMutableDictionary new];
        _lastFront = [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier;
    }
    return self;
}

- (BOOL)wants:(NSString *)key fallback:(BOOL)def { id v = self.app.config[key]; return v ? [v boolValue] : def; }

#pragma mark Pins

- (NSArray<NSString *> *)defaultPins {
    NSMutableArray *r = [NSMutableArray arrayWithObject:@"/System/Library/CoreServices/Finder.app"];
    for (NSString *p in [self.app dockAppPaths]) if (![r containsObject:p] && [[NSFileManager defaultManager] fileExistsAtPath:p]) [r addObject:p];
    return r;
}
- (NSArray<NSString *> *)pinnedPaths {
    id v = self.app.config[@"taskbarPins"];
    if (![v isKindOfClass:[NSArray class]]) return [self defaultPins];
    NSMutableArray *r = [NSMutableArray new];
    for (id p in v) if ([p isKindOfClass:[NSString class]] && ![r containsObject:p]) [r addObject:p];
    return r;
}
- (void)setPinnedPaths:(NSArray<NSString *> *)paths {
    NSMutableDictionary *c = [self.app mutableConfig];
    c[@"taskbarPins"] = paths ?: @[];
    [self.app writeConfig:c];
}
// Reorder in memory while dragging (saved on mouse-up), so the drag stays smooth.
- (void)movePinned:(NSString *)path toIndex:(NSInteger)idx {
    NSMutableArray *p = [[self pinnedPaths] mutableCopy];
    [p removeObject:path];
    [p insertObject:path atIndex:(NSUInteger)MIN(MAX(idx, 0), (NSInteger)p.count)];
    NSMutableDictionary *c = [self.app.config mutableCopy] ?: [NSMutableDictionary new];
    c[@"taskbarPins"] = p; self.app.config = c;                      // not written yet
    [self rebuild];
}

#pragma mark Show / hide / position

- (NSScreen *)screen { return NSScreen.screens.firstObject ?: NSScreen.mainScreen; }

// Bottom of the main display (above the Dock while the Dock is visible), or just under the menu bar.
- (NSRect)barFrame {
    NSScreen *s = [self screen];
    NSRect v = s.visibleFrame, f = s.frame;
    if (gTop) return NSMakeRect(v.origin.x + gBarGap, NSMaxY(v) - gBarGap - gBarH, v.size.width - gBarGap * 2, gBarH);
    CGFloat bottom = (v.origin.y - f.origin.y) > 12 ? v.origin.y : f.origin.y;   // a visible Dock pushes the bar up
    return NSMakeRect(v.origin.x + gBarGap, bottom + gBarGap, v.size.width - gBarGap * 2, gBarH);
}
- (void)applyMask {
    CGFloat R = MAX(gBarRadius, 0.5);
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(R * 2 + 2, R * 2 + 2) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] set]; [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:gBarRadius yRadius:gBarRadius] fill]; return YES; }];
    mask.capInsets = NSEdgeInsetsMake(R, R, R, R); mask.resizingMode = NSImageResizingModeStretch;
    ((NSVisualEffectView *)self.bar.contentView).maskImage = mask;
}
// Reads Settings › Taskbar into the drawing metrics.
- (void)loadMetrics {
    NSString *size = [self.app.config[@"taskbarSize"] isKindOfClass:[NSString class]] ? self.app.config[@"taskbarSize"] : @"normal";
    if ([size isEqualToString:@"compact"]) { gBarH = 40; gTaskIcon = 24; gTaskW = 38; }
    else if ([size isEqualToString:@"large"]) { gBarH = 56; gTaskIcon = 36; gTaskW = 52; }
    else { gBarH = 48; gTaskIcon = 30; gTaskW = 44; }
    BOOL floating = [self wants:@"taskbarFloating" fallback:YES];
    gBarGap = floating ? 8 : 0; gBarRadius = floating ? (gBarH >= 56 ? 16 : 14) : 0;
    gTop = [self.app.config[@"taskbarPosition"] isEqual:@"top"];
    gLabels = [self wants:@"taskbarLabels" fallback:NO];
}

- (void)build {
    if (self.built) return;
    self.built = YES;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 800, gBarH) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:NO];
    p.level = CGWindowLevelForKey(kCGDockWindowLevelKey);
    p.opaque = NO; p.backgroundColor = [NSColor clearColor]; p.hasShadow = YES;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    p.hidesOnDeactivate = NO; p.becomesKeyOnlyIfNeeded = YES; p.releasedWhenClosed = NO; p.acceptsMouseMovedEvents = YES;
    p.animationBehavior = NSWindowAnimationBehaviorNone;
    NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:p.contentView.bounds];
    fx.material = NSVisualEffectMaterialHUDWindow; fx.blendingMode = NSVisualEffectBlendingModeBehindWindow; fx.state = NSVisualEffectStateActive;
    fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    p.contentView = fx;
    CTBBackdrop *bd = [[CTBBackdrop alloc] initWithFrame:fx.bounds]; bd.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [fx addSubview:bd];
    CTBView *v = [[CTBView alloc] initWithFrame:fx.bounds]; v.owner = self; v.hover = -1; v.press = -1;
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [fx addSubview:v];
    self.bar = p; self.barView = v;

    NSNotificationCenter *wc = [NSWorkspace sharedWorkspace].notificationCenter;
    __weak CTaskbar *ws = self;
    for (NSString *n in @[NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidTerminateApplicationNotification, NSWorkspaceDidHideApplicationNotification,
                          NSWorkspaceDidUnhideApplicationNotification, NSWorkspaceDidActivateApplicationNotification])
        [wc addObserverForName:n object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            NSRunningApplication *a = note.userInfo[NSWorkspaceApplicationKey];
            if ([note.name isEqualToString:NSWorkspaceDidActivateApplicationNotification] && a && a != NSRunningApplication.currentApplication)
                ws.lastFront = a.processIdentifier;
            [ws rebuild];
            [ws checkFullScreen];
        }];
    // Entering or leaving full screen switches Space; check at once, and again once the animation settles.
    [wc addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [ws checkFullScreen]; [ws windowsChanged];                    // each Space has its own windows
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws checkFullScreen]; });
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) { [ws apply]; }];
}

- (void)apply {
    if ([self.app.config[@"taskbarDock"] isEqual:@"reserve"] && !self.app.snapshotDir) {   // retired mode: carry it over as "off"
        NSMutableDictionary *c = [self.app mutableConfig]; c[@"taskbarDock"] = @"off"; [self.app writeConfig:c];
    }
    BOOL on = [self wants:@"taskbarEnabled" fallback:YES] && !self.app.snapshotDir;
    [self loadMetrics];
    if (!self.app.snapshotDir) [self syncDock:on];
    if (!on) {
        [self.bar orderOut:nil]; [self.tip orderOut:nil];
        [self.tick invalidate]; self.tick = nil; self.fullScreenAway = NO;
        [self stopAutoHide];
        setTaskbarReserve(nil, 0, NO);
        return;
    }
    [self build];
    [self applyMask];
    [self refreshStatus:YES];
    [self.bar setFrame:[self barFrame] display:NO];
    [self rebuild];
    if (!self.tick) {
        __weak CTaskbar *ws = self;
        self.tick = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [ws refreshStatus:NO]; [ws checkFullScreen]; }];   // also catches borderless games
        [[NSRunLoop mainRunLoop] addTimer:self.tick forMode:NSRunLoopCommonModes];
    }
    BOOL autoHide = [self wants:@"taskbarAutoHide" fallback:NO];
    if (autoHide) {
        [self startAutoHide];                                    // no-op if already watching; doesn't re-hide a bar you're using
        if (self.hiddenAway) [self.bar setFrame:NSOffsetRect([self barFrame], 0, (gTop ? 1 : -1) * (gBarH + gBarGap + 6)) display:NO];
        setTaskbarReserve(nil, 0, NO);
    } else {
        [self stopAutoHide]; self.hiddenAway = NO;
        self.bar.alphaValue = 1; self.bar.ignoresMouseEvents = NO;
        NSRect f = [self barFrame], v = [self screen].visibleFrame;
        CGFloat strip = gTop ? NSMaxY(v) - NSMinY(f) : NSMaxY(f) - v.origin.y;
        setTaskbarReserve([self screen], strip, gTop);           // window snapping leaves the bar uncovered
    }
    self.fullScreenAway = [self fullScreenInFront];
    if (self.fullScreenAway) { [self.bar orderOut:nil]; [self.tip orderOut:nil]; }
    else [self.bar orderFrontRegardless];
    [self.barView setNeedsDisplay:YES];
    if ([self fitsWindows] && !NSEqualRects(self.sweptFrame, [self barFrame])) {   // first time, or the bar changed size or place
        self.sweptFrame = [self barFrame];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self sweepWindows]; });
    } else if (![self fitsWindows]) self.sweptFrame = NSZeroRect;
}

#pragma mark Full screen

// Is the display showing a full-screen Space? The window server knows (Space type 4); this is how it stays right when
// macOS keeps the menu bar visible in full screen, so the window no longer covers the whole display.
// CGSCopyManagedDisplaySpaces is private but long-lived; looked up at run time, so a missing symbol just means "no".
static BOOL displayInFullScreenSpace(CGDirectDisplayID did) {
    static int (*mainConn)(void); static CFArrayRef (*copySpaces)(int);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mainConn = dlsym(RTLD_DEFAULT, "CGSMainConnectionID") ?: dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        copySpaces = dlsym(RTLD_DEFAULT, "CGSCopyManagedDisplaySpaces") ?: dlsym(RTLD_DEFAULT, "SLSCopyManagedDisplaySpaces");
    });
    if (!mainConn || !copySpaces) return NO;
    CFArrayRef raw = copySpaces(mainConn());
    if (!raw) return NO;
    NSArray *displays = CFBridgingRelease(raw);
    NSString *uuid = nil;
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
    if (u) { uuid = CFBridgingRelease(CFUUIDCreateString(NULL, u)); CFRelease(u); }
    for (NSDictionary *d in displays) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *ident = [d[@"Display Identifier"] isKindOfClass:[NSString class]] ? d[@"Display Identifier"] : @"";
        // "Main" when displays share Spaces; otherwise each display is listed by its UUID.
        BOOL ours = displays.count == 1 || [ident isEqualToString:@"Main"] || (uuid && [ident caseInsensitiveCompare:uuid] == NSOrderedSame);
        if (!ours) continue;
        NSDictionary *cur = [d[@"Current Space"] isKindOfClass:[NSDictionary class]] ? d[@"Current Space"] : nil;
        return [cur[@"type"] intValue] == 4;
    }
    return NO;
}

// Native full screen and split view (by Space type), or the app you're using covering the display (borderless games, slideshows).
// Reads only window owners and bounds, so it needs no Screen Recording permission.
- (BOOL)fullScreenInFront {
    if (![self wants:@"taskbarHideFullScreen" fallback:YES]) return NO;
    if (displayInFullScreenSpace([[self screen].deviceDescription[@"NSScreenNumber"] unsignedIntValue])) return YES;
    // Not a full-screen Space: a borderless game or slideshow can still cover the display.
    pid_t front = [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier;
    if (front == getpid()) front = self.lastFront;               // Centre's own panel over a full-screen app keeps the bar away
    if (front <= 0) return NO;
    CGRect d = CGDisplayBounds([[self screen].deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return NO;
    BOOL full = NO;
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != front || [w[(id)kCGWindowLayer] integerValue] < 0 || [w[(id)kCGWindowAlpha] doubleValue] < 0.05) continue;
        CGRect b;
        if ([w[(id)kCGWindowBounds] isKindOfClass:[NSDictionary class]] && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b) &&
            windowFillsDisplay(b, d)) { full = YES; break; }
    }
    CFRelease(list);
    return full;
}
- (void)checkFullScreen {
    if (!self.built || self.app.snapshotDir || !self.tick) return;   // the bar is off
    BOOL full = [self fullScreenInFront];
    if (full == self.fullScreenAway) return;
    if (full) {
        self.fullScreenAway = YES;
        [self.hideTimer invalidate]; self.hideTimer = nil;
        if (self.calendar.shown) [self.calendar close];
        [self.tip orderOut:nil];
        [self.bar orderOut:nil];
    } else [self apply];                                          // back exactly as Settings has it, auto-hide included
}

#pragma mark The macOS Dock

static id dockValue(NSString *key) {
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.apple.dock")));
}
// The Dock settings Centre may change, and so saves first and puts back exactly (NSNull: you never set it).
static NSArray<NSString *> *dockKeys(void) { return @[@"autohide", @"autohide-delay", @"tilesize", @"magnification", @"orientation", @"mineffect"]; }
static BOOL sameDockValue(id a, id b) {
    BOOL na = !a || a == [NSNull null], nb = !b || b == [NSNull null];
    if (na || nb) return na && nb;
    if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]]) return fabs([a doubleValue] - [b doubleValue]) < 0.01;
    return [[a description] isEqualToString:[b description]];
}
static NSString *dockWrite(NSString *key, id v) {
    if (!v || v == [NSNull null]) return [NSString stringWithFormat:@"defaults delete com.apple.dock %@ 2>/dev/null", key];
    if ([key isEqualToString:@"orientation"] || [key isEqualToString:@"mineffect"])
        return [NSString stringWithFormat:@"defaults write com.apple.dock %@ -string %@", key, shellQuote([v description])];
    if ([key isEqualToString:@"autohide"] || [key isEqualToString:@"magnification"])
        return [NSString stringWithFormat:@"defaults write com.apple.dock %@ -bool %@", key, [v boolValue] ? @"true" : @"false"];
    return [NSString stringWithFormat:@"defaults write com.apple.dock %@ -float %g", key, [v doubleValue]];
}

// Settings › Taskbar › "While the taskbar is on, the Dock…": keep | autohide | off.
// ("reserve", a short-lived mode that parked a visible Dock under the bar, now reads as "off".)
- (NSString *)dockMode {
    NSString *m = [self.app.config[@"taskbarDock"] isKindOfClass:[NSString class]] ? self.app.config[@"taskbarDock"] : @"keep";
    return [m isEqualToString:@"reserve"] ? @"off" : m;
}
// Your Dock settings as they were before Centre touched them, with every key Centre may change.
// Older saves held only autohide and delay; keys they lack were never changed, so their current values are yours.
- (NSDictionary *)dockOriginal:(BOOL)create {
    NSDictionary *o = [self.app.config[@"dockOriginal"] isKindOfClass:[NSDictionary class]] ? self.app.config[@"dockOriginal"] : nil;
    if (!o && !create) return nil;
    NSMutableDictionary *r = [o mutableCopy] ?: [NSMutableDictionary new];
    if (o && !r[@"autohide-delay"]) r[@"autohide-delay"] = r[@"delay"] ?: [NSNull null];
    [r removeObjectForKey:@"delay"];
    for (NSString *k in dockKeys()) if (!r[k]) r[k] = dockValue(k) ?: [NSNull null];
    id d = r[@"autohide-delay"];                                       // never treat Centre's own "never show" delay as yours
    if ([d isKindOfClass:[NSNumber class]] && [d doubleValue] >= 100) r[@"autohide-delay"] = [NSNull null];
    if (![r isEqualToDictionary:o ?: @{}]) { NSMutableDictionary *c = [self.app mutableConfig]; c[@"dockOriginal"] = r; [self.app writeConfig:c]; }
    return r;
}
- (void)syncDock:(BOOL)barOn {
    NSString *mode = barOn ? [self dockMode] : @"keep";
    // Quick minimise: macOS has no instant minimise (the window server draws it), so use its quickest effect, Scale.
    BOOL quick = barOn && [self wants:@"taskbarQuickMinimise" fallback:YES];
    NSString *key = quick ? [mode stringByAppendingString:@"+scale"] : mode;
    if ([key isEqualToString:self.appliedDock]) return;               // apply runs on every config write; touch the Dock only on a real change
    self.appliedDock = key;
    BOOL keep = [mode isEqualToString:@"keep"] && !quick;              // nothing of yours is changed: put it all back
    NSDictionary *orig = [self dockOriginal:!keep];
    if (!orig) return;                                                 // never changed: nothing to put back
    NSMutableDictionary *want = [orig mutableCopy];
    // Keys a mode doesn't name (icon size, magnification, position, effect) are always yours, so anything Centre ever changed goes back.
    if ([mode isEqualToString:@"autohide"]) want[@"autohide"] = @YES;
    else if ([mode isEqualToString:@"off"]) { want[@"autohide"] = @YES; want[@"autohide-delay"] = @1000; }   // never comes back up
    if (quick) want[@"mineffect"] = @"scale";
    NSMutableArray *cmds = [NSMutableArray new];
    for (NSString *k in dockKeys()) if (!sameDockValue(dockValue(k), want[k])) [cmds addObject:dockWrite(k, want[k])];
    if (keep) { NSMutableDictionary *c = [self.app mutableConfig]; [c removeObjectForKey:@"dockOriginal"]; [self.app writeConfig:c]; }
    if (!cmds.count) return;
    [cmds addObject:@"killall Dock"];
    __weak CTaskbar *ws = self;
    runShell([cmds componentsJoinedByString:@"; "], ^(NSString *o) {   // the Dock restarting changes the screen's usable area
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws apply]; });
    });
}
// Quitting Centre (not a rebuild) gives you your Dock back, so you're never left without one.
- (void)restoreDockNow {
    NSDictionary *orig = [self dockOriginal:NO];
    if (!orig) return;
    NSMutableArray *cmds = [NSMutableArray new];
    for (NSString *k in dockKeys()) if (!sameDockValue(dockValue(k), orig[k])) [cmds addObject:dockWrite(k, orig[k])];
    if (cmds.count) {
        [cmds addObject:@"killall Dock"];
        NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[@"-c", [cmds componentsJoinedByString:@"; "]]];
        [t waitUntilExit];
    }
    NSMutableDictionary *c = [self.app mutableConfig]; [c removeObjectForKey:@"dockOriginal"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:c options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [d writeToFile:self.app.configPath atomically:YES];
}

#pragma mark Items and layout

- (void)rebuild {
    if (!self.built) return;
    NSMutableArray *items = [NSMutableArray new];
    CTBItem *start = [CTBItem new]; start.kind = CTBStart; start.title = @"Centre"; [items addObject:start];
    if (self.sampleApps) {                                           // README: neutral apps, nothing from this Mac
        for (NSString *p in self.sampleApps) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            CTBItem *t = [CTBItem new]; t.kind = CTBTask; t.path = p; t.pinned = YES;
            t.title = [[NSFileManager defaultManager] displayNameAtPath:p].stringByDeletingPathExtension;
            t.sampleRunning = [self.sampleRunningApps containsObject:p]; t.sampleActive = [p isEqualToString:self.sampleActiveApp];
            [items addObject:t];
        }
        for (NSNumber *k in @[@(CTBMedia), @(CTBPrev), @(CTBPlay), @(CTBNext), @(CTBVolume), @(CTBWifi), @(CTBBattery), @(CTBClock), @(CTBDesktop)]) { CTBItem *t = [CTBItem new]; t.kind = k.integerValue; [items addObject:t]; }
        self.items = items; [self layoutItems]; [self.barView setNeedsDisplay:YES];
        return;
    }
    NSMutableArray<NSRunningApplication *> *running = [NSMutableArray new];
    for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
        if (r.activationPolicy == NSApplicationActivationPolicyRegular && r != NSRunningApplication.currentApplication && !r.terminated && r.bundleURL) [running addObject:r];
    [running sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) { return [a.launchDate ?: [NSDate distantPast] compare:b.launchDate ?: [NSDate distantPast]]; }];
    BOOL perWindow = ![self wants:@"taskbarGroup" fallback:NO] && AXIsProcessTrusted();
    BOOL observe = AXIsProcessTrusted() && (perWindow || [self wants:@"taskbarFitWindows" fallback:YES]);   // window buttons, or keeping windows clear
    NSDictionary<NSNumber *, NSArray *> *lists = [self watchWindows:observe ? running : @[]];
    // One button per window (minimised ones too), or one per app when grouped. A pinned app's first window takes its pin slot.
    void (^addApp)(NSString *, NSRunningApplication *, BOOL) = ^(NSString *path, NSRunningApplication *r, BOOL pinned) {
        NSString *name = r.localizedName ?: [[NSFileManager defaultManager] displayNameAtPath:path].stringByDeletingPathExtension;
        NSArray *wins = (perWindow && r) ? [self ordered:lists[@(r.processIdentifier)] pid:r.processIdentifier] : @[];
        if (!wins.count) {
            CTBItem *t = [CTBItem new]; t.kind = CTBTask; t.path = path; t.app = r; t.pinned = pinned; t.title = name ?: @"App";
            [items addObject:t];
            return;
        }
        for (NSDictionary *w in wins) {
            CTBItem *t = [CTBItem new]; t.kind = CTBTask; t.path = path; t.app = r; t.pinned = pinned && w == wins.firstObject;
            t.win = w[@"win"]; t.minimized = [w[@"min"] boolValue];
            t.title = [w[@"title"] length] ? w[@"title"] : name;
            [items addObject:t];
        }
    };
    NSMutableSet *claimed = [NSMutableSet new];
    for (NSString *p in [self pinnedPaths]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
        NSRunningApplication *app = nil;
        for (NSRunningApplication *r in running) if ([r.bundleURL.path.stringByStandardizingPath isEqualToString:p.stringByStandardizingPath]) { app = r; [claimed addObject:r]; break; }
        addApp(p, app, YES);
    }
    for (NSRunningApplication *r in running) if (![claimed containsObject:r]) addApp(r.bundleURL.path, r, NO);
    self.focusedWin = nil;
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    pid_t fpid = (front && front != NSRunningApplication.currentApplication) ? front.processIdentifier : self.lastFront;
    if (perWindow && fpid > 0) {
        AXUIElementRef ae = AXUIElementCreateApplication(fpid);
        AXUIElementSetMessagingTimeout(ae, 0.1);
        CFTypeRef fw = NULL;
        if (AXUIElementCopyAttributeValue(ae, kAXFocusedWindowAttribute, &fw) == kAXErrorSuccess && fw) self.focusedWin = CFBridgingRelease(fw);
        CFRelease(ae);
    }
    NSArray *tray = @[@(CTBMedia), @(CTBPrev), @(CTBPlay), @(CTBNext), @(CTBVolume), @(CTBWifi), @(CTBBattery), @(CTBClock), @(CTBDesktop)];
    for (NSNumber *k in tray) { CTBItem *t = [CTBItem new]; t.kind = k.integerValue; [items addObject:t]; }
    self.items = items;
    [self layoutItems];
    CTBView *bv = (CTBView *)self.barView;
    if (bv.hover >= 0 && !bv.dragging) {
        NSPoint p = [bv convertPoint:[self.bar convertPointFromScreen:[NSEvent mouseLocation]] fromView:nil];
        bv.hover = [bv indexAt:p];
    }
    [self.barView setNeedsDisplay:YES];
}

// The title carousel: rest 4 s on the start, glide to the end at a steady reading pace, rest 2 s, glide back, repeat.
// Steady means constant speed with only a half-second ramp at each end (a trapezoid velocity profile) —
// an ease-in-out curve peaks at 1.5–2× its average speed, which read as "fast, then slowing down".
static double glide(double t, double d, double v) {          // position after t seconds of a glide over d points at v pt/s
    double a = 0.5, T = d / v + a;                            // a: ramp time; distance covered = v·(T − a)
    if (T < 2 * a) { double x = MIN(MAX(t / (2 * a), 0), 1); return d * x * x * (3 - 2 * x); }   // very short: one gentle curve
    if (t <= 0) return 0;
    if (t < a) return v * t * t / (2 * a);
    if (t < T - a) return v * (t - a / 2);
    if (t < T) return d - v * (T - t) * (T - t) / (2 * a);
    return d;
}
static double glideTime(double d, double v) { return MAX(d / v + 0.5, 1.0); }
- (CGFloat)marqueeOffset {
    CGFloat d = self.marqueeOverflow; if (d <= 0) return 0;
    const double speed = 22, backSpeed = 44;                   // points per second: about three characters a second
    double hold1 = 4, move = glideTime(d, speed), hold2 = 2, back = glideTime(d, backSpeed), total = hold1 + move + hold2 + back;
    double t = fmod(CACurrentMediaTime() - self.marqueeStart, total);
    if (t < hold1) return 0;
    if (t < hold1 + move) return glide(t - hold1, d, speed);
    if (t < hold1 + move + hold2) return d;
    return d - glide(t - hold1 - move - hold2, d, backSpeed);
}
// 60 fps only while the title overflows; frames where nothing moves aren't redrawn.
- (void)updateMarquee {
    BOOL want = [self showsMedia] && self.marqueeOverflow > 0 && self.bar.visible && !self.hiddenAway;
    if (!want) { [self.marqueeTimer invalidate]; self.marqueeTimer = nil; return; }
    if (self.marqueeTimer) return;
    __weak CTaskbar *ws = self;
    self.marqueeTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
        CGFloat off = [ws marqueeOffset];
        if (fabs(off - ws.marqueeShown) < 0.05) return;
        ws.marqueeShown = off;
        for (CTBItem *it in ws.items) if (it.kind == CTBMedia) [ws.barView setNeedsDisplayInRect:it.rect];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.marqueeTimer forMode:NSRunLoopCommonModes];
}
- (BOOL)showsMedia { return [self wants:@"taskbarMedia" fallback:YES] && self.app.hasNow && self.app.nowTitle.length; }

- (void)layoutItems {
    CGFloat W = self.barView.bounds.size.width, H = self.barView.bounds.size.height ?: gBarH;
    NSDictionary *ta = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]};
    NSDictionary *da = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]};
    CGFloat clockW = MAX([self.clockText ?: @"" sizeWithAttributes:ta].width, [self.dateText ?: @"" sizeWithAttributes:da].width) + 22;
    // Right to left: desktop, clock, battery, Wi-Fi, volume, now playing.
    CGFloat x = W - 4;
    NSMutableArray *visible = [NSMutableArray new];
    for (CTBItem *it in [self.items reverseObjectEnumerator]) {
        if (it.kind == CTBTask || it.kind == CTBStart) continue;
        CGFloat w = 0;
        switch (it.kind) {
            case CTBDesktop: w = [self wants:@"taskbarDesktop" fallback:YES] ? 30 : 0; if (w) x -= 4; break;
            case CTBClock: w = [self wants:@"taskbarClock" fallback:YES] ? ceil(clockW) : 0; break;
            case CTBBattery: w = self.hasBattery && [self wants:@"taskbarBattery" fallback:YES] ? 33 + ceil([[NSString stringWithFormat:@"%ld%%", (long)self.battery] sizeWithAttributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium]}].width) + 10 : 0; break;
            case CTBWifi: w = [self wants:@"taskbarWifi" fallback:YES] ? 32 : 0; break;
            case CTBVolume: w = [self wants:@"taskbarVolume" fallback:YES] ? 32 : 0; break;
            case CTBMedia: if ([self showsMedia] && ![self wants:@"taskbarMediaControls" fallback:YES]) x -= 10;
                w = [self showsMedia] ? MIN(230, MAX(120, ceil([self.app.nowTitle sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}].width) + 58)) : 0; break;
            case CTBPrev: case CTBPlay: case CTBNext:                       // ⏮ ⏯ ⏭ beside the title
                w = [self showsMedia] && [self wants:@"taskbarMediaControls" fallback:YES] ? 28 : 0;
                if (w && it.kind == CTBNext) x -= 10;
                break;
            default: break;
        }
        if (w <= 0) { it.rect = NSZeroRect; continue; }
        x -= w; it.rect = NSMakeRect(x, 0, w, H); [visible addObject:it];
    }
    CGFloat trayLeft = x - 14;
    // Left to right: launcher, then apps; slots shrink if there are too many to fit.
    CGFloat lx = 6;
    NSInteger tasks = 0; for (CTBItem *it in self.items) if (it.kind == CTBTask) tasks++;
    CGFloat avail = trayLeft - (lx + 44 + 12);
    // With names, each app takes what its name needs (up to 170). If that doesn't fit, only running apps keep
    // their names; if even that doesn't fit, everything is icon-only — never a row of "Fi…".
    NSMutableDictionary<NSValue *, NSNumber *> *width = [NSMutableDictionary new];
    CGFloat slot = tasks ? MIN(gTaskW, MAX(30, floor(avail / tasks))) : gTaskW;
    if (gLabels) {
        NSDictionary *na = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]};
        for (NSInteger tier = 0; tier < 2; tier++) {
            CGFloat sum = 0; [width removeAllObjects];
            for (CTBItem *it in self.items) if (it.kind == CTBTask) {
                BOOL named = tier == 0 || it.app;
                CGFloat w = named ? MIN(170, ceil([it.title ?: @"" sizeWithAttributes:na].width) + gTaskIcon + 34) : gTaskW;
                width[[NSValue valueWithNonretainedObject:it]] = @(w); sum += w + 2;
            }
            if (sum <= avail) break;
            [width removeAllObjects];
        }
    }
    for (CTBItem *it in self.items) {
        if (it.kind == CTBStart) { it.rect = NSMakeRect(lx, 0, 44, H); lx += 44 + 12; }
        else if (it.kind == CTBTask) {
            NSNumber *nw = width[[NSValue valueWithNonretainedObject:it]];
            CGFloat w = nw ? nw.doubleValue : slot;
            if (lx + w > trayLeft) { it.rect = NSZeroRect; continue; }
            it.rect = NSMakeRect(lx, 0, w, H); lx += w + (nw ? 2 : 0);
        }
    }
}

- (BOOL)isActive:(CTBItem *)it {
    if (it.sampleActive) return YES;
    if (!it.app || it.app.hidden) return NO;
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    pid_t pid = (front && front != NSRunningApplication.currentApplication) ? front.processIdentifier : self.lastFront;
    if (it.app.processIdentifier != pid) return NO;
    if (!it.win) return YES;
    if (it.minimized) return NO;
    if (self.focusedWin) return CFEqual((__bridge CFTypeRef)it.win, (__bridge CFTypeRef)self.focusedWin);
    for (CTBItem *x in self.items) if (x.app == it.app && x.win && !x.minimized) return x == it;   // no focus info: the app's first open window
    return NO;
}

#pragma mark Windows (Accessibility)

// Windows in the order they first appeared, so focusing one never reshuffles the bar.
- (NSArray<NSDictionary *> *)ordered:(NSArray<NSDictionary *> *)now pid:(pid_t)pid {
    if (!now.count) return @[];
    NSNumber *key = @(pid);
    NSMutableArray *order = [NSMutableArray new];
    NSMutableArray *els = [NSMutableArray new]; for (NSDictionary *w in now) [els addObject:w[@"win"]];
    for (id el in self.winOrder[key]) if ([els containsObject:el]) [order addObject:el];       // isEqual: on AX elements is CFEqual
    for (id el in els) if (![order containsObject:el]) [order addObject:el];
    self.winOrder[key] = order;
    NSMutableArray *out = [NSMutableArray new];
    for (id el in order) [out addObject:now[[els indexOfObject:el]]];
    return out;
}

static void axWindowEvent(AXObserverRef obs, AXUIElementRef el, CFStringRef note, void *ctx) {
    CTaskbar *tb = (__bridge CTaskbar *)ctx;
    BOOL resized = CFEqual(note, kAXWindowResizedNotification), created = CFEqual(note, kAXWindowCreatedNotification);
    if (resized || created) [tb windowNeedsFit:(__bridge id)el];
    if (!resized) [tb windowsChanged];                                  // a resize alone doesn't change the buttons
}
// One observer per running app (needs Accessibility). App-level: windows created, focus moves. Per window: closed,
// minimised, restored, renamed — re-adding an existing registration is a cheap no-op, so this runs on every rebuild.
// Returns each app's current windows (pid → list), read once per rebuild.
- (NSDictionary<NSNumber *, NSArray *> *)watchWindows:(NSArray<NSRunningApplication *> *)running {
    NSMutableSet *alive = [NSMutableSet new];
    NSMutableDictionary *lists = [NSMutableDictionary new];
    for (NSRunningApplication *r in running) {
        NSNumber *key = @(r.processIdentifier); [alive addObject:key];
        AXObserverRef obs = (__bridge AXObserverRef)self.observers[key];
        AXUIElementRef ae = AXUIElementCreateApplication(r.processIdentifier);
        AXUIElementSetMessagingTimeout(ae, 0.1);
        if (!obs) {
            if (AXObserverCreate(r.processIdentifier, axWindowEvent, &obs) == kAXErrorSuccess && obs) {
                self.observers[key] = CFBridgingRelease(obs);
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), kCFRunLoopCommonModes);
                for (NSString *n in @[(id)kAXWindowCreatedNotification, (id)kAXFocusedWindowChangedNotification, (id)kAXMainWindowChangedNotification])
                    AXObserverAddNotification(obs, ae, (__bridge CFStringRef)n, (__bridge void *)self);
                for (NSDictionary *w in appWindows(r)) [self windowNeedsFit:w[@"win"]];   // an app just launched may open over the bar
            } else obs = NULL;                                       // still list its windows; they just won't update live
        }
        NSArray *wins = appWindows(r); lists[key] = wins;
        if (obs) for (NSDictionary *w in wins)
            for (NSString *n in @[(id)kAXUIElementDestroyedNotification, (id)kAXWindowMiniaturizedNotification, (id)kAXWindowDeminiaturizedNotification, (id)kAXTitleChangedNotification, (id)kAXWindowResizedNotification])
                AXObserverAddNotification(obs, (__bridge AXUIElementRef)w[@"win"], (__bridge CFStringRef)n, (__bridge void *)self);
        CFRelease(ae);
    }
    for (NSNumber *key in self.observers.allKeys) if (![alive containsObject:key]) {      // app quit (or windows grouped again)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource((__bridge AXObserverRef)self.observers[key]), kCFRunLoopCommonModes);
        [self.observers removeObjectForKey:key];
    }
    for (NSNumber *key in self.winOrder.allKeys) if (![alive containsObject:key]) [self.winOrder removeObjectForKey:key];
    return lists;
}
#pragma mark Keeping windows clear of the bar (Accessibility)

// macOS lets only the Dock shrink the usable screen, so like ExtraDock and uBar, Centre trims windows itself:
// any window zoomed, tiled, resized or opened over the bar is cut to end exactly at its edge.
// It waits until the window has settled and the mouse is up, so it never fights a drag.
- (BOOL)fitsWindows {
    return self.built && self.tick && !self.app.snapshotDir && [self wants:@"taskbarFitWindows" fallback:YES] && AXIsProcessTrusted()
        && ![self wants:@"taskbarAutoHide" fallback:NO] && !self.fullScreenAway;
}
- (void)windowNeedsFit:(id)win {
    if (!win || ![self fitsWindows]) return;
    if (!self.pendingFit) self.pendingFit = [NSMutableArray new];
    if (![self.pendingFit containsObject:win]) [self.pendingFit addObject:win];
    [self.fitTimer invalidate];
    __weak CTaskbar *ws = self;
    self.fitTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *t) { [ws fitPending]; }];
}
- (void)fitPending {
    self.fitTimer = nil;
    if ([NSEvent pressedMouseButtons]) {                                // still dragging: look again shortly
        __weak CTaskbar *ws = self;
        self.fitTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:NO block:^(NSTimer *t) { [ws fitPending]; }];
        return;
    }
    NSArray *wins = self.pendingFit; self.pendingFit = nil;
    for (id w in wins) [self fitWindow:w];
}
- (void)sweepWindows {
    if (![self fitsWindows]) return;
    for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
        if (r.activationPolicy == NSApplicationActivationPolicyRegular && r != NSRunningApplication.currentApplication && !r.hidden)
            for (NSDictionary *w in appWindows(r)) [self fitWindow:w[@"win"]];
}
// An app that refuses the height (a minimum size, or size steps) would be trimmed forever. Remember the exact frame it
// stayed at; skip only while it's still at that frame, so every new zoom or resize gets trimmed again.
static CGRect axFrame(AXUIElementRef w) {
    CFTypeRef pv = NULL, sv = NULL; CGPoint p = CGPointZero; CGSize sz = CGSizeZero;
    BOOL ok = AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &pv) == kAXErrorSuccess && pv && AXValueGetValue((AXValueRef)pv, kAXValueTypeCGPoint, &p);
    ok = ok && AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sv) == kAXErrorSuccess && sv && AXValueGetValue((AXValueRef)sv, kAXValueTypeCGSize, &sz);
    if (pv) CFRelease(pv);
    if (sv) CFRelease(sv);
    return ok ? CGRectMake(p.x, p.y, sz.width, sz.height) : CGRectNull;
}
- (BOOL)refusedAt:(id)win frame:(CGRect)r {
    NSValue *v = [self.refused objectForKey:win];
    return v && CGRectEqualToRect(NSRectToCGRect(v.rectValue), r);
}
- (void)checkTrim:(id)win wanted:(CGFloat)limit top:(BOOL)top {
    CGRect now = axFrame((__bridge AXUIElementRef)win);
    if (!self.refused) self.refused = [NSMapTable strongToStrongObjectsMapTable];   // keys compare with CFEqual
    if (self.refused.count > 64) [self.refused removeAllObjects];
    BOOL still = !CGRectIsNull(now) && (top ? CGRectGetMinY(now) < limit - 1 : CGRectGetMaxY(now) > limit + 1);
    if (still) [self.refused setObject:[NSValue valueWithRect:NSRectFromCGRect(now)] forKey:win];
    else [self.refused removeObjectForKey:win];
}
static BOOL axBool(AXUIElementRef w, CFStringRef attr) {
    CFTypeRef v = NULL; BOOL on = NO;
    if (AXUIElementCopyAttributeValue(w, attr, &v) == kAXErrorSuccess && v) { on = CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v); CFRelease(v); }
    return on;
}
- (void)fitWindow:(id)win {
    if (![self fitsWindows] || !self.bar.visible) return;
    AXUIElementRef w = (__bridge AXUIElementRef)win;
    if (axBool(w, CFSTR("AXFullScreen")) || axBool(w, kAXMinimizedAttribute)) return;
    CFTypeRef sub = NULL; AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, &sub);
    BOOL standard = sub && CFEqual(sub, kAXStandardWindowSubrole); if (sub) CFRelease(sub);
    if (!standard) return;                                              // dialogs, sheets, panels and popovers are left alone
    CGRect r = axFrame(w);
    if (CGRectIsNull(r)) return;
    CGPoint p = r.origin; CGSize sz = r.size;
    // Accessibility uses top-left coordinates from the main display; the bar lives on that display.
    NSRect bar = [self barFrame], scr = [self screen].frame;
    CGFloat H = NSMaxY(NSScreen.screens.firstObject.frame);
    CGFloat barTop = H - NSMaxY(bar), barBottom = H - NSMinY(bar), scrTop = H - NSMaxY(scr), scrBottom = H - NSMinY(scr);
    if (CGRectGetMaxX(r) < NSMinX(bar) + 20 || CGRectGetMinX(r) > NSMaxX(bar) - 20) return;          // not over the bar
    if (CGRectGetMinY(r) < scrTop - 2 || CGRectGetMaxY(r) > scrBottom + 2) return;                    // another display, or partly off screen on purpose
    if (!gTop) {
        CGFloat limit = barTop;                                         // flush with the bar's top edge
        if (CGRectGetMaxY(r) <= limit + 1) { [self.refused removeObjectForKey:win]; return; }         // clear (apps like Brave apply a trim late)
        if (limit - CGRectGetMinY(r) < 120) return;                                                    // too little room left
        if ([self refusedAt:win frame:r]) return;
        CGSize ns = CGSizeMake(sz.width, floor(limit - CGRectGetMinY(r)));
        AXValueRef v = AXValueCreate(kAXValueTypeCGSize, &ns); AXUIElementSetAttributeValue(w, kAXSizeAttribute, v); CFRelease(v);
        [self checkTrim:win wanted:limit top:NO];
    } else {
        CGFloat limit = barBottom;
        if (CGRectGetMinY(r) >= limit - 1) { [self.refused removeObjectForKey:win]; return; }
        if (CGRectGetMaxY(r) - limit < 120) return;
        if ([self refusedAt:win frame:r]) return;
        CGPoint np = CGPointMake(p.x, limit); CGSize ns = CGSizeMake(sz.width, floor(CGRectGetMaxY(r) - limit));
        AXValueRef v = AXValueCreate(kAXValueTypeCGPoint, &np); AXUIElementSetAttributeValue(w, kAXPositionAttribute, v); CFRelease(v);
        v = AXValueCreate(kAXValueTypeCGSize, &ns); AXUIElementSetAttributeValue(w, kAXSizeAttribute, v); CFRelease(v);
        [self checkTrim:win wanted:limit top:YES];
    }
}

// A burst of window events (a new window is created, focused and titled at once) rebuilds the bar once.
- (void)windowsChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rebuild) object:nil];
    [self performSelector:@selector(rebuild) withObject:nil afterDelay:0.12 inModes:@[NSRunLoopCommonModes]];
}
// Core Apple events (reopen, quit) are what the Dock sends; they need no Automation permission.
static BOOL sendAppEvent(NSRunningApplication *r, AEEventID eid) {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:r.processIdentifier];
    NSAppleEventDescriptor *ev = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:eid targetDescriptor:target
                                                                       returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    OSStatus st = AESendMessage(ev.aeDesc, NULL, kAENoReply | kAENeverInteract, kAEDefaultTimeout);
    return st == noErr;
}
static void raiseWindow(id win, NSRunningApplication *r) {
    AXUIElementRef w = (__bridge AXUIElementRef)win;
    if (r.hidden) [r unhide];
    CFTypeRef mn = NULL;
    if (AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute, &mn) == kAXErrorSuccess && mn) {
        if (CFGetTypeID(mn) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)mn)) AXUIElementSetAttributeValue(w, kAXMinimizedAttribute, kCFBooleanFalse);
        CFRelease(mn);
    }
    AXUIElementPerformAction(w, kAXRaiseAction);
    AXUIElementSetAttributeValue(w, kAXMainAttribute, kCFBooleanTrue);
    [r activateWithOptions:0];
}

- (NSImage *)iconForPath:(NSString *)p {
    if (!p) return nil;
    NSImage *i = self.icons[p];
    if (!i) {
        i = prerenderIcon([[NSWorkspace sharedWorkspace] iconForFile:p]) ?: [[NSWorkspace sharedWorkspace] iconForFile:p];
        if (i) self.icons[p] = i;
    }
    return i;
}

#pragma mark Status (clock every second; volume every 2 s; battery and network every 10 s)

- (void)refreshStatus:(BOOL)all {
    self.ticks++;
    BOOL dirty = NO, relayout = NO;
    static NSDateFormatter *tf, *df; static NSString *tfKey;          // rebuilt only when the clock settings change
    BOOL secs = [self wants:@"taskbarSeconds" fallback:NO], h24 = [self wants:@"taskbar24h" fallback:NO];
    NSString *key = [NSString stringWithFormat:@"%d%d%@", secs, h24, [NSLocale autoupdatingCurrentLocale].localeIdentifier];
    if (!tf || ![key isEqualToString:tfKey]) {
        tf = [NSDateFormatter new]; tf.locale = [NSLocale autoupdatingCurrentLocale];
        tf.dateFormat = [NSDateFormatter dateFormatFromTemplate:h24 ? (secs ? @"HHmmss" : @"HHmm") : (secs ? @"jmmss" : @"jmm") options:0 locale:tf.locale];
        df = [NSDateFormatter new]; df.locale = tf.locale;
        df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEdMMM" options:0 locale:df.locale];
        tfKey = key;
    }
    NSDate *now = [NSDate date];
    NSString *clock = [[tf stringFromDate:now] stringByReplacingOccurrencesOfString:@"\u202f" withString:@" "];   // narrow no-break space before am/pm
    NSString *date = [self wants:@"taskbarDate" fallback:YES] ? [df stringFromDate:now] : @"";
    if (![clock isEqualToString:self.clockText] || ![date isEqualToString:self.dateText]) {
        relayout = self.clockText.length != clock.length || self.dateText.length != date.length;
        self.clockText = clock; self.dateText = date; dirty = YES;
    }
    if (all || self.ticks % 2 == 0) {
        float v = 0; BOOL m = NO; BOOL ok = readVolume(&v, &m);
        if (ok != self.hasVolume || fabsf(v - self.volume) > 0.004 || m != self.muted) { self.hasVolume = ok; self.volume = v; self.muted = m; dirty = YES; }
    }
    if (all || self.ticks % 10 == 0) {
        NSInteger pct = self.battery; BOOL chg = self.charging, ac = self.onPower, has = NO;
        CFTypeRef info = IOPSCopyPowerSourcesInfo();
        CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
        if (list && CFArrayGetCount(list) > 0) {
            NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, 0));
            if ([d[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) {
                has = YES;
                pct = [d[@kIOPSCurrentCapacityKey] integerValue] * 100 / MAX([d[@kIOPSMaxCapacityKey] integerValue], 1);
                chg = [d[@kIOPSIsChargingKey] boolValue]; ac = [d[@kIOPSPowerSourceStateKey] isEqual:@kIOPSACPowerValue];
            }
        }
        if (list) CFRelease(list);
        if (info) CFRelease(info);
        if (has != self.hasBattery || pct != self.battery || chg != self.charging || ac != self.onPower) {
            relayout |= has != self.hasBattery || (pct == 100) != (self.battery == 100) || (pct < 10) != (self.battery < 10);
            self.hasBattery = has; self.battery = pct; self.charging = chg; self.onPower = ac; dirty = YES;
        }
        BOOL online = NO; struct ifaddrs *ifs = NULL;
        if (getifaddrs(&ifs) == 0) {
            for (struct ifaddrs *a = ifs; a; a = a->ifa_next)
                if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP) && !(a->ifa_flags & IFF_LOOPBACK) && strncmp(a->ifa_name, "en", 2) == 0) { online = YES; break; }
            freeifaddrs(ifs);
        }
        if (online != self.online) { self.online = online; dirty = YES; }
    }
    // Now playing comes and goes with the media app; its width changes the tray.
    BOOL media = [self showsMedia];
    static NSString *lastTitle; static BOOL lastMedia;
    if (media != lastMedia || (media && ![self.app.nowTitle isEqualToString:lastTitle ?: @""])) {
        lastMedia = media; lastTitle = self.app.nowTitle; relayout = YES;
        self.marqueeStart = CACurrentMediaTime(); self.marqueeOverflow = 0;   // a new song starts at its beginning
    }
    [self updateMarquee];
    if (media) dirty = YES;
    if (relayout) [self layoutItems];
    if (dirty || relayout) [self.barView setNeedsDisplay:YES];
}

#pragma mark Actions

- (void)clickItem:(CTBItem *)it {
    switch (it.kind) {
        case CTBStart: [self.app toggle]; break;
        case CTBTask: {
            NSRunningApplication *r = it.app;
            if (!r) { [self launch:it.path]; break; }
            if (it.win) {                                              // one window: minimise it if it's the one you're in, else bring it back
                if ([self isActive:it]) AXUIElementSetAttributeValue((__bridge AXUIElementRef)it.win, kAXMinimizedAttribute, kCFBooleanTrue);
                else raiseWindow(it.win, r);
                [self windowsChanged];
                break;
            }
            NSArray *wins = appWindows(r); NSDictionary *open = nil, *mini = nil;
            for (NSDictionary *w in wins) { if (![w[@"min"] boolValue]) { open = w; break; } if (!mini) mini = w; }
            // The app in front gets out of the way — unless it has nothing on screen (its window closed), then it reopens.
            if ([self isActive:it] && (open || !AXIsProcessTrusted())) { [r hide]; break; }
            if (r.hidden) [r unhide];
            // Grouped: if every window is minimised, bring the most recent back, like the Dock does.
            if (!open && mini) { raiseWindow(mini[@"win"], r); break; }
            // What the Dock does: bring it forward and send "reopen", so an app whose windows are closed or hidden
            // (GitHub Desktop and other Electron apps hide theirs) shows one again.
            [r activateWithOptions:NSApplicationActivateAllWindows];
            sendAppEvent(r, kAEReopenApplication);
            break;
        }
        case CTBMedia: [self.app mediaCommand:2]; break;
        case CTBPrev: [self.app mediaCommand:5]; break;
        case CTBPlay: [self.app mediaCommand:2]; break;
        case CTBNext: [self.app mediaCommand:4]; break;
        case CTBVolume: writeMute(!self.muted); [self refreshStatus:YES]; break;
        case CTBWifi: openURLString(@"x-apple.systempreferences:com.apple.wifi-settings-extension"); break;
        case CTBBattery: openURLString(@"x-apple.systempreferences:com.apple.Battery-Settings.extension"); break;
        case CTBClock: [self showCalendar:it]; break;
        case CTBDesktop: [self peekDesktop]; break;
    }
}
- (void)launch:(NSString *)path {
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration]; cfg.activates = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:path] configuration:cfg completionHandler:nil];
}

// First click hides every app to show the desktop; the next click brings exactly those apps back.
- (void)peekDesktop {
    NSMutableArray *still = [NSMutableArray new];
    for (NSRunningApplication *r in self.peeked) if (!r.terminated && r.hidden) [still addObject:r];
    if (still.count) {
        for (NSRunningApplication *r in still) [r unhide];
        // The app you were in comes back in front, its windows on top, as you left them.
        NSRunningApplication *f = self.peekFront;
        if (f && !f.terminated) [f activateWithOptions:NSApplicationActivateAllWindows];
        self.peeked = nil; self.peekFront = nil;
    } else {
        NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
        self.peekFront = (front && front != NSRunningApplication.currentApplication) ? front : [NSRunningApplication runningApplicationWithProcessIdentifier:self.lastFront];
        // Centre takes the front (it has no windows), so every app — Finder's windows too — can be hidden;
        // the active app can't always be hidden while it's in front, which is what left windows behind before.
        [NSApp activateIgnoringOtherApps:YES];
        NSMutableArray *hid = [NSMutableArray new];
        for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
            if (r.activationPolicy == NSApplicationActivationPolicyRegular && !r.hidden && r != NSRunningApplication.currentApplication)
                if ([r hide]) [hid addObject:r];
        self.peeked = hid;
    }
    [self.barView setNeedsDisplay:YES];
}

- (void)scrollOnItem:(CTBItem *)it event:(NSEvent *)e {
    if (it.kind != CTBVolume || !self.hasVolume) return;
    CGFloat d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.004 : e.scrollingDeltaY * 0.03;
    if (e.isDirectionInvertedFromDevice) d = -d;
    float v = (float)MIN(MAX((self.muted ? 0 : self.volume) + d, 0), 1);
    writeVolume(v);
    self.volume = v; self.muted = v <= 0.001;
    [self.barView setNeedsDisplay:YES];
}

#pragma mark Calendar

- (void)showCalendar:(CTBItem *)it {
    if (self.calendar.shown) { [self.calendar close]; return; }
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 252, 250)];
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale autoupdatingCurrentLocale];
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEEdMMMMyyyy" options:0 locale:f.locale];
    NSTextField *day = [NSTextField labelWithString:[f stringFromDate:[NSDate date]]];
    day.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]; day.frame = NSMakeRect(16, 214, 222, 20);
    NSDatePicker *dp = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
    dp.datePickerStyle = NSDatePickerStyleClockAndCalendar; dp.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    dp.dateValue = [NSDate date]; dp.bezeled = NO; dp.bordered = NO; dp.drawsBackground = NO;
    [dp sizeToFit];
    dp.frame = NSMakeRect(floor((252 - dp.frame.size.width) / 2), 14, dp.frame.size.width, dp.frame.size.height);
    [v addSubview:day]; [v addSubview:dp];
    NSViewController *vc = [NSViewController new]; vc.view = v;
    NSPopover *pop = [NSPopover new]; pop.contentViewController = vc; pop.behavior = NSPopoverBehaviorTransient; pop.animates = YES; pop.delegate = self;
    pop.contentSize = NSMakeSize(252, MAX(250, dp.frame.size.height + 56));
    day.frame = NSMakeRect(16, pop.contentSize.height - 36, 222, 20);
    self.calendar = pop;
    [NSApp activateIgnoringOtherApps:YES];                     // a transient popover closes when you click elsewhere only if Centre is active
    [pop showRelativeToRect:it.rect ofView:self.barView preferredEdge:gTop ? NSRectEdgeMinY : NSRectEdgeMaxY];
}

// The calendar had to activate Centre; when it closes, give focus back to the app you were using
// (unless you've opened a Centre window meanwhile).
- (void)popoverDidClose:(NSNotification *)n {
    if (![NSApp isActive] || self.app.panel.visible || self.app.settings.window.visible) return;
    NSRunningApplication *r = [NSRunningApplication runningApplicationWithProcessIdentifier:self.lastFront];
    [r activateWithOptions:0];
}

#pragma mark Menus

static NSArray<NSDictionary *> *appWindows(NSRunningApplication *r) {
    NSMutableArray *out = [NSMutableArray new];
    if (!r || !AXIsProcessTrusted()) return out;
    AXUIElementRef ae = AXUIElementCreateApplication(r.processIdentifier);
    AXUIElementSetMessagingTimeout(ae, 0.15);
    CFTypeRef wins = NULL;
    if (AXUIElementCopyAttributeValue(ae, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins && CFGetTypeID(wins) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(wins) && out.count < 12; i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            CFTypeRef sub = NULL; AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, &sub);
            BOOL standard = !sub || CFEqual(sub, kAXStandardWindowSubrole); if (sub) CFRelease(sub);
            if (!standard) continue;
            CFTypeRef t = NULL; AXUIElementCopyAttributeValue(w, kAXTitleAttribute, &t);
            NSString *title = (t && CFGetTypeID(t) == CFStringGetTypeID()) ? [(__bridge NSString *)t copy] : nil; if (t) CFRelease(t);
            // Finder reports the desktop as an untitled window; real Finder windows are always named after a folder.
            if (!title.length && [r.bundleIdentifier isEqualToString:@"com.apple.finder"]) continue;
            CFTypeRef sz = NULL; CGSize size = CGSizeZero;
            if (AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sz) == kAXErrorSuccess && sz) { AXValueGetValue((AXValueRef)sz, kAXValueTypeCGSize, &size); CFRelease(sz); }
            if (size.width < 60 || size.height < 40) continue;                    // invisible helper windows
            CFTypeRef mn = NULL; AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute, &mn);
            BOOL mini = mn && CFGetTypeID(mn) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)mn); if (mn) CFRelease(mn);
            [out addObject:@{@"title": title.length ? title : (r.localizedName ?: @"Window"), @"win": (__bridge id)w, @"min": @(mini)}];
        }
    }
    if (wins) CFRelease(wins);
    CFRelease(ae);
    return out;
}

- (NSMenuItem *)item:(NSString *)t action:(SEL)a object:(id)o {
    NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:@""]; m.target = self; m.representedObject = o; return m;
}

- (void)menuForItem:(CTBItem *)it event:(NSEvent *)e {
    NSMenu *m = [NSMenu new]; m.autoenablesItems = NO;
    switch (it.kind) {
        case CTBStart:
            [m addItem:[self item:@"Open Centre" action:@selector(menuOpenCentre:) object:nil]];
            [m addItem:[self item:@"Taskbar Settings…" action:@selector(menuSettings:) object:@"Taskbar"]];
            [m addItem:[self item:@"Centre Settings…" action:@selector(menuSettings:) object:@"General"]];
            [m addItem:[NSMenuItem separatorItem]];
            [m addItem:[self item:@"Hide Taskbar" action:@selector(menuHideBar:) object:nil]];
            break;
        case CTBTask: {
            NSMenuItem *head = [[NSMenuItem alloc] initWithTitle:it.app.localizedName ?: it.title action:nil keyEquivalent:@""]; head.enabled = NO;
            head.image = [[self iconForPath:it.path] copy]; head.image.size = NSMakeSize(16, 16);
            [m addItem:head];
            NSArray *wins = appWindows(it.app);
            if (wins.count) {
                [m addItem:[NSMenuItem separatorItem]];
                for (NSDictionary *w in wins) {
                    NSString *t = w[@"title"]; if (t.length > 60) t = [[t substringToIndex:60] stringByAppendingString:@"…"];
                    NSMenuItem *wi = [self item:t action:@selector(menuRaise:) object:@{@"w": w, @"pid": @(it.app.processIdentifier)}];
                    wi.image = symSize([w[@"min"] boolValue] ? @"minus.rectangle" : @"macwindow", 12);
                    [m addItem:wi];
                }
            }
            [m addItem:[NSMenuItem separatorItem]];
            if (it.win) {
                [m addItem:[self item:it.minimized ? @"Restore Window" : @"Minimise Window" action:@selector(menuMinimise:) object:it]];
                [m addItem:[self item:@"Close Window" action:@selector(menuCloseWindow:) object:it]];
                [m addItem:[NSMenuItem separatorItem]];
            }
            if (it.app) {
                [m addItem:[self item:it.app.hidden ? @"Show" : @"Hide" action:@selector(menuHide:) object:it.app]];
                NSMenuItem *reveal = [self item:@"Show in Finder" action:@selector(menuReveal:) object:it.path]; [m addItem:reveal];
            } else [m addItem:[self item:@"Open" action:@selector(menuLaunch:) object:it.path]];
            [m addItem:[self item:it.pinned ? @"Unpin from Taskbar" : @"Pin to Taskbar" action:@selector(menuPin:) object:it.path]];
            if (it.app) {
                [m addItem:[NSMenuItem separatorItem]];
                [m addItem:[self item:@"Quit" action:@selector(menuQuit:) object:it.app]];
                // Force Quit: right-click with ⌥ held, or always once Quit failed. Not an ⌥-alternate item: hidden alternates
                // still count in the menu's measured height, which floated the menu a row above the bar.
                BOOL opt = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
                if (opt || [self.stuck containsObject:@(it.app.processIdentifier)])
                    [m addItem:[self item:@"Force Quit" action:@selector(menuForceQuit:) object:it.app]];
            }
            break;
        }
        case CTBMedia: case CTBPrev: case CTBPlay: case CTBNext:
            [m addItem:[self item:self.app.isPlaying ? @"Pause" : @"Play" action:@selector(menuMedia:) object:@2]];
            [m addItem:[self item:@"Next Track" action:@selector(menuMedia:) object:@4]];
            [m addItem:[self item:@"Previous Track" action:@selector(menuMedia:) object:@5]];
            break;
        case CTBVolume:
            [m addItem:[self item:self.muted ? @"Unmute" : @"Mute" action:@selector(menuMute:) object:nil]];
            [m addItem:[self item:@"Sound Settings…" action:@selector(menuURL:) object:@"x-apple.systempreferences:com.apple.Sound-Settings.extension"]];
            break;
        case CTBWifi: [m addItem:[self item:@"Network Settings…" action:@selector(menuURL:) object:@"x-apple.systempreferences:com.apple.Network-Settings.extension"]]; break;
        case CTBBattery: [m addItem:[self item:@"Battery Settings…" action:@selector(menuURL:) object:@"x-apple.systempreferences:com.apple.Battery-Settings.extension"]]; break;
        case CTBClock: [m addItem:[self item:@"Date & Time Settings…" action:@selector(menuURL:) object:@"x-apple.systempreferences:com.apple.Date-Time-Settings.extension"]]; break;
        case CTBDesktop: [m addItem:[self item:@"Show Desktop" action:@selector(menuPeek:) object:nil]]; break;
    }
    if (it.kind >= CTBMedia && ![self wants:@"taskbarClock" fallback:YES]) {   // clock hidden: its calendar lives on in the tray's menus
        [m addItem:[NSMenuItem separatorItem]];
        [m addItem:[self item:@"Calendar" action:@selector(menuCalendar:) object:it]];
    }
    self.menuOpen = YES;
    // While a menu tracks, macOS holds Centre's global shortcut in the event queue until the menu closes. Look for it
    // and close the menu, so the shortcut opens Centre at once (it runs as soon as tracking ends).
    EventTypeSpec hot = {kEventClassKeyboard, kEventHotKeyPressed};
    NSTimer *watch = [NSTimer timerWithTimeInterval:0.04 repeats:YES block:^(NSTimer *t) {
        EventRef e = AcquireFirstMatchingEventInQueue(GetMainEventQueue(), 1, &hot, kEventQueueOptionsNone);
        if (e) { ReleaseEvent(e); [m cancelTrackingWithoutAnimation]; }
    }];
    [[NSRunLoop mainRunLoop] addTimer:watch forMode:NSRunLoopCommonModes];
    // The menu's top-left goes at the location: just above the bar at the bottom, just below it at the top.
    NSPoint at = gTop ? NSMakePoint(NSMinX(it.rect) + 4, NSMinY(it.rect) - 6) : NSMakePoint(NSMinX(it.rect) + 4, NSMaxY(it.rect) + 6 + m.size.height);
    [m popUpMenuPositioningItem:nil atLocation:at inView:self.barView];
    [watch invalidate];
    self.menuOpen = NO;
    [self.barView setNeedsDisplay:YES];
}
- (void)menuOpenCentre:(id)s { [self.app show]; }
- (void)menuSettings:(NSMenuItem *)m { [self.app openSettingsPage:m.representedObject]; }
- (void)menuHideBar:(id)s {
    NSMutableDictionary *c = [self.app mutableConfig]; c[@"taskbarEnabled"] = @NO; [self.app writeConfig:c];
    showHUD(@"Taskbar hidden · turn it back on in Settings › Taskbar", @"dock.rectangle");
}
- (void)menuRaise:(NSMenuItem *)m {
    NSDictionary *w = m.representedObject[@"w"]; AXUIElementRef win = (__bridge AXUIElementRef)w[@"win"];
    if ([w[@"min"] boolValue]) AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanFalse);
    AXUIElementPerformAction(win, kAXRaiseAction);
    AXUIElementSetAttributeValue(win, kAXMainAttribute, kCFBooleanTrue);
    NSRunningApplication *r = [NSRunningApplication runningApplicationWithProcessIdentifier:[m.representedObject[@"pid"] intValue]];
    if (r.hidden) [r unhide];
    [r activateWithOptions:0];
}
- (void)menuMinimise:(NSMenuItem *)m {
    CTBItem *it = m.representedObject;
    if (it.minimized) raiseWindow(it.win, it.app);
    else AXUIElementSetAttributeValue((__bridge AXUIElementRef)it.win, kAXMinimizedAttribute, kCFBooleanTrue);
    [self windowsChanged];
}
- (void)menuCloseWindow:(NSMenuItem *)m {                       // presses the window's own close button, so the app can ask to save
    CTBItem *it = m.representedObject; CFTypeRef btn = NULL;
    if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)it.win, kAXCloseButtonAttribute, &btn) == kAXErrorSuccess && btn) {
        AXUIElementPerformAction((AXUIElementRef)btn, kAXPressAction); CFRelease(btn);
    }
    [self windowsChanged];
}
- (void)menuHide:(NSMenuItem *)m { NSRunningApplication *r = m.representedObject; if (r.hidden) { [r unhide]; [r activateWithOptions:0]; } else [r hide]; }
- (void)menuReveal:(NSMenuItem *)m { [[NSWorkspace sharedWorkspace] selectFile:m.representedObject inFileViewerRootedAtPath:@""]; }
- (void)menuLaunch:(NSMenuItem *)m { [self launch:m.representedObject]; }
- (void)menuPin:(NSMenuItem *)m {
    NSMutableArray *p = [[self pinnedPaths] mutableCopy]; NSString *path = m.representedObject;
    if ([p containsObject:path]) [p removeObject:path]; else [p addObject:path];
    [self setPinnedPaths:p];
}
- (void)menuQuit:(NSMenuItem *)m {
    NSRunningApplication *r = m.representedObject;
    if (![r terminate]) sendAppEvent(r, kAEQuitApplication);             // terminate refused: ask the way the Dock does
    // A stuck app accepts the request and never quits. Say so, and offer Force Quit openly on its next menu.
    __weak CTaskbar *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (r.terminated) return;
        if (!ws.stuck) ws.stuck = [NSMutableSet new];
        [ws.stuck addObject:@(r.processIdentifier)];
        showHUDFor([NSString stringWithFormat:@"%@ didn't quit · right-click it for Force Quit", r.localizedName ?: @"The app"], @"exclamationmark.triangle.fill", 4);
    });
}
- (void)menuForceQuit:(NSMenuItem *)m { [(NSRunningApplication *)m.representedObject forceTerminate]; }
- (void)menuMedia:(NSMenuItem *)m { [self.app mediaCommand:[m.representedObject intValue]]; }
- (void)menuMute:(id)s { writeMute(!self.muted); [self refreshStatus:YES]; }
- (void)menuURL:(NSMenuItem *)m { openURLString(m.representedObject); }
- (void)menuPeek:(id)s { [self peekDesktop]; }
- (void)menuCalendar:(NSMenuItem *)m { CTBItem *it = m.representedObject; dispatch_async(dispatch_get_main_queue(), ^{ [self showCalendar:it]; }); }   // after the menu has closed

#pragma mark Tooltips (a small glass label above the hovered item)

- (NSString *)tipFor:(CTBItem *)it {
    switch (it.kind) {
        case CTBStart: return @"Centre  ·  right-click for settings";
        case CTBTask: {
            if (!it.app) return it.title;
            if (it.win) {
                NSString *t = it.title.length > 70 ? [[it.title substringToIndex:70] stringByAppendingString:@"…"] : it.title;
                NSString *name = it.app.localizedName ?: @"";
                return [NSString stringWithFormat:@"%@%@%@", [t isEqualToString:name] ? t : [NSString stringWithFormat:@"%@  ·  %@", t, name],
                        it.minimized ? @"  ·  minimised" : @"", it.app.hidden ? @"  ·  hidden" : @""];
            }
            NSUInteger n = appWindows(it.app).count;
            NSString *w = n ? [NSString stringWithFormat:@"  ·  %lu window%@", (unsigned long)n, n == 1 ? @"" : @"s"] : @"";
            return [NSString stringWithFormat:@"%@%@%@", it.title, it.app.hidden ? @"  ·  hidden" : @"", w];
        }
        case CTBPrev: return @"Previous track";
        case CTBPlay: return self.app.isPlaying ? @"Pause" : @"Play";
        case CTBNext: return @"Next track";
        case CTBMedia: return [NSString stringWithFormat:@"%@  ·  click to %@", self.app.nowApp.length ? self.app.nowApp : @"Now playing", self.app.isPlaying ? @"pause" : @"play"];
        case CTBVolume: return self.hasVolume ? [NSString stringWithFormat:@"Volume %ld%%%@  ·  scroll to change", (long)lroundf((self.muted ? 0 : self.volume) * 100), self.muted ? @" (muted)" : @""] : @"Volume";
        case CTBWifi: return self.online ? @"Connected" : @"No network";
        case CTBBattery: return [NSString stringWithFormat:@"Battery %ld%%%@", (long)self.battery, self.charging ? @" · charging" : self.onPower ? @" · on power" : @""];
        case CTBClock: { NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterFullStyle; f.timeStyle = NSDateFormatterNoStyle; return [f stringFromDate:[NSDate date]]; }
        case CTBDesktop: return self.peeked.count ? @"Bring your windows back" : @"Show desktop";
    }
    return nil;
}

- (void)hoverItem:(CTBItem *)it {
    [self.tipTimer invalidate]; self.tipTimer = nil;
    if (!it || self.menuOpen) { [self.tip orderOut:nil]; return; }
    BOOL showing = self.tip.visible;
    __weak CTaskbar *ws = self;
    self.tipTimer = [NSTimer scheduledTimerWithTimeInterval:showing ? 0.05 : 0.45 repeats:NO block:^(NSTimer *t) { [ws showTipFor:it]; }];
}
- (void)showTipFor:(CTBItem *)it {
    NSString *text = [self tipFor:it]; if (!text.length || !self.bar.visible) return;
    if (!self.tip) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 100, 28) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        p.level = self.bar.level + 1; p.opaque = NO; p.backgroundColor = [NSColor clearColor]; p.hasShadow = YES; p.ignoresMouseEvents = YES;
        p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:p.contentView.bounds];
        fx.material = NSVisualEffectMaterialHUDWindow; fx.blendingMode = NSVisualEffectBlendingModeBehindWindow; fx.state = NSVisualEffectStateActive;
        fx.wantsLayer = YES; fx.layer.cornerRadius = 8; fx.layer.masksToBounds = YES; fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        p.contentView = fx;
        NSTextField *l = [NSTextField labelWithString:@""]; l.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        [fx addSubview:l]; self.tipLabel = l; self.tip = p;
    }
    self.tipLabel.stringValue = text; [self.tipLabel sizeToFit];
    CGFloat w = ceil(self.tipLabel.frame.size.width) + 22, h = 28;
    self.tipLabel.frame = NSMakeRect(11, floor((h - self.tipLabel.frame.size.height) / 2), w - 22, self.tipLabel.frame.size.height);
    NSRect bar = self.bar.frame;
    CGFloat cx = bar.origin.x + NSMidX(it.rect);
    CGFloat x = MIN(MAX(cx - w / 2, bar.origin.x), NSMaxX(bar) - w);
    [self.tip setFrame:NSMakeRect(round(x), gTop ? NSMinY(bar) - 6 - h : NSMaxY(bar) + 6, w, h) display:YES];
    [self.tip orderFrontRegardless];
}

#pragma mark Auto-hide

- (void)startAutoHide {
    if (self.globalMouse) return;
    __weak CTaskbar *ws = self;
    void (^check)(void) = ^{ [ws checkPointer]; };
    self.globalMouse = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^(NSEvent *e) { check(); }];
    self.localMouse = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *e) { check(); return e; }];
    if (!NSPointInRect([NSEvent mouseLocation], NSInsetRect([self barFrame], -12, -14))) [self slide:NO];
}
- (void)stopAutoHide {
    if (self.globalMouse) [NSEvent removeMonitor:self.globalMouse];
    if (self.localMouse) [NSEvent removeMonitor:self.localMouse];
    self.globalMouse = nil; self.localMouse = nil;
    [self.hideTimer invalidate]; self.hideTimer = nil;
}
- (void)checkPointer {
    if (self.fullScreenAway) return;                              // the edge belongs to the full-screen app
    NSPoint m = [NSEvent mouseLocation]; NSRect f = [self barFrame]; NSScreen *s = [self screen];
    NSRect v = s.visibleFrame;
    if (self.hiddenAway) {
        BOOL atEdge = gTop ? (m.y >= NSMaxY(v) - 2 && m.y <= NSMaxY(v) + 6) : m.y <= NSMinY(s.frame) + 2;
        if (atEdge && m.x >= NSMinX(f) && m.x <= NSMaxX(f)) [self slide:YES];
        return;
    }
    NSRect edgeStrip = gTop ? NSMakeRect(f.origin.x, NSMaxY(v), f.size.width, 1) : NSMakeRect(f.origin.x, s.frame.origin.y, f.size.width, 1);
    BOOL inside = NSPointInRect(m, NSInsetRect(NSUnionRect(f, edgeStrip), -12, -14));
    if (inside || self.menuOpen || self.calendar.shown) { [self.hideTimer invalidate]; self.hideTimer = nil; return; }
    if (!self.hideTimer) {
        __weak CTaskbar *ws = self;
        self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:NO block:^(NSTimer *t) { ws.hideTimer = nil; [ws slide:NO]; }];
    }
}
- (void)slide:(BOOL)show {
    NSRect f = [self barFrame];
    NSRect away = NSOffsetRect(f, 0, (gTop ? 1 : -1) * (f.size.height + gBarGap + 6));
    if (show && self.fullScreenAway) return;
    self.hiddenAway = !show;
    self.bar.ignoresMouseEvents = !show;                         // a hidden bar must never swallow clicks at the screen edge
    if (show) { [self.bar setFrame:away display:NO]; [self.bar orderFrontRegardless]; }
    else [self.tip orderOut:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = show ? 0.18 : 0.22;
        c.timingFunction = [CAMediaTimingFunction functionWithName:show ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseIn];
        [self.bar.animator setFrame:show ? f : away display:YES];
        self.bar.animator.alphaValue = show ? 1 : 0;
    } completionHandler:nil];
}

#pragma mark Snapshots

- (void)useSampleApps:(NSArray<NSString *> *)paths running:(NSArray<NSString *> *)running active:(NSString *)active {
    self.sampleApps = paths; self.sampleRunningApps = running; self.sampleActiveApp = active;
}
- (NSView *)snapshotView {
    [self loadMetrics];
    [self build];
    [self applyMask];
    [self.bar setFrame:NSMakeRect(0, 0, 1180, gBarH) display:NO];
    [self refreshStatus:YES];
    [self rebuild];
    return self.bar.contentView;
}

@end
