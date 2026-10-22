// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Five things beyond a search box:
//   Timed suggestions — usage is remembered by hour and by the app you came from, so Home leads with what fits now.
//   Hold-to-peek      — hold the shortcut for a glance (time, next event, music, battery, last copy); let go and it's gone.
//   Shelf             — drag anything while Centre's drop zone shows; it waits on Home until you paste it or drag it out.
//   Window sessions   — "save session Study" remembers which apps are open and where; typing "Study" puts it all back.
//   Preview           — rest on a file or a clipboard entry and see it beside the panel.
#import "App.h"
#import <dlfcn.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

// EventKit and Quick Look are loaded at run time (dlopen), so the build needs no extra frameworks.
@interface NSObject (CentreEventKit)
+ (NSInteger)authorizationStatusForEntityType:(NSUInteger)type;
- (void)requestFullAccessToEventsWithCompletion:(void (^)(BOOL granted, NSError *error))done;
- (void)requestAccessToEntityType:(NSUInteger)type completion:(void (^)(BOOL granted, NSError *error))done;
- (id)predicateForEventsWithStartDate:(NSDate *)start endDate:(NSDate *)end calendars:(NSArray *)calendars;
- (NSArray *)eventsMatchingPredicate:(id)predicate;
@end
@interface NSView (CentreQuickLook)
- (instancetype)initWithFrame:(NSRect)frame style:(NSUInteger)style;
@end

#pragma mark - Shared bits

static NSImage *roundedMask(CGFloat r) {
    NSImage *m = [NSImage imageWithSize:NSMakeSize(r * 2 + 2, r * 2 + 2) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] set]; [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:r yRadius:r] fill]; return YES; }];
    m.capInsets = NSEdgeInsetsMake(r, r, r, r); m.resizingMode = NSImageResizingModeStretch;
    return m;
}
// A borderless glass panel that never takes focus (so Centre's own panel stays key).
static NSPanel *glassPanel(NSRect frame, CGFloat radius) {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    p.level = NSPopUpMenuWindowLevel; p.opaque = NO; p.backgroundColor = [NSColor clearColor]; p.hasShadow = YES;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    p.hidesOnDeactivate = NO; p.releasedWhenClosed = NO; p.animationBehavior = NSWindowAnimationBehaviorNone;
    NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    fx.material = NSVisualEffectMaterialHUDWindow; fx.blendingMode = NSVisualEffectBlendingModeBehindWindow; fx.state = NSVisualEffectStateActive;
    fx.maskImage = roundedMask(radius); fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView *tint = [[NSView alloc] initWithFrame:fx.bounds]; tint.wantsLayer = YES;                 // obsidian glass, like the panel
    tint.layer.backgroundColor = cObsidian().CGColor; tint.layer.cornerRadius = radius;
    tint.layer.borderWidth = 1; tint.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.09].CGColor;
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; tint.identifier = @"tint"; [fx addSubview:tint];
    p.contentView = fx;
    return p;
}
static NSTextField *label(NSString *s, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *l = [NSTextField labelWithString:s ?: @""];
    l.font = [NSFont systemFontOfSize:size weight:w]; l.textColor = c; l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}
static NSArray *axStandardWindows(pid_t pid) {             // AXUIElementRefs (bridged), front to back
    NSMutableArray *out = [NSMutableArray new];
    AXUIElementRef ae = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(ae, 0.25);
    CFTypeRef wins = NULL;
    if (AXUIElementCopyAttributeValue(ae, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins && CFGetTypeID(wins) == CFArrayGetTypeID())
        for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)wins); i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)wins, i);
            CFTypeRef sub = NULL; AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, &sub);
            BOOL standard = sub && CFEqual(sub, kAXStandardWindowSubrole); if (sub) CFRelease(sub);
            if (standard) [out addObject:(__bridge id)w];
        }
    if (wins) CFRelease(wins);
    CFRelease(ae);
    return out;
}
static NSString *axTitle(id win) {
    CFTypeRef t = NULL; AXUIElementCopyAttributeValue((__bridge AXUIElementRef)win, kAXTitleAttribute, &t);
    NSString *s = (t && CFGetTypeID(t) == CFStringGetTypeID()) ? [(__bridge NSString *)t copy] : @""; if (t) CFRelease(t);
    return s;
}
static BOOL axFlag(id win, CFStringRef attr) {
    CFTypeRef v = NULL; BOOL on = NO;
    if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)win, attr, &v) == kAXErrorSuccess && v) { on = CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v); CFRelease(v); }
    return on;
}
static CGRect axRect(id win) {
    CFTypeRef pv = NULL, sv = NULL; CGPoint p = CGPointZero; CGSize s = CGSizeZero;
    AXUIElementRef w = (__bridge AXUIElementRef)win;
    BOOL ok = AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &pv) == kAXErrorSuccess && pv && AXValueGetValue((AXValueRef)pv, kAXValueTypeCGPoint, &p);
    ok = ok && AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sv) == kAXErrorSuccess && sv && AXValueGetValue((AXValueRef)sv, kAXValueTypeCGSize, &s);
    if (pv) CFRelease(pv);
    if (sv) CFRelease(sv);
    return ok ? CGRectMake(p.x, p.y, s.width, s.height) : CGRectNull;
}
static void axSetRect(id win, CGRect r) {
    AXUIElementRef w = (__bridge AXUIElementRef)win;
    if (axFlag(win, kAXMinimizedAttribute)) AXUIElementSetAttributeValue(w, kAXMinimizedAttribute, kCFBooleanFalse);
    CGPoint p = r.origin; CGSize s = r.size;
    AXValueRef pv = AXValueCreate(kAXValueTypeCGPoint, &p), sv = AXValueCreate(kAXValueTypeCGSize, &s);
    AXUIElementSetAttributeValue(w, kAXPositionAttribute, pv);
    AXUIElementSetAttributeValue(w, kAXSizeAttribute, sv);
    AXUIElementSetAttributeValue(w, kAXPositionAttribute, pv);             // again: a move can be clamped until the size fits
    CFRelease(pv); CFRelease(sv);
}

#pragma mark - Shelf drop zone

@interface CShelfDrop : NSView
@property (nonatomic, weak) CApp *app;
@property (nonatomic) BOOL hot;
@end
@implementation CShelfDrop
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f]))
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL, NSPasteboardTypeString, NSPasteboardTypeTIFF, NSPasteboardTypePNG]];
    return self;
}
- (void)drawRect:(NSRect)r {
    NSRect b = NSInsetRect(self.bounds, 6, 6);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:12 yRadius:12];
    p.lineWidth = 1.5; CGFloat dash[2] = {5, 4}; [p setLineDash:dash count:2 phase:0];
    [(self.hot ? cAccent() : [[NSColor labelColor] colorWithAlphaComponent:0.35]) setStroke]; [p stroke];
    if (self.hot) { [[cAccent() colorWithAlphaComponent:0.12] setFill]; [p fill]; }
    NSImage *ic = tintedSymbol(@"tray.and.arrow.down.fill", 15, self.hot ? cAccent() : [NSColor labelColor]);
    NSString *t = self.hot ? @"Let go to keep it" : @"Drop on Centre's shelf";
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor labelColor]};
    NSSize ts = [t sizeWithAttributes:a]; CGFloat w = ic.size.width + 8 + ts.width, x = NSMidX(b) - w / 2;
    [ic drawInRect:NSMakeRect(x, NSMidY(b) - ic.size.height / 2, ic.size.width, ic.size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [t drawAtPoint:NSMakePoint(x + ic.size.width + 8, NSMidY(b) - ts.height / 2) withAttributes:a];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { self.hot = YES; [self setNeedsDisplay:YES]; return NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)s { self.hot = NO; [self setNeedsDisplay:YES]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s {
    self.hot = NO; [self setNeedsDisplay:YES];
    return [self.app addToShelfFrom:s.draggingPasteboard] != nil;
}
@end

@implementation CApp (Glance)

#pragma mark - Timed suggestions

// recordUse (App.m) keeps a 24-hour histogram and the apps you were in; this reads it back.
- (double)timelyScore:(NSString *)key {
    NSDictionary *e = self.usage[key]; if (![e isKindOfClass:[NSDictionary class]]) return 0;
    double s = 0;
    NSArray *h = e[@"h"];
    if ([h isKindOfClass:[NSArray class]] && h.count == 24) {
        NSInteger hr = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
        s = [h[hr] doubleValue] + 0.5 * ([h[(hr + 23) % 24] doubleValue] + [h[(hr + 1) % 24] doubleValue]);
    }
    NSDictionary *apps = e[@"apps"];
    if (self.contextBundleID && [apps isKindOfClass:[NSDictionary class]]) s += 0.75 * [apps[self.contextBundleID] doubleValue];
    return s;
}

#pragma mark - Hold-to-peek

// A tap opens Centre as always (it acts on release, a fraction of a second later); holding shows the glance.
- (void)hotKeyPressed {
    if (self.hotKeyHeld && (self.holdTimer || self.peekShowing)) return;    // key repeat
    self.hotKeyHeld = YES;
    if (self.panel.visible || [self.config[@"holdToPeek"] isEqual:@NO]) { [self toggle]; return; }
    __weak CApp *ws = self;
    self.holdTimer = [NSTimer timerWithTimeInterval:0.28 repeats:NO block:^(NSTimer *t) {
        ws.holdTimer = nil; if (ws.hotKeyHeld) [ws showPeek]; }];
    [[NSRunLoop mainRunLoop] addTimer:self.holdTimer forMode:NSRunLoopCommonModes];
}
- (void)hotKeyReleased {
    self.hotKeyHeld = NO;
    if (self.peekShowing) { [self hidePeek]; return; }
    if (self.holdTimer) { [self.holdTimer invalidate]; self.holdTimer = nil; [self toggle]; }
}

- (NSArray<NSArray *> *)peekRows {                           // @[symbol, title, detail]
    NSMutableArray *rows = [NSMutableArray new];
    // Next event (EventKit, asked for once)
    NSArray *ev = [self nextEvent];
    if (ev) [rows addObject:ev];
    // Music
    if (self.hasNow && self.nowTitle.length) {
        NSString *who = self.nowArtist.length ? self.nowArtist : (self.nowApp ?: @"");
        [rows addObject:@[self.isPlaying ? @"play.circle.fill" : @"pause.circle.fill", self.nowTitle,
                          [NSString stringWithFormat:@"%@%@", who, self.isPlaying ? @"" : (who.length ? @"  ·  paused" : @"Paused")]]];
    }
    // Timers
    for (NSDictionary *t in self.timers) {
        NSDate *end = [t[@"end"] isKindOfClass:[NSDate class]] ? t[@"end"] : nil; if (!end) continue;
        NSTimeInterval left = MAX(0, end.timeIntervalSinceNow);
        [rows addObject:@[@"timer", [t[@"label"] description] ?: @"Timer", [NSString stringWithFormat:@"%@ left", fmtTime(left)]]];
    }
    // Battery
    CFTypeRef info = IOPSCopyPowerSourcesInfo(); CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    if (list && CFArrayGetCount(list) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, 0));
        if ([d[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) {
            NSInteger pct = [d[@kIOPSCurrentCapacityKey] integerValue] * 100 / MAX([d[@kIOPSMaxCapacityKey] integerValue], 1);
            BOOL chg = [d[@kIOPSIsChargingKey] boolValue], ac = [d[@kIOPSPowerSourceStateKey] isEqual:@kIOPSACPowerValue];
            NSInteger mins = [d[@kIOPSTimeToEmptyKey] integerValue];
            NSString *detail = chg ? @"Charging" : ac ? @"On power" : mins > 0 ? [NSString stringWithFormat:@"About %ld:%02ld left", (long)mins / 60, (long)mins % 60] : @"On battery";
            NSString *sym = chg ? @"battery.100.bolt" : pct > 80 ? @"battery.100" : pct > 55 ? @"battery.75" : pct > 30 ? @"battery.50" : pct > 12 ? @"battery.25" : @"battery.0";
            [rows addObject:@[sym, [NSString stringWithFormat:@"%ld%%", (long)pct], detail]];
        }
    }
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    // Last copied
    if (self.clips.count) {
        NSString *c = [[self.clips.firstObject stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (c.length > 80) c = [[c substringToIndex:[c rangeOfComposedCharacterSequenceAtIndex:80].location] stringByAppendingString:@"…"];
        [rows addObject:@[@"doc.on.clipboard", c, @"Last copied"]];
    }
    if (self.shelf.count) [rows addObject:@[@"tray.full", [NSString stringWithFormat:@"%lu on your shelf", (unsigned long)self.shelf.count], @"Open Centre to use them"]];
    return rows;
}

- (NSArray *)nextEvent {
    if ([self.config[@"peekCalendar"] isEqual:@NO] || self.snapshotDir) return nil;   // snapshots never touch your calendar
    static Class store; static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/Frameworks/EventKit.framework/EventKit", RTLD_LAZY); store = NSClassFromString(@"EKEventStore"); });
    if (!store) return nil;
    NSInteger st = [store authorizationStatusForEntityType:0];               // 0 events
    if (st == 0) {                                                            // not asked yet
        if (!self.calendarAsked) {
            self.calendarAsked = YES;
            id s = [store new]; self.calendarStore = s;
            void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {};
            if ([s respondsToSelector:@selector(requestFullAccessToEventsWithCompletion:)]) [s requestFullAccessToEventsWithCompletion:done];
            else [s requestAccessToEntityType:0 completion:done];
        }
        return @[@"calendar", @"Calendar", @"Allow access to see your next event"];
    }
    if (st != 3) return nil;                                                  // denied or write-only: say nothing
    if (!self.calendarStore) self.calendarStore = [store new];
    NSDate *now = [NSDate date];
    id pred = [self.calendarStore predicateForEventsWithStartDate:[now dateByAddingTimeInterval:-6 * 3600] endDate:[now dateByAddingTimeInterval:36 * 3600] calendars:nil];
    NSArray *evs = pred ? [self.calendarStore eventsMatchingPredicate:pred] : @[];
    id next = nil; NSDate *nextStart = nil;
    for (id e in evs) {
        if ([[e valueForKey:@"allDay"] boolValue]) continue;
        NSDate *s = [e valueForKey:@"startDate"], *en = [e valueForKey:@"endDate"];
        if (![s isKindOfClass:[NSDate class]] || ![en isKindOfClass:[NSDate class]] || [en compare:now] != NSOrderedDescending) continue;
        if (!nextStart || [s compare:nextStart] == NSOrderedAscending) { next = e; nextStart = s; }
    }
    if (!next) return @[@"calendar", @"Nothing else today", @"Your calendar is clear"];
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale autoupdatingCurrentLocale];
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:f.locale];
    NSTimeInterval until = nextStart.timeIntervalSinceNow;
    NSString *when = until <= 0 ? @"Now" : until < 3600 ? [NSString stringWithFormat:@"In %ld min", (long)ceil(until / 60)]
                   : [NSString stringWithFormat:@"%@%@", [[NSCalendar currentCalendar] isDateInToday:nextStart] ? @"" : @"Tomorrow ", [f stringFromDate:nextStart]];
    NSString *title = [[next valueForKey:@"title"] description] ?: @"Event";
    NSString *where = [[next valueForKey:@"location"] isKindOfClass:[NSString class]] ? [next valueForKey:@"location"] : @"";
    return @[@"calendar", title, where.length ? [NSString stringWithFormat:@"%@  ·  %@", when, where] : when];
}

- (void)showPeek {
    if (self.peekShowing) return;
    self.peekShowing = YES;
    NSArray *rows = [self peekRows];
    CGFloat W = 440, rowH = 46, top = 96, H = top + rows.count * rowH + (rows.count ? 14 : 0);
    NSPoint m = [NSEvent mouseLocation]; NSScreen *scr = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(m, s.frame, NO)) scr = s;
    NSRect v = usableFrame(scr);
    NSRect fr = NSMakeRect(round(NSMidX(v) - W / 2), round(NSMidY(v) - H / 2), W, H);
    if (!self.peekPanel) self.peekPanel = glassPanel(fr, 20);
    NSPanel *p = self.peekPanel; [p setFrame:fr display:NO];
    p.ignoresMouseEvents = YES;
    NSView *c = p.contentView; for (NSView *s in [c.subviews copy]) if (![s.identifier isEqualToString:@"tint"]) [s removeFromSuperview];
    // Time and date
    NSDateFormatter *tf = [NSDateFormatter new]; tf.locale = [NSLocale autoupdatingCurrentLocale];
    tf.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:tf.locale];
    NSDateFormatter *df = [NSDateFormatter new]; df.locale = tf.locale;
    df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEEdMMMM" options:0 locale:df.locale];
    NSTextField *time = label([[tf stringFromDate:[NSDate date]] stringByReplacingOccurrencesOfString:@" " withString:@" "], 40, NSFontWeightLight, [NSColor labelColor]);
    time.font = [NSFont monospacedDigitSystemFontOfSize:40 weight:NSFontWeightLight];
    time.frame = NSMakeRect(24, H - 64, W - 48, 48); [c addSubview:time];
    NSTextField *date = label([df stringFromDate:[NSDate date]], 13, NSFontWeightMedium, [NSColor secondaryLabelColor]);
    date.frame = NSMakeRect(26, H - 86, W - 52, 18); [c addSubview:date];
    CGFloat y = H - top - rowH;
    for (NSArray *r in rows) {
        NSImageView *iv = [NSImageView imageViewWithImage:tintedSymbol(r[0], 15, [NSColor secondaryLabelColor]) ?: [NSImage new]];
        iv.frame = NSMakeRect(24, y + 12, 22, 22); [c addSubview:iv];
        NSTextField *t = label(r[1], 13.5, NSFontWeightSemibold, [NSColor labelColor]); t.frame = NSMakeRect(58, y + 22, W - 82, 18); [c addSubview:t];
        NSTextField *d = label(r[2], 12, NSFontWeightRegular, [NSColor secondaryLabelColor]); d.frame = NSMakeRect(58, y + 5, W - 82, 16); [c addSubview:d];
        y -= rowH;
    }
    p.alphaValue = 0; [p orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.12; p.animator.alphaValue = 1; } completionHandler:nil];
    // If the key-up never arrives (focus changes mid-hold), let go of the modifiers and it still goes.
    __weak CApp *ws = self;
    [self.peekWatch invalidate];
    self.peekWatch = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        NSEventModifierFlags f = [NSEvent modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
        if (!f) { ws.hotKeyHeld = NO; [ws hidePeek]; }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.peekWatch forMode:NSRunLoopCommonModes];
}
- (void)hidePeek {
    [self.peekWatch invalidate]; self.peekWatch = nil;
    if (!self.peekShowing) return;
    self.peekShowing = NO;
    NSPanel *p = self.peekPanel;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.1; p.animator.alphaValue = 0; }
                        completionHandler:^{ if (!self.peekShowing) [p orderOut:nil]; }];
}

#pragma mark - Shelf

- (NSString *)shelfPath { return [supportDir() stringByAppendingPathComponent:@"shelf.json"]; }
- (void)loadShelf {
    NSData *d = [NSData dataWithContentsOfFile:[self shelfPath]];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    self.shelf = [NSMutableArray new];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([o isKindOfClass:[NSArray class]]) for (NSDictionary *e in o) {
        if (![e isKindOfClass:[NSDictionary class]] || ![e[@"value"] isKindOfClass:[NSString class]]) continue;
        if ([e[@"type"] isEqual:@"file"] && ![fm fileExistsAtPath:e[@"value"]]) continue;   // moved or deleted since
        [self.shelf addObject:e];
    }
}
- (void)saveShelf {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.shelf ?: @[] options:0 error:nil];
    [d writeToFile:[self shelfPath] atomically:YES];
}
- (BOOL)shelfHas:(NSString *)type value:(NSString *)v {
    for (NSDictionary *e in self.shelf) if ([e[@"type"] isEqual:type] && [e[@"value"] isEqual:v]) return YES;
    return NO;
}
- (void)shelfAdd:(NSString *)type value:(NSString *)v {
    if (!v.length || [self shelfHas:type value:v]) return;
    [self.shelf insertObject:@{@"id": [NSUUID UUID].UUIDString, @"type": type, @"value": v, @"added": @([NSDate date].timeIntervalSince1970)} atIndex:0];
    while (self.shelf.count > 24) [self.shelf removeLastObject];
}
// Files, links, text or images dropped on the zone (or anything else that hands over a pasteboard).
- (id)addToShelfFrom:(NSPasteboard *)pb {
    if (!self.shelf) [self loadShelf];
    NSUInteger before = self.shelf.count;
    NSArray *files = [pb readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *u in files) [self shelfAdd:@"file" value:u.path];
    if (!files.count) {
        NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:nil];
        NSString *text = [pb stringForType:NSPasteboardTypeString];
        NSData *img = [pb dataForType:NSPasteboardTypePNG] ?: [pb dataForType:NSPasteboardTypeTIFF];
        if (urls.count && [[urls.firstObject scheme] hasPrefix:@"http"]) [self shelfAdd:@"url" value:[urls.firstObject absoluteString]];
        else if (text.length) [self shelfAdd:[text hasPrefix:@"http"] && ![text containsString:@" "] ? @"url" : @"text" value:text];
        else if (img) {                                                       // a dragged image with no file behind it
            NSString *dir = [supportDir() stringByAppendingPathComponent:@"Shelf"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:img];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
            NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"Image %@.png", [f stringFromDate:[NSDate date]]]];
            if ([png writeToFile:path atomically:YES]) [self shelfAdd:@"file" value:path];
        }
    }
    if (self.shelf.count == before) return nil;
    [self saveShelf];
    NSUInteger n = self.shelf.count - before;
    showHUD(n == 1 ? @"On your shelf" : [NSString stringWithFormat:@"%lu on your shelf", (unsigned long)n], @"tray.and.arrow.down.fill");
    if (self.panel.visible && !self.field.stringValue.length) [self refresh];
    return @YES;
}
- (void)shelfRemove:(NSString *)sid {
    NSUInteger i = [self.shelf indexOfObjectPassingTest:^BOOL(NSDictionary *e, NSUInteger idx, BOOL *stop) { return [e[@"id"] isEqual:sid]; }];
    if (i == NSNotFound) return;
    [self.shelf removeObjectAtIndex:i]; [self saveShelf];
    if (self.panel.visible) {
        NSInteger keep = self.selected; [self refresh];
        if (self.gridMode && keep < (NSInteger)self.items.count) [self homeSelect:keep];
    }
}
// Paste a shelf entry into the app you came from (files paste as files), then it leaves the shelf.
- (void)useShelfEntry:(NSDictionary *)e {
    NSString *sid = e[@"id"];
    if (![e[@"type"] isEqual:@"file"]) { [self deliverText:e[@"value"] paste:YES]; [self shelfRemove:sid]; return; }
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSMutableArray *saved = [NSMutableArray new];
    for (NSPasteboardItem *it in pb.pasteboardItems) { NSPasteboardItem *c = [NSPasteboardItem new]; for (NSString *t in it.types) { NSData *d = [it dataForType:t]; if (d) [c setData:d forType:t]; } [saved addObject:c]; }
    [pb clearContents]; [pb writeObjects:@[[NSURL fileURLWithPath:e[@"value"]]]];
    [self shelfRemove:sid];
    if (!AXIsProcessTrusted() || !self.previousApp || self.previousApp.terminated) { showHUD(@"Copied · paste with ⌘V", @"doc.on.clipboard.fill"); return; }
    NSInteger mine = pb.changeCount;
    [self.previousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        simulatePaste();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSPasteboard *p = [NSPasteboard generalPasteboard];
            if (p.changeCount == mine && saved.count) { [p clearContents]; [p writeObjects:saved]; }   // your clipboard comes back
        });
    });
}
- (NSArray<CItem *> *)shelfItems {
    if (!self.shelf) [self loadShelf];
    NSMutableArray *out = [NSMutableArray new];
    __weak CApp *ws = self;
    for (NSDictionary *e in self.shelf) {
        NSString *type = e[@"type"], *v = e[@"value"];
        CItem *i = [CItem new]; i.kind = @"Shelf"; i.shelfID = e[@"id"];
        i.detail = shortAgo([e[@"added"] doubleValue]);
        if ([type isEqual:@"file"]) {
            i.title = v.lastPathComponent; i.subtitle = [v.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath];
            i.path = v; i.dragObject = [NSURL fileURLWithPath:v];
        } else {
            NSString *one = [[v stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (one.length > 80) one = [[one substringToIndex:[one rangeOfComposedCharacterSequenceAtIndex:80].location] stringByAppendingString:@"…"];
            i.title = one; i.symbol = [type isEqual:@"url"] ? @"link" : @"text.quote";
            id drag = v; if ([type isEqual:@"url"] && [NSURL URLWithString:v]) drag = [NSURL URLWithString:v];
            i.dragObject = drag;
            i.previewText = [type isEqual:@"url"] ? nil : v;
        }
        i.action = ^{ [ws useShelfEntry:e]; };
        i.altAction = ^{ [ws shelfRemove:e[@"id"]]; }; i.altHint = @"⌘↩ Remove";
        i.verb = [type isEqual:@"file"] ? @"Paste File" : @"Paste";
        [out addObject:i];
    }
    return out;
}

// While you drag something anywhere, a drop zone appears under the menu bar.
- (void)startShelfWatch {
    if (self.dragMoveMonitor) return;
    __weak CApp *ws = self;
    NSPasteboard *dpb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    self.dragPBCount = dpb.changeCount;
    self.dragDownMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *e) { ws.dragPBCount = dpb.changeCount; }];
    self.dragMoveMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged handler:^(NSEvent *e) {
        if (ws.dragActive || dpb.changeCount == ws.dragPBCount || [ws.config[@"shelfDropZone"] isEqual:@NO]) return;   // a real drag puts something on the drag pasteboard
        ws.dragActive = YES; [ws showDropZone];
    }];
    self.dragUpMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp handler:^(NSEvent *e) {
        ws.dragPBCount = dpb.changeCount;
        if (!ws.dragActive) return;
        ws.dragActive = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!ws.dragActive) [ws hideDropZone]; });
    }];
}
- (void)showDropZone {
    NSPoint m = [NSEvent mouseLocation]; NSScreen *scr = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(m, s.frame, NO)) scr = s;
    NSRect v = scr.visibleFrame;
    NSRect fr = NSMakeRect(round(NSMidX(v) - 140), NSMaxY(v) - 84, 280, 72);
    if (!self.dropZone) {
        self.dropZone = glassPanel(fr, 16);
        CShelfDrop *d = [[CShelfDrop alloc] initWithFrame:self.dropZone.contentView.bounds]; d.app = self;
        d.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.dropZone.contentView addSubview:d];
    }
    [self.dropZone setFrame:fr display:NO];
    self.dropZone.alphaValue = 0; [self.dropZone orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.15; self.dropZone.animator.alphaValue = 1; } completionHandler:nil];
}
- (void)hideDropZone {
    NSPanel *z = self.dropZone; if (!z.visible) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.15; z.animator.alphaValue = 0; }
                        completionHandler:^{ if (!self.dragActive) [z orderOut:nil]; }];
}

#pragma mark - Window sessions

- (NSDictionary *)sessions { return [self.config[@"sessions"] isKindOfClass:[NSDictionary class]] ? self.config[@"sessions"] : @{}; }
- (void)saveSession:(NSString *)name {
    if (!AXIsProcessTrusted()) { [self grantAX]; return; }
    // Front-to-back app order from the window server, so the app you were in comes back in front.
    NSMutableArray<NSNumber *> *order = [NSMutableArray new];
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *w in list) if ([w[(id)kCGWindowLayer] integerValue] == 0) { NSNumber *p = w[(id)kCGWindowOwnerPID]; if (p && ![order containsObject:p]) [order addObject:p]; }
    NSMutableArray *apps = [NSMutableArray new];
    NSArray *running = [[NSWorkspace sharedWorkspace].runningApplications filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSRunningApplication *r, NSDictionary *b) {
        return r.activationPolicy == NSApplicationActivationPolicyRegular && !r.hidden && r != NSRunningApplication.currentApplication && r.bundleIdentifier && r.bundleURL; }]];
    running = [running sortedArrayUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        NSUInteger x = [order indexOfObject:@(a.processIdentifier)], y = [order indexOfObject:@(b.processIdentifier)];
        return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame; }];
    NSUInteger winCount = 0;
    for (NSRunningApplication *r in running) {
        NSMutableArray *wins = [NSMutableArray new];
        for (id w in axStandardWindows(r.processIdentifier)) {
            if (axFlag(w, kAXMinimizedAttribute) || axFlag(w, CFSTR("AXFullScreen"))) continue;
            CGRect f = axRect(w); if (CGRectIsNull(f)) continue;
            [wins addObject:@{@"title": axTitle(w), @"x": @(f.origin.x), @"y": @(f.origin.y), @"w": @(f.size.width), @"h": @(f.size.height)}];
        }
        if (!wins.count) continue;                                            // a running app with nothing open isn't part of the layout
        winCount += wins.count;
        [apps addObject:@{@"bundle": r.bundleIdentifier, @"path": r.bundleURL.path, @"name": r.localizedName ?: @"", @"windows": wins}];
    }
    if (!apps.count) { showHUD(@"No open windows to save", @"exclamationmark.circle.fill"); return; }
    NSMutableDictionary *c = [self mutableConfig];
    NSMutableDictionary *s = [[self sessions] mutableCopy]; s[name] = apps; c[@"sessions"] = s;
    [self writeConfig:c];
    showHUD([NSString stringWithFormat:@"Saved “%@” · %lu apps, %lu windows", name, (unsigned long)apps.count, (unsigned long)winCount], @"rectangle.3.group.fill");
}
- (void)deleteSession:(NSString *)name {
    NSMutableDictionary *c = [self mutableConfig];
    NSMutableDictionary *s = [[self sessions] mutableCopy]; [s removeObjectForKey:name]; c[@"sessions"] = s;
    [self writeConfig:c];
    showHUD([NSString stringWithFormat:@"Deleted “%@”", name], @"trash");
}
- (void)restoreSession:(NSString *)name {
    NSArray *apps = [self sessions][name]; if (![apps isKindOfClass:[NSArray class]] || !apps.count) return;
    if (!AXIsProcessTrusted()) { [self grantAX]; return; }
    NSMutableSet *bundles = [NSMutableSet new];
    for (NSDictionary *a in apps) {
        if (![a isKindOfClass:[NSDictionary class]] || ![a[@"bundle"] isKindOfClass:[NSString class]]) continue;
        [bundles addObject:a[@"bundle"]];
        NSRunningApplication *r = [NSRunningApplication runningApplicationsWithBundleIdentifier:a[@"bundle"]].firstObject;
        if (r) { if (r.hidden) [r unhide]; continue; }
        if ([a[@"path"] isKindOfClass:[NSString class]]) {
            NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration]; cfg.activates = NO;
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:a[@"path"]] configuration:cfg completionHandler:nil];
        }
    }
    // Everything else steps aside (hidden, still running).
    for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
        if (r.activationPolicy == NSApplicationActivationPolicyRegular && r != NSRunningApplication.currentApplication && !r.hidden
            && r.bundleIdentifier && ![bundles containsObject:r.bundleIdentifier] && ![r.bundleIdentifier isEqualToString:@"com.apple.finder"]) [r hide];
    showHUD([NSString stringWithFormat:@"Restoring “%@”…", name], @"rectangle.3.group.fill");
    [self placeSession:apps attempt:0 done:[NSMutableSet new]];
}
// Apps that are still launching get a few seconds to open their windows; each app is arranged once it has them.
- (void)placeSession:(NSArray *)apps attempt:(NSInteger)n done:(NSMutableSet *)done {
    BOOL waiting = NO;
    for (NSDictionary *a in apps) {
        NSString *bid = a[@"bundle"]; if (![bid isKindOfClass:[NSString class]] || [done containsObject:bid]) continue;
        NSRunningApplication *r = [NSRunningApplication runningApplicationsWithBundleIdentifier:bid].firstObject;
        NSArray *saved = [a[@"windows"] isKindOfClass:[NSArray class]] ? a[@"windows"] : @[];
        NSArray *now = r ? axStandardWindows(r.processIdentifier) : @[];
        if ((!r || now.count < saved.count) && n < 16) { waiting = YES; if (!r || !now.count) continue; }
        NSMutableArray *spare = [now mutableCopy];
        for (NSDictionary *w in saved) {
            id match = nil;
            for (id cur in spare) if ([axTitle(cur) isEqualToString:w[@"title"] ?: @""]) { match = cur; break; }
            if (!match) match = spare.firstObject;
            if (!match) break;
            [spare removeObject:match];
            axSetRect(match, CGRectMake([w[@"x"] doubleValue], [w[@"y"] doubleValue], [w[@"w"] doubleValue], [w[@"h"] doubleValue]));
        }
        if (now.count >= saved.count || n >= 16) [done addObject:bid];
    }
    if (waiting && n < 16) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self placeSession:apps attempt:n + 1 done:done]; });
        return;
    }
    NSString *front = [apps.firstObject isKindOfClass:[NSDictionary class]] ? apps.firstObject[@"bundle"] : nil;   // saved front to back
    if (front) [[NSRunningApplication runningApplicationsWithBundleIdentifier:front].firstObject activateWithOptions:0];
}

#pragma mark - Search: sessions and shelf

- (NSArray<CItem *> *)glanceItemsFor:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    __weak CApp *ws = self;
    NSString *lower = q.lowercaseString;
    if ([lower hasPrefix:@"save session"]) {                              // save session Study
        NSString *name = [[q substringFromIndex:12] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        CItem *i;
        if (name.length) {
            BOOL exists = [self sessions][name] != nil;
            i = mk([NSString stringWithFormat:@"Save Window Session “%@”", name], exists ? @"Replaces the saved layout with what's open now" : @"Remembers every open app and where its windows are",
                   @"Session", @"rectangle.3.group", ^{ [ws saveSession:name]; });
            i.verb = @"Save";
        } else {
            i = mk(@"Type a name for this layout", @"save session Study", @"Session", @"rectangle.3.group", nil);
        }
        i.score = 3000; [r addObject:i];
        return r;
    }
    if (q.length >= 3) {
        double s = fuzzyScore(q, @"Save Window Session");
        if (s >= 0) {
            CItem *i = mk(@"Save Window Session…", @"Name it, then restore it any time by typing that name", @"Session", @"rectangle.3.group", ^{ [ws askInputFor:@"save session"]; });
            i.keepsPanel = YES; i.verb = @"Name It"; i.score = s - 6; [r addObject:i];
        }
    }
    BOOL listAll = q.length >= 4 && [@"sessions" hasPrefix:lower];
    NSDictionary *sessions = [self sessions];
    for (NSString *name in sessions) {
        double s = listAll ? 40 : fuzzyScore(q, name);
        if (s < 0) continue;
        NSArray *apps = [sessions[name] isKindOfClass:[NSArray class]] ? sessions[name] : @[];
        NSMutableArray *names = [NSMutableArray new]; for (NSDictionary *a in apps) if ([a[@"name"] length]) [names addObject:a[@"name"]];
        NSString *sub = names.count > 3 ? [NSString stringWithFormat:@"%@ and %lu more", [[names subarrayWithRange:NSMakeRange(0, 3)] componentsJoinedByString:@", "], (unsigned long)names.count - 3]
                                        : [names componentsJoinedByString:@", "];
        CItem *i = mk(name, sub, @"Session", @"rectangle.3.group", ^{ [ws restoreSession:name]; });
        i.altAction = ^{ [ws deleteSession:name]; }; i.altHint = @"⌘↩ Delete"; i.verb = @"Restore";
        i.score = s + 6; [r addObject:i];
    }
    if (q.length >= 3 && fuzzyScore(q, @"shelf") >= 0) {
        NSArray *items = [self shelfItems];
        NSInteger k = 0;
        for (CItem *i in items) { i.score = 60 - k++; [r addObject:i]; }
        if (items.count) {
            CItem *clear = mk(@"Clear Shelf", [NSString stringWithFormat:@"Removes %lu item%@", (unsigned long)items.count, items.count == 1 ? @"" : @"s"], @"Shelf", @"tray", ^{
                [ws.shelf removeAllObjects]; [ws saveShelf]; showHUD(@"Shelf cleared", @"tray"); });
            clear.score = 59 - k; [r addObject:clear];
        } else {
            CItem *empty = mk(@"Your shelf is empty", @"Drag anything and drop it on the zone that appears at the top", @"Shelf", @"tray", nil);
            empty.score = 40; [r addObject:empty];
        }
    }
    return r;
}

#pragma mark - Preview

- (void)startPreviewWatch {
    if (self.previewTimer) return;
    __weak CApp *ws = self;
    self.previewTimer = [NSTimer timerWithTimeInterval:0.12 repeats:YES block:^(NSTimer *t) { [ws updatePreview]; }];
    [[NSRunLoop mainRunLoop] addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
}
- (BOOL)previewFor:(CItem *)it url:(NSURL **)url text:(NSString **)text {
    if (!it) return NO;
    if (it.previewText.length) { *text = it.previewText; return YES; }
    if (it.path.length && [it.path hasPrefix:@"/"]) {
        BOOL dir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:it.path isDirectory:&dir] && !dir) { *url = [NSURL fileURLWithPath:it.path]; return YES; }
    }
    return NO;
}
- (void)updatePreview {
    if (!self.panel.visible || [self.config[@"previewFiles"] isEqual:@NO]) { if (self.previewPanel.visible) [self hidePreview]; return; }
    CItem *it = (self.selected >= 0 && self.selected < (NSInteger)self.items.count) ? self.items[self.selected] : nil;
    NSURL *url = nil; NSString *text = nil;
    if (![self previewFor:it url:&url text:&text]) { self.previewPending = nil; if (self.previewPanel.visible) [self hidePreview]; return; }
    if (it == self.previewedItem && self.previewPanel.visible) { [self placePreview]; return; }
    if (it != self.previewPending) { self.previewPending = it; self.previewPendingAt = [NSDate date]; return; }
    if (-[self.previewPendingAt timeIntervalSinceNow] < 0.18) return;          // rest on it a moment; arrowing past doesn't flash previews
    self.previewedItem = it;
    [self showPreviewURL:url text:text];
}
- (void)placePreview {
    NSRect pf = self.panel.frame; NSRect v = usableFrame(self.panel.screen ?: NSScreen.mainScreen);
    CGFloat H = MIN(MAX(pf.size.height, 320), v.size.height - 24);
    // The side with more room, narrowed to fit (down to 240); on a screen with room on neither side it overlaps the
    // panel's edge rather than leaving the screen.
    CGFloat right = NSMaxX(v) - 8 - (NSMaxX(pf) + 10), left = (NSMinX(pf) - 10) - (NSMinX(v) + 8);
    BOOL onRight = right >= left;
    CGFloat room = MAX(right, left), W = MIN(380, MAX(240, room));
    CGFloat x = onRight ? NSMaxX(pf) + 10 : NSMinX(pf) - 10 - W;
    x = MAX(NSMinX(v) + 8, MIN(x, NSMaxX(v) - 8 - W));
    CGFloat y = MAX(NSMinY(v) + 8, MIN(NSMaxY(pf) - H, NSMaxY(v) - 8 - H));
    NSRect fr = NSMakeRect(round(x), round(y), W, round(H));
    if (!NSEqualRects(fr, self.previewPanel.frame)) [self.previewPanel setFrame:fr display:YES];
}
- (void)showPreviewURL:(NSURL *)url text:(NSString *)text {
    if (!self.previewPanel) {
        self.previewPanel = glassPanel(NSMakeRect(0, 0, 380, 400), 18);
        self.previewPanel.level = self.panel.level;
    }
    NSView *c = self.previewPanel.contentView;
    [self placePreview];
    NSRect inner = NSInsetRect(c.bounds, 10, 10);
    self.previewTextScroll.hidden = YES; self.previewQL.hidden = YES;
    if (url) {
        static Class ql; static dispatch_once_t once;
        dispatch_once(&once, ^{ dlopen("/System/Library/Frameworks/Quartz.framework/Quartz", RTLD_LAZY); ql = NSClassFromString(@"QLPreviewView"); });
        if (!ql) return;
        if (!self.previewQL) {
            NSView *v = [[ql alloc] initWithFrame:inner style:1];                // compact: no Quick Look toolbar
            v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; v.wantsLayer = YES; v.layer.cornerRadius = 10; v.layer.masksToBounds = YES;
            [c addSubview:v]; self.previewQL = v;
        }
        self.previewQL.frame = inner; self.previewQL.hidden = NO;
        [self.previewQL setValue:url forKey:@"previewItem"];
    } else {
        if (!self.previewTextScroll) {
            NSScrollView *sv = [[NSScrollView alloc] initWithFrame:inner];
            sv.hasVerticalScroller = YES; sv.drawsBackground = NO; sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, inner.size.width, inner.size.height)];
            tv.editable = NO; tv.selectable = YES; tv.drawsBackground = NO; tv.textContainerInset = NSMakeSize(8, 10);
            tv.font = [NSFont systemFontOfSize:13]; tv.textColor = [NSColor labelColor];
            tv.autoresizingMask = NSViewWidthSizable; tv.verticallyResizable = YES; tv.textContainer.widthTracksTextView = YES;
            sv.documentView = tv;
            [c addSubview:sv]; self.previewTextScroll = sv;
        }
        self.previewTextScroll.frame = inner; self.previewTextScroll.hidden = NO;
        NSTextView *tv = self.previewTextScroll.documentView;
        tv.string = text.length > 20000 ? [[text substringToIndex:20000] stringByAppendingString:@"\n…"] : text;
        [tv scrollRangeToVisible:NSMakeRange(0, 0)];
    }
    if (!self.previewPanel.parentWindow) [self.panel addChildWindow:self.previewPanel ordered:NSWindowAbove];
    [self.previewPanel orderFront:nil];
}
- (void)hidePreview {
    self.previewedItem = nil;
    if (self.previewPanel.parentWindow) [self.previewPanel.parentWindow removeChildWindow:self.previewPanel];
    [self.previewPanel orderOut:nil];
}
@end
