// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"
#import "Settings.h"

@implementation CApp (Snapshots)

#pragma mark Design snapshots (offscreen; used to review the UI without touching the screen)
- (void)snapshotView:(NSView *)v name:(NSString *)name radius:(CGFloat)radius {
    [v layoutSubtreeIfNeeded]; [v displayIfNeeded];
    NSRect b = v.bounds;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:b];
    [v cacheDisplayInRect:b toBitmapImageRep:rep];
    const CGFloat pad = self.readmeMode ? 64 : 36;
    NSSize sz = NSMakeSize(b.size.width + pad * 2, b.size.height + pad * 2);
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(sz.width * 2) pixelsHigh:(NSInteger)(sz.height * 2)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    out.size = sz;
    BOOL dark = [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
    NSAppearance *was = [NSAppearance currentAppearance];
    [NSAppearance setCurrentAppearance:v.effectiveAppearance];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:out]];
    NSGradient *g = dark ? [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.16 green:0.19 blue:0.25 alpha:1] endingColor:[NSColor colorWithCalibratedRed:0.05 green:0.06 blue:0.08 alpha:1]]
                         : [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.74 green:0.80 blue:0.88 alpha:1] endingColor:[NSColor colorWithCalibratedRed:0.94 green:0.91 blue:0.87 alpha:1]];
    if (self.readmeMode)
        g = dark ? [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.11 green:0.20 blue:0.30 alpha:1] endingColor:[NSColor colorWithSRGBRed:0.03 green:0.05 blue:0.09 alpha:1]]
                 : [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.78 green:0.88 blue:0.96 alpha:1] endingColor:[NSColor colorWithSRGBRed:0.96 green:0.97 blue:0.99 alpha:1]];
    [g drawInRect:NSMakeRect(0, 0, sz.width, sz.height) angle:-60];
    NSRect dst = NSMakeRect(pad, pad, b.size.width, b.size.height);
    if (radius > 0) {   // the real panel floats with a system shadow; draw one so the render reads the same
        NSShadow *sh = [NSShadow new]; sh.shadowBlurRadius = 28; sh.shadowOffset = NSMakeSize(0, -10);
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:dark ? 0.55 : 0.20];
        [NSGraphicsContext saveGraphicsState]; [sh set];
        [(dark ? [NSColor colorWithSRGBRed:0.112 green:0.114 blue:0.126 alpha:1] : [NSColor colorWithSRGBRed:0.978 green:0.978 blue:0.982 alpha:1]) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:dst xRadius:radius yRadius:radius] fill];
        [NSGraphicsContext restoreGraphicsState];
    }
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:dst xRadius:radius yRadius:radius];
    if (radius <= 0) { [[NSColor windowBackgroundColor] setFill]; NSRectFill(dst); }
    [clip addClip];
    [rep drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [NSAppearance setCurrentAppearance:was];
    [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[self.snapshotDir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
- (void)readmeShots {
    NSImage *art = [NSImage imageWithSize:NSMakeSize(240, 240) flipped:NO drawingHandler:^BOOL(NSRect r) {   // abstract cover art
        [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.42 green:0.80 blue:0.98 alpha:1]
                                       endingColor:[NSColor colorWithSRGBRed:0.05 green:0.16 blue:0.32 alpha:1]] drawInRect:r angle:-65];
        [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.55] endingColor:[NSColor colorWithWhite:1 alpha:0]]
            drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(40, 70, 130, 130)] relativeCenterPosition:NSMakePoint(-0.2, 0.2)];
        return YES; }];
    for (NSString *mode in @[@"dark", @"light"]) {
        NSApp.appearance = [NSAppearance appearanceNamed:[mode isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        [self buildUI]; [self positionPanel];
        self.hasNow = YES; self.nowTitle = @"Midnight City"; self.nowArtist = @"M83"; self.nowApp = @"Music"; self.nowArt = art;
        self.nowDuration = 243; self.nowElapsed = 71; self.nowStamp = [NSDate date]; self.nowRate = 1; self.isPlaying = YES;
        self.field.stringValue = @""; [self refresh]; [self updateMediaView];
        [self snapshotView:self.panel.contentView name:[@"home-" stringByAppendingString:mode] radius:kRadius];
        self.hasNow = NO;
        if (![mode isEqualToString:@"dark"]) continue;
        NSArray *shots = @[@[@"window", @"commands"], @[@"pw 24", @"passwords"], @[@"clip ", @"clipboard"], @[@"128*0.15+12", @"calculator"]];
        for (NSArray *q in shots) {
            self.field.stringValue = q[0]; [self refresh]; [self stopFileSearch];
            [self snapshotView:self.panel.contentView name:q[1] radius:kRadius];
        }
    }
}
- (void)snapshotAll {
    if (self.readmeMode) { [self readmeShots]; return; }
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self buildUI]; [self positionPanel];
    self.field.stringValue = @"empty trash"; [self refresh]; [self stopFileSearch];
    for (CItem *c in self.items) if (c.confirm.length) { self.selected = (NSInteger)[self.items indexOfObject:c]; [self armItem:c]; break; }
    [self snapshotView:self.panel.contentView name:@"dark-18-confirm" radius:kRadius];
    self.field.stringValue = @"centre"; [self refresh]; [self stopFileSearch];
    [self snapshotView:self.panel.contentView name:@"dark-19-centre-ranked" radius:kRadius];
    [self snapshotView:prepareHUD(@"Password copied · clears in 90 s", @"key.fill").contentView name:@"dark-20-hud" radius:20];
    for (NSArray *q in @[@[@"define serendipity", @"dark-22-define"], @[@"5 km to mi", @"dark-23-units"], @[@"timer 10m tea", @"dark-24-timer"],
                         @[@"vol 40", @"dark-25-volume"], @[@"keep awake", @"dark-26-awake"], @[@"window third", @"dark-27-thirds"]]) {
        self.field.stringValue = q[0]; [self refresh]; [self stopFileSearch];
        [self snapshotView:self.panel.contentView name:q[1] radius:kRadius];
    }
    self.timers = [@[[@{@"end": [NSDate dateWithTimeIntervalSinceNow:462], @"label": @"Tea", @"total": @600} mutableCopy]] mutableCopy];
    self.field.stringValue = @""; [self refresh];
    [self snapshotView:self.panel.contentView name:@"dark-28-home-timer" radius:kRadius];
    self.timers = nil;
    // Context-aware home: text selected in another app, then arriving from a browser
    self.selectedText = @"The quick brown fox jumps over the lazy dog"; self.contextAppName = @"Notes"; self.contextBundleID = @"com.apple.Notes";
    self.field.stringValue = @""; [self refresh];
    [self snapshotView:self.panel.contentView name:@"dark-30-home-selection" radius:kRadius];
    self.field.stringValue = @"tx"; [self refresh]; [self stopFileSearch];
    [self snapshotView:self.panel.contentView name:@"dark-35-transform" radius:kRadius];
    self.field.stringValue = @"upper"; [self refresh]; [self stopFileSearch];
    [self snapshotView:self.panel.contentView name:@"dark-38-upper" radius:kRadius];
    self.selectedText = nil; self.contextAppName = @"Brave Browser"; self.contextBundleID = @"com.brave.Browser";
    self.field.stringValue = @""; [self refresh];
    [self snapshotView:self.panel.contentView name:@"dark-31-home-browser" radius:kRadius];
    self.contextAppName = nil; self.contextBundleID = nil;
    for (NSArray *q in @[@[@":hea", @"dark-32-emoji"], @[@"time in tokyo", @"dark-33-time"], @[@"3pm melbourne in london", @"dark-34-timeconv"],
                         @[@"info", @"dark-36-info"], @[@"w ", @"dark-37-windows"], @[@"snip", @"dark-39-snippets"]]) {
        self.field.stringValue = q[0]; [self refresh]; [self stopFileSearch];
        [self snapshotView:self.panel.contentView name:q[1] radius:kRadius];
    }
    CSettings *st = [[CSettings alloc] initWithApp:self]; [st useSampleData];
    st.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSArray *pg in @[@[@"Home", @"dark-40-set-home"], @[@"Commands", @"dark-41-set-commands"], @[@"Snippets", @"dark-42-set-snippets"], @[@"Shortcuts", @"dark-43-set-shortcuts"]]) {
        [st showPageNamed:pg[0]];
        [self snapshotView:st.window.contentView name:pg[1] radius:0];
    }
    NSArray *queries = @[@"", @"sa", @"window", @"12*7+3", @"pw 24", @"zzqx", @"clip ", @"kill ", @"play", @"centre"];
    NSArray *names = @[@"1-home", @"2-apps", @"3-commands", @"4-calc", @"5-password", @"6-nomatch", @"7-clip", @"8-kill", @"9-media", @"10-centre"];
    for (NSString *mode in @[@"dark", @"light"]) {
        NSAppearance *ap = [NSAppearance appearanceNamed:[mode isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        NSApp.appearance = ap;
        [self buildUI];
        [self positionPanel];
        for (NSUInteger i = 0; i < queries.count; i++) {
            self.field.stringValue = queries[i];
            [self refresh]; [self stopFileSearch];
            [self snapshotView:self.panel.contentView name:[NSString stringWithFormat:@"%@-%@", mode, names[i]] radius:kRadius];
        }
        self.field.stringValue = @"sa"; [self refresh]; [self stopFileSearch];
        self.cmdHeld = YES; [self reloadTable];
        [self snapshotView:self.panel.contentView name:[mode stringByAppendingString:@"-11-cmdheld"] radius:kRadius];
        self.cmdHeld = NO;
        [self hoverSelect:3];
        [self snapshotView:self.panel.contentView name:[mode stringByAppendingString:@"-13-hover-row"] radius:kRadius];
        self.field.stringValue = @""; [self refresh];
        [self homeMoveVertical:1]; [self homeMoveVertical:1]; [self homeMoveVertical:1];
        [self snapshotView:self.panel.contentView name:[mode stringByAppendingString:@"-15-home-nav"] radius:kRadius];
        self.hasNow = YES; self.nowTitle = @"Midnight City"; self.nowArtist = @"M83"; self.nowApp = @"Brave Browser";
        self.nowDuration = 243; self.nowElapsed = 71; self.nowStamp = [NSDate date]; self.nowRate = 1; self.isPlaying = YES;
        [self refresh]; [self updateMediaView];
        [self snapshotView:self.panel.contentView name:[mode stringByAppendingString:@"-16-home-media"] radius:kRadius];
        self.media.hoverBar = YES; [self.media setNeedsDisplay:YES];
        [self snapshotView:self.panel.contentView name:[mode stringByAppendingString:@"-17-media-hover"] radius:kRadius];
        self.media.hoverBar = NO; self.hasNow = NO;
        [self refresh];
        [self hoverSelect:2];
        [self snapshotView:self.panel.contentView name:[mode stringByAppendingString:@"-14-hover-grid"] radius:kRadius];
        self.settings = [[CSettings alloc] initWithApp:self];
        self.settings.window.appearance = ap;
        [self.settings showPage:0];
        [self snapshotView:self.settings.window.contentView name:[mode stringByAppendingString:@"-12-settings"] radius:0];
        [self.settings showPageNamed:@"Permissions"];
        [self snapshotView:self.settings.window.contentView name:[mode stringByAppendingString:@"-21-permissions"] radius:0];
    }
}
- (void)runSnapshots {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    self.iconCache = [NSMutableDictionary new]; self.clips = [NSMutableArray new]; self.items = @[];
    [self loadUsage]; [self loadConfig];
    [self buildUI];
    [self scanApps];
    [self refreshWindowList];
    if (self.readmeMode) {   // neutral sample data so public screenshots show nothing personal
        [self.clips addObjectsFromArray:@[@"brew install --cask iina", @"Meeting moved to 3:30 pm, room 4.12",
                                          @"https://developer.apple.com/design/human-interface-guidelines", @"git commit -m \"Tighten launcher spacing\""]];
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        self.recentFiles = @[@{@"path": [docs stringByAppendingPathComponent:@"Product Brief.pdf"], @"date": [NSDate dateWithTimeIntervalSince1970:now - 2 * 3600]},
                             @{@"path": [docs stringByAppendingPathComponent:@"Roadmap.png"], @"date": [NSDate dateWithTimeIntervalSince1970:now - 5 * 3600]},
                             @{@"path": [docs stringByAppendingPathComponent:@"Reading List.txt"], @"date": [NSDate dateWithTimeIntervalSince1970:now - 30 * 3600]}];
        self.usage = [@{@"cmd:Window: Left Half": @{@"count": @3, @"last": @(now - 600)},
                        @"cmd:Toggle Hidden Files": @{@"count": @1, @"last": @(now - 3 * 3600)}} mutableCopy];
        NSMutableArray *apps = [NSMutableArray new];
        for (NSString *p in @[@"/Applications/Safari.app", @"/System/Applications/Mail.app", @"/System/Applications/Notes.app",
                              @"/System/Applications/Calendar.app", @"/System/Applications/Music.app", @"/System/Applications/Photos.app",
                              @"/System/Applications/Utilities/Terminal.app", @"/System/Applications/System Settings.app"]) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            CItem *a = [CItem new]; a.title = p.lastPathComponent.stringByDeletingPathExtension; a.path = p; a.kind = @"Application";
            [apps addObject:[self appItem:a score:0]];
        }
        self.readmeApps = apps;
    } else {
        [self startRecentFilesQuery];
        [self.clips addObjectsFromArray:@[@"brew install --cask iina", @"Meeting moved to 3:30 pm, room 4.12"]];   // sample text, snapshots only
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:self.snapshotDir withIntermediateDirectories:YES attributes:nil error:nil];
    __block int waited = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        if (self.apps.count == 0 && ++waited < 24) return;
        [t invalidate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self snapshotAll]; [NSApp terminate:nil]; });
    }];
}
@end
