// Centre — a lightweight launcher for macOS (Raycast-style, native AppKit, single file).
// Build: ./centre   (compiles with clang from Command Line Tools; no Xcode needed)
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

#pragma mark - Model

typedef void (^CAction)(void);

@interface CItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *kind;      // right-hand label
@property (nonatomic, copy) NSString *path;      // for icon lookup / frecency key
@property (nonatomic, copy) NSString *symbol;    // SF symbol name for non-file items
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic) double score;
@property (nonatomic, copy) CAction action;      // Enter
@property (nonatomic, copy) CAction altAction;   // Cmd+Enter
@property (nonatomic, copy) NSString *altHint;
@property (nonatomic, copy) NSString *detail;    // right-hand text that replaces kind (e.g. "2h ago")
@property (nonatomic, copy) NSString *key;       // usage key, so the item can show up under Recent Commands
@end
@implementation CItem @end

static CItem *mk(NSString *title, NSString *sub, NSString *kind, NSString *symbol, CAction action) {
    CItem *i = [CItem new]; i.title = title; i.subtitle = sub; i.kind = kind; i.symbol = symbol; i.action = action; return i;
}

#pragma mark - Helpers

static NSString *supportDir(void) {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Centre"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void runShell(NSString *cmd, void (^done)(NSString *out)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *t = [NSTask new];
        t.launchPath = @"/bin/zsh"; t.arguments = @[@"-lc", cmd];
        NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = p;
        @try { [t launch]; } @catch (NSException *e) { if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(e.reason); }); return; }
        NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(s); });
    });
}

// AppleScript runs in-process on one serial queue (no osascript process per call); compiled scripts are cached.
static void runOsa(NSString *script, void (^done)(NSString *out)) {
    static dispatch_queue_t q; static NSMutableDictionary<NSString *, NSAppleScript *> *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.y.centre.osa", DISPATCH_QUEUE_SERIAL); cache = [NSMutableDictionary new]; });
    dispatch_async(q, ^{
        NSString *o = @"";
        @autoreleasepool {
            NSAppleScript *as = cache[script];
            if (!as) { as = [[NSAppleScript alloc] initWithSource:script]; if (cache.count > 64) [cache removeAllObjects]; if (as) cache[script] = as; }
            NSDictionary *err = nil;
            NSAppleEventDescriptor *r = [as executeAndReturnError:&err];
            if (err) o = [NSString stringWithFormat:@"%@ (%@)", err[NSAppleScriptErrorMessage] ?: @"AppleScript error", err[NSAppleScriptErrorNumber] ?: @""];
            else o = r.stringValue ?: @"";
        }
        NSString *trimmed = [o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(trimmed); });
    });
}
static void osa(NSString *script) { runOsa(script, nil); }

#pragma mark Password generator
// arc4random_uniform is cryptographically secure on macOS (kernel-seeded ChaCha20).
static NSString *pwPick(NSString *pool) {
    unichar c = [pool characterAtIndex:arc4random_uniform((uint32_t)pool.length)];
    return [NSString stringWithCharacters:&c length:1];
}
static NSString *const kPwLower = @"abcdefghijkmnopqrstuvwxyz", *const kPwUpper = @"ABCDEFGHJKLMNPQRSTUVWXYZ",
                     *const kPwDigit = @"23456789", *const kPwSymbol = @"!@#$%^&*-_=+?";
static NSString *genPassword(NSUInteger len, BOOL symbols) {
    NSString *pool = [NSString stringWithFormat:@"%@%@%@%@", kPwLower, kPwUpper, kPwDigit, symbols ? kPwSymbol : @""];
    for (int attempt = 0; attempt < 200; attempt++) {
        NSMutableString *p = [NSMutableString string];
        for (NSUInteger i = 0; i < len; i++) [p appendString:pwPick(pool)];
        BOOL lo = NO, up = NO, dg = NO, sy = !symbols;
        for (NSUInteger i = 0; i < p.length; i++) {
            unichar c = [p characterAtIndex:i];
            NSString *ch = [NSString stringWithCharacters:&c length:1];
            if ([kPwLower containsString:ch]) lo = YES; else if ([kPwUpper containsString:ch]) up = YES;
            else if ([kPwDigit containsString:ch]) dg = YES; else if ([kPwSymbol containsString:ch]) sy = YES;
        }
        if (lo && up && dg && sy) return p;   // every class present
    }
    return @"";
}
static double pwBits(NSUInteger len, BOOL symbols) {
    double pool = kPwLower.length + kPwUpper.length + kPwDigit.length + (symbols ? kPwSymbol.length : 0);
    return len * log2(pool);
}
static NSString *genPassphrase(NSUInteger nWords) {
    static NSArray *words; static dispatch_once_t once;
    dispatch_once(&once, ^{ words = @[@"acorn", @"amber", @"anchor", @"apple", @"arrow", @"aspen", @"atlas", @"autumn", @"badge", @"bamboo", @"banner", @"barley", @"basil", @"beacon", @"berry", @"birch", @"bison", @"blossom", @"bolt", @"breeze", @"brick", @"bridge", @"brook", @"bubble", @"cabin", @"cactus", @"camel", @"candle", @"canyon", @"cargo", @"carrot", @"castle", @"cedar", @"cherry", @"cider", @"cinder", @"citrus", @"clover", @"cobalt", @"comet", @"copper", @"coral", @"cosmos", @"cotton", @"crane", @"crater", @"cricket", @"crystal", @"cypress", @"dagger", @"daisy", @"delta", @"desert", @"diesel", @"dolphin", @"dragon", @"drift", @"eagle", @"ember", @"engine", @"falcon", @"feather", @"fern", @"fiddle", @"flint", @"forest", @"fossil", @"fountain", @"fox", @"galaxy", @"garnet", @"ginger", @"glacier", @"globe", @"granite", @"grape", @"gravel", @"harbor", @"hazel", @"heron", @"hollow", @"honey", @"horizon", @"indigo", @"iris", @"island", @"ivory", @"jade", @"jasmine", @"jungle", @"kettle", @"kiwi", @"lagoon", @"lantern", @"lava", @"lemon", @"lily", @"linen", @"lotus", @"lumen", @"magnet", @"mango", @"maple", @"marble", @"meadow", @"melon", @"meteor", @"mint", @"mirror", @"mosaic", @"motor", @"nectar", @"nickel", @"nova", @"oasis", @"ocean", @"olive", @"onyx", @"orbit", @"orchid", @"otter", @"paddle", @"panda", @"paper", @"parrot", @"pebble", @"pepper", @"pilot", @"pine", @"planet", @"plum", @"polar", @"poppy", @"prism", @"puzzle", @"quartz", @"quill", @"rabbit", @"radar", @"raven", @"reef", @"ribbon", @"river", @"robin", @"rocket", @"saddle", @"saffron", @"salmon", @"sapphire", @"satin", @"scarlet", @"shadow", @"shell", @"sierra", @"silver", @"sketch", @"slate", @"solar", @"sparrow", @"spice", @"spruce", @"summit", @"sunset", @"swift", @"tango", @"thistle", @"thunder", @"tiger", @"timber", @"topaz", @"tulip", @"tundra", @"velvet", @"violet", @"walnut", @"willow", @"winter", @"zephyr"]; });
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < nWords; i++) [parts addObject:[words[arc4random_uniform((uint32_t)words.count)] capitalizedString]];
    [parts addObject:[NSString stringWithFormat:@"%u", 10 + arc4random_uniform(90)]];
    return [parts componentsJoinedByString:@"-"];
}
static NSUInteger pwWordCount(void) { return 178; }
static NSString *genPIN(NSUInteger len) {
    NSMutableString *p = [NSMutableString string];
    for (NSUInteger i = 0; i < len; i++) [p appendFormat:@"%u", arc4random_uniform(10)];
    return p;
}
// Copies a secret: marked concealed so clipboard managers (and Centre's own history) skip it, and cleared after 90 s.
static void copySecret(NSString *s) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:@[NSPasteboardTypeString, @"org.nspasteboard.ConcealedType", @"org.nspasteboard.TransientType"] owner:nil];
    [pb setString:s forType:NSPasteboardTypeString];
    [pb setString:@"" forType:@"org.nspasteboard.ConcealedType"];
    [pb setString:@"" forType:@"org.nspasteboard.TransientType"];
    NSInteger cc = pb.changeCount;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([NSPasteboard generalPasteboard].changeCount == cc) [[NSPasteboard generalPasteboard] clearContents];
    });
}

static void copyText(NSString *s) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents]; [pb setString:s forType:NSPasteboardTypeString];
}

static void openURLString(NSString *s) {
    NSURL *u = [NSURL URLWithString:s];
    if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

static NSString *urlEncode(NSString *s) {
    NSMutableCharacterSet *cs = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [cs addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs] ?: s;
}

// Fuzzy subsequence score. < 0 means no match.
static double fuzzyScore(NSString *query, NSString *target) {
    NSString *q = query.lowercaseString, *t = target.lowercaseString;
    NSUInteger ql = q.length, tl = t.length;
    if (ql == 0) return 0; if (tl == 0) return -1;
    if ([t hasPrefix:q]) return 100 + (ql == tl ? 50 : 0) - (double)(tl - ql) * 0.2;
    NSUInteger qi = 0; double score = 0; NSInteger prev = -2; NSUInteger first = NSNotFound;
    for (NSUInteger ti = 0; ti < tl && qi < ql; ti++) {
        unichar tc = [t characterAtIndex:ti], qc = [q characterAtIndex:qi];
        if (tc != qc) continue;
        double add = 10;
        BOOL wordStart = (ti == 0);
        if (!wordStart) { unichar pc = [t characterAtIndex:ti - 1]; wordStart = (pc == ' ' || pc == '-' || pc == '_' || pc == '.' || pc == '/'); }
        if (wordStart) add += 12;
        if ((NSInteger)ti == prev + 1) add += 8;
        if (first == NSNotFound) first = ti;
        score += add; prev = ti; qi++;
    }
    if (qi < ql) return -1;
    score -= (double)first * 1.5;
    score -= (double)(tl - ql) * 0.15;
    return score;
}

static NSImage *symbolImage(NSString *name) {
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
        if (img) {
            NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightRegular];
            img = [img imageWithSymbolConfiguration:cfg];
            img.template = YES;
            return img;
        }
    }
    return [NSImage imageNamed:NSImageNameActionTemplate];
}

// Decode an icon once into a 128px bitmap (off the main thread) so drawing it later is a plain blit.
static NSImage *prerenderIcon(NSImage *src) {
    if (!src) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:128 pixelsHigh:128 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (!rep) return nil;
    rep.size = NSMakeSize(64, 64);
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) return nil;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [src drawInRect:NSMakeRect(0, 0, 64, 64) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
    [out addRepresentation:rep];
    return out;
}

#pragma mark - Design tokens

// One accent, the icy core of the app icon. Used sparingly: the text caret and the active-mode chip.
static NSColor *cAccent(void) {
    static NSColor *c; static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSColor colorWithName:@"CentreIce" dynamicProvider:^NSColor *(NSAppearance *ap) {
            BOOL dark = [ap bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
            return dark ? [NSColor colorWithSRGBRed:0.56 green:0.86 blue:1.00 alpha:1] : [NSColor colorWithSRGBRed:0.13 green:0.58 blue:0.92 alpha:1];
        }];
    });
    return c;
}
static BOOL cIsDark(NSView *v) {
    return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}
// Selection fill + hairline shared by result rows, grid cells and the settings sidebar.
static NSColor *cSelFill(NSView *v) { return cIsDark(v) ? [NSColor colorWithWhite:1 alpha:0.095] : [NSColor colorWithWhite:0 alpha:0.065]; }
static NSColor *cSelEdge(NSView *v) { return cIsDark(v) ? [NSColor colorWithWhite:1 alpha:0.055] : [NSColor colorWithWhite:0 alpha:0.04]; }

static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
// System Settings–style tile colours (top, bottom) per result kind.
static NSArray<NSColor *> *tileColors(NSString *kind) {
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
                 @"Files": slate, @"File": slate };
    });
    return map[kind ?: @""] ?: map[@"System"];
}
// Rounded colour tile with a white SF Symbol; resolution-independent and cached.
static NSImage *tileImage(NSString *symbol, NSString *kind) {
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

#pragma mark - Hotkey helpers

static NSDictionary<NSString *, NSNumber *> *hotkeyKeyMap(void) {
    static NSDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{ @"space": @(kVK_Space), @"return": @(kVK_Return), @"tab": @(kVK_Tab), @"`": @(kVK_ANSI_Grave), @"escape": @(kVK_Escape),
               @"-": @(kVK_ANSI_Minus), @"=": @(kVK_ANSI_Equal), @",": @(kVK_ANSI_Comma), @".": @(kVK_ANSI_Period), @"/": @(kVK_ANSI_Slash),
               @";": @(kVK_ANSI_Semicolon), @"'": @(kVK_ANSI_Quote), @"[": @(kVK_ANSI_LeftBracket), @"]": @(kVK_ANSI_RightBracket), @"\\": @(kVK_ANSI_Backslash),
               @"a": @(kVK_ANSI_A), @"b": @(kVK_ANSI_B), @"c": @(kVK_ANSI_C), @"d": @(kVK_ANSI_D), @"e": @(kVK_ANSI_E), @"f": @(kVK_ANSI_F), @"g": @(kVK_ANSI_G),
               @"h": @(kVK_ANSI_H), @"i": @(kVK_ANSI_I), @"j": @(kVK_ANSI_J), @"k": @(kVK_ANSI_K), @"l": @(kVK_ANSI_L), @"m": @(kVK_ANSI_M), @"n": @(kVK_ANSI_N),
               @"o": @(kVK_ANSI_O), @"p": @(kVK_ANSI_P), @"q": @(kVK_ANSI_Q), @"r": @(kVK_ANSI_R), @"s": @(kVK_ANSI_S), @"t": @(kVK_ANSI_T), @"u": @(kVK_ANSI_U),
               @"v": @(kVK_ANSI_V), @"w": @(kVK_ANSI_W), @"x": @(kVK_ANSI_X), @"y": @(kVK_ANSI_Y), @"z": @(kVK_ANSI_Z),
               @"0": @(kVK_ANSI_0), @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2), @"3": @(kVK_ANSI_3), @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5),
               @"6": @(kVK_ANSI_6), @"7": @(kVK_ANSI_7), @"8": @(kVK_ANSI_8), @"9": @(kVK_ANSI_9),
               @"f1": @(kVK_F1), @"f2": @(kVK_F2), @"f3": @(kVK_F3), @"f4": @(kVK_F4), @"f5": @(kVK_F5), @"f6": @(kVK_F6),
               @"f7": @(kVK_F7), @"f8": @(kVK_F8), @"f9": @(kVK_F9), @"f10": @(kVK_F10), @"f11": @(kVK_F11), @"f12": @(kVK_F12) };
    });
    return m;
}

static NSString *prettyHotkey(NSString *spec) {
    NSString *ctrl = @"", *alt = @"", *shift = @"", *cmd = @"", *key = @"";
    NSDictionary *names = @{ @"space": @"Space", @"return": @"↩", @"tab": @"⇥", @"escape": @"⎋" };
    for (NSString *p0 in [[spec ?: @"" lowercaseString] componentsSeparatedByString:@"+"]) {
        NSString *p = [p0 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([p isEqualToString:@"ctrl"] || [p isEqualToString:@"control"]) ctrl = @"⌃";
        else if ([p isEqualToString:@"alt"] || [p isEqualToString:@"opt"] || [p isEqualToString:@"option"]) alt = @"⌥";
        else if ([p isEqualToString:@"shift"]) shift = @"⇧";
        else if ([p isEqualToString:@"cmd"] || [p isEqualToString:@"command"]) cmd = @"⌘";
        else if (p.length) key = names[p] ?: p.uppercaseString;
    }
    return [NSString stringWithFormat:@"%@%@%@%@ %@", ctrl, alt, shift, cmd, key];
}

#pragma mark - Accessibility window management

static void moveFrontWindow(NSRunningApplication *app, NSString *mode) {
    if (!app) return;
    if (!AXIsProcessTrusted()) {
        NSDictionary *o = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
        return;
    }
    AXUIElementRef appEl = AXUIElementCreateApplication(app.processIdentifier);
    CFTypeRef win = NULL;
    AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute, &win);
    if (!win) { CFRelease(appEl); return; }
    CGPoint cur = CGPointZero; CFTypeRef pv = NULL;
    AXUIElementCopyAttributeValue((AXUIElementRef)win, kAXPositionAttribute, &pv);
    if (pv) { AXValueGetValue((AXValueRef)pv, kAXValueTypeCGPoint, &cur); CFRelease(pv); }
    NSScreen *primary = NSScreen.screens.firstObject; CGFloat H = primary.frame.size.height;
    NSPoint cocoa = NSMakePoint(cur.x + 2, H - cur.y - 2);
    NSScreen *scr = primary;
    for (NSScreen *s in NSScreen.screens) if (NSPointInRect(cocoa, s.frame)) scr = s;
    NSRect v = scr.visibleFrame, r = v;
    if ([mode isEqualToString:@"left"])       r.size.width = floor(v.size.width / 2);
    else if ([mode isEqualToString:@"right"]) { r.size.width = floor(v.size.width / 2); r.origin.x = v.origin.x + v.size.width - r.size.width; }
    else if ([mode isEqualToString:@"top"])   { r.size.height = floor(v.size.height / 2); r.origin.y = v.origin.y + v.size.height - r.size.height; }
    else if ([mode isEqualToString:@"bottom"]) r.size.height = floor(v.size.height / 2);
    else if ([mode isEqualToString:@"center"]) { r.size.width = floor(v.size.width * 0.7); r.size.height = floor(v.size.height * 0.8); r.origin.x = v.origin.x + (v.size.width - r.size.width) / 2; r.origin.y = v.origin.y + (v.size.height - r.size.height) / 2; }
    CGPoint np = CGPointMake(r.origin.x, H - (r.origin.y + r.size.height));
    CGSize ns = CGSizeMake(r.size.width, r.size.height);
    AXValueRef npv = AXValueCreate(kAXValueTypeCGPoint, &np), nsv = AXValueCreate(kAXValueTypeCGSize, &ns);
    AXUIElementSetAttributeValue((AXUIElementRef)win, kAXPositionAttribute, npv);
    AXUIElementSetAttributeValue((AXUIElementRef)win, kAXSizeAttribute, nsv);
    AXUIElementSetAttributeValue((AXUIElementRef)win, kAXPositionAttribute, npv);
    CFRelease(npv); CFRelease(nsv); CFRelease(win); CFRelease(appEl);
}

static void simulatePaste(void) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef d = CGEventCreateKeyboardEvent(src, (CGKeyCode)9, true);
    CGEventRef u = CGEventCreateKeyboardEvent(src, (CGKeyCode)9, false);
    CGEventSetFlags(d, kCGEventFlagMaskCommand); CGEventSetFlags(u, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, d); CGEventPost(kCGHIDEventTap, u);
    CFRelease(d); CFRelease(u); if (src) CFRelease(src);
}

#pragma mark - Views

@interface CPanel : NSPanel @end
@implementation CPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// ---------- Panel chrome ----------

// Near-opaque layer over the vibrancy so busy wallpapers/windows don't muddy the panel.
@interface CBackdrop : NSView @end
@implementation CBackdrop
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r {
    [(cIsDark(self) ? [NSColor colorWithSRGBRed:0.112 green:0.114 blue:0.126 alpha:0.88] : [NSColor colorWithSRGBRed:0.978 green:0.978 blue:0.982 alpha:0.90]) setFill];
    NSRectFill(self.bounds);
}
@end

@interface CHairline : NSView @end
@implementation CHairline
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r { [[[NSColor labelColor] colorWithAlphaComponent:0.08] setFill]; NSRectFill(self.bounds); }
@end

static const CGFloat kRadius = 16;
@interface CEdgeView : NSView @end
@implementation CEdgeView
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r {
    BOOL dark = cIsDark(self);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:kRadius - 0.5 yRadius:kRadius - 0.5];
    p.lineWidth = 1; [(dark ? [NSColor colorWithWhite:1 alpha:0.14] : [NSColor colorWithWhite:0 alpha:0.15]) setStroke]; [p stroke];
    if (dark) {   // glass: a faint lit line along the top edge, fading out before the corners
        NSColor *clear = [NSColor colorWithWhite:1 alpha:0], *lit = [NSColor colorWithWhite:1 alpha:0.075];
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:clear, 0.0, lit, 0.2, lit, 0.8, clear, 1.0, nil];
        [g drawInRect:NSMakeRect(kRadius * 0.6, self.bounds.size.height - 2, self.bounds.size.width - kRadius * 1.2, 1) angle:0];
    }
}
@end

// Quiet band behind the footer hints.
@interface CFooterBar : NSView @end
@implementation CFooterBar
- (void)drawRect:(NSRect)r { [(cIsDark(self) ? [NSColor colorWithWhite:1 alpha:0.028] : [NSColor colorWithWhite:0 alpha:0.024]) setFill]; NSRectFill(self.bounds); }
@end

// Active-mode token at the right of the search field ("Clipboard", "Files", "youtube.com"…).
@interface CChip : NSView
@property (nonatomic, copy) NSString *text;
- (CGFloat)fittingWidth;
@end
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
@interface CKeyHints : NSView
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *hints;   // @[@[label, key1, key2…], …]
@end
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
@interface CRowView : NSView
@property (nonatomic) BOOL selected;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *titleLabel, *kindLabel;
@property (nonatomic) CGFloat iconSize;          // 26 in results, 22 in the compact home lists
@property (nonatomic) NSInteger globalIndex;     // position in CApp.items (home lists)
- (void)setTitle:(NSString *)t subtitle:(NSString *)s;
- (void)setKind:(NSString *)kind shortcut:(NSString *)shortcut;
@end
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
    if (one.length) [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@"    " stringByAppendingString:one]
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}]];
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
    CGFloat is = _iconSize, tx = 22 + is + 12;
    _iconView.frame = NSMakeRect(22, floor((H - is) / 2), is, is);
    _kindLabel.frame = NSMakeRect(W - 26 - 140, floor((H - 16) / 2), 140, 16);
    _titleLabel.frame = NSMakeRect(tx, floor((H - 19) / 2), W - tx - 178, 19);
}
- (void)drawRect:(NSRect)r {
    if (_selected) {
        [cSelFill(self) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 8, 1.5) xRadius:9 yRadius:9] fill];
        NSBezierPath *e = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 8.5, 2) xRadius:8.5 yRadius:8.5];
        e.lineWidth = 1; [cSelEdge(self) setStroke]; [e stroke];
    }
}
@end

// ---------- Most-used grid ----------
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
static const CGFloat kCellW = 84, kCellH = 84, kGridX = 24, kQuickH = 46, kHomeRowH = 34, kHomeHeadH = 26;
@implementation CGridView
- (void)reload {
    for (NSView *v in [self.subviews copy]) [v removeFromSuperview];
    NSInteger n = (NSInteger)self.items.count;
    for (NSInteger i = 0; i < n; i++) {
        CItem *it = self.items[i];
        NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(kGridX + i * kCellW, 0, kCellW, kCellH)];
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect((kCellW - 48) / 2, kCellH - 48 - 9, 48, 48)];
        iv.imageScaling = NSImageScaleProportionallyUpOrDown;
        NSImage *img = self.iconFor ? self.iconFor(it) : nil;
        iv.image = img; if (img.template) iv.contentTintColor = [NSColor secondaryLabelColor];
        NSString *t = (self.showShortcuts && i < 9) ? [NSString stringWithFormat:@"\u2318%ld", (long)i + 1] : (it.title ?: @"");
        NSTextField *lbl = [NSTextField labelWithString:t];
        lbl.font = [NSFont systemFontOfSize:11.5 weight:i == self.selected ? NSFontWeightMedium : NSFontWeightRegular]; lbl.alignment = NSTextAlignmentCenter;
        lbl.textColor = i == self.selected ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        lbl.lineBreakMode = NSLineBreakByTruncatingTail; lbl.frame = NSMakeRect(6, 9, kCellW - 12, 16);
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
            ((NSTextField *)v).font = [NSFont systemFontOfSize:11.5 weight:i == s ? NSFontWeightMedium : NSFontWeightRegular];
        }
        i++;
    }
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)r {
    if (_selected >= 0 && _selected < (NSInteger)self.items.count) {
        NSRect b = NSMakeRect(kGridX + _selected * kCellW + 4, 1, kCellW - 8, kCellH - 2);
        [cSelFill(self) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:14 yRadius:14] fill];
        NSBezierPath *e = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:13.5 yRadius:13.5];
        e.lineWidth = 1; [cSelEdge(self) setStroke]; [e stroke];
    }
}
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = (NSInteger)floor((p.x - kGridX) / kCellW);
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
    NSInteger i = (NSInteger)floor((p.x - kGridX) / kCellW);
    if (i >= 0 && i < (NSInteger)self.items.count && self.onHover) self.onHover(i);
}
@end

// ---------- Quick actions: a row of pill buttons under Most Used ----------
@interface CQuickStrip : NSView
@property (nonatomic, strong) NSArray<CItem *> *items;
@property (nonatomic) NSInteger selected;            // local index, -1 = none
@property (nonatomic, copy) void (^onPick)(NSInteger);
@property (nonatomic, copy) void (^onHover)(NSInteger);
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@end
@implementation CQuickStrip
- (NSDictionary *)attrs:(BOOL)sel {
    return @{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium],
             NSForegroundColorAttributeName: sel ? [NSColor labelColor] : [NSColor secondaryLabelColor]};
}
- (NSArray<NSValue *> *)pillRects {
    NSMutableArray *r = [NSMutableArray new];
    CGFloat x = kGridX + 4, H = self.bounds.size.height, h = 30;
    for (CItem *it in self.items) {
        CGFloat w = 9 + 18 + 7 + ceil([it.title sizeWithAttributes:[self attrs:NO]].width) + 13;
        if (x + w > self.bounds.size.width - kGridX) break;          // never overflow the panel
        [r addObject:[NSValue valueWithRect:NSMakeRect(x, floor((H - h) / 2), w, h)]];
        x += w + 8;
    }
    return r;
}
- (void)setItems:(NSArray<CItem *> *)items { _items = items; [self setNeedsDisplay:YES]; }
- (void)setSelected:(NSInteger)s { _selected = s; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    BOOL dark = cIsDark(self);
    NSArray *rects = [self pillRects];
    for (NSUInteger i = 0; i < rects.count; i++) {
        NSRect b = [rects[i] rectValue]; BOOL sel = (NSInteger)i == self.selected;
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:(b.size.height - 1) / 2 yRadius:(b.size.height - 1) / 2];
        [(sel ? cSelFill(self) : (dark ? [NSColor colorWithWhite:1 alpha:0.04] : [NSColor colorWithWhite:0 alpha:0.03])) setFill]; [p fill];
        p.lineWidth = 1; [(sel ? (dark ? [NSColor colorWithWhite:1 alpha:0.13] : [NSColor colorWithWhite:0 alpha:0.10]) : cSelEdge(self)) setStroke]; [p stroke];
        CItem *it = self.items[i];
        NSRect ir = NSMakeRect(b.origin.x + 9, floor(NSMidY(b) - 9), 18, 18);
        [tileImage(it.symbol, it.kind) drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        NSDictionary *a = [self attrs:sel]; NSSize ts = [it.title sizeWithAttributes:a];
        [it.title drawAtPoint:NSMakePoint(NSMaxX(ir) + 7, NSMidY(b) - ts.height / 2) withAttributes:a];
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
    for (id e in self.entries) {
        if ([e isKindOfClass:[NSString class]]) {
            NSTextField *h = [NSTextField labelWithString:e];
            h.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]; h.textColor = [NSColor secondaryLabelColor];
            h.frame = NSMakeRect(kGridX + 6, y + 8, 300, 15);
            [self addSubview:h]; y += kHomeHeadH;
        } else {
            CItem *it = e;
            CRowView *r = [[CRowView alloc] initWithFrame:NSMakeRect(0, y, W, kHomeRowH)];
            r.iconSize = 22; r.globalIndex = idx++; r.autoresizingMask = NSViewWidthSizable;
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
- (void)mouseDown:(NSEvent *)e { NSInteger i = [self indexAt:e]; if (i >= 0 && self.onPick) self.onPick(i); }
- (void)mouseMoved:(NSEvent *)e { NSInteger i = [self indexAt:e]; if (i >= 0 && self.onHover) self.onHover(i); }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
@end

// ---------- Now Playing (MediaRemote, private framework; loaded at runtime) ----------
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRSetElapsedFn)(double);
static MRGetInfoFn MRGetInfo; static MRSendFn MRSend; static MRRegisterFn MRRegister; static MRGetPIDFn MRGetPID; static MRIsPlayingFn MRIsPlaying;
static MRSetElapsedFn MRSetElapsed;
static void loadMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) return;
        MRGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRSend = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
        MRRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRGetPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        MRIsPlaying = (MRIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRSetElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    });
}
// Fallback: synthesize the hardware media keys (needs Accessibility).
static void postMediaKey(int key) {   // NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18
    for (int down = 1; down >= 0; down--) {
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:(down ? 0xa00 : 0xb00)
                                       timestamp:0 windowNumber:0 context:nil subtype:8 data1:((key << 16) | ((down ? 0xa : 0xb) << 8)) data2:-1];
        CGEventPost(kCGHIDEventTap, e.CGEvent);
    }
}
static NSImage *symSize(NSString *name, CGFloat pt) {
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightSemibold]];
}

static NSString *fmtTime(double sec) {
    if (!(sec >= 0) || isinf(sec)) sec = 0;
    long t = (long)floor(sec + 0.5), h = t / 3600, m = (t % 3600) / 60, x = t % 60;
    return h > 0 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, x] : [NSString stringWithFormat:@"%ld:%02ld", m, x];
}

static const CGFloat kMediaH = 92;
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
        for (NSView *v in @[_art, _titleL, _subL, _elapsedL, _remainL, _prevB, _playB, _nextB]) [self addSubview:v];
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
- (void)setPlaying:(BOOL)p { self.playB.image = symSize(p ? @"pause.fill" : @"play.fill", 19); }
- (NSRect)card { return NSMakeRect(12, 6, self.bounds.size.width - 24, self.bounds.size.height - 12); }
// Track rect between the two time labels; the hit area is taller than the drawn bar.
- (NSRect)barRect { return NSMakeRect(NSMaxX(self.elapsedL.frame) + 6, NSMinY([self card]) + 18, MAX(0, NSMinX(self.remainL.frame) - NSMaxX(self.elapsedL.frame) - 12), 4); }
- (NSRect)barHitRect { return NSInsetRect([self barRect], -4, -8); }
- (void)layout {
    [super layout];
    NSRect c = [self card];
    self.art.frame = NSMakeRect(c.origin.x + 12, c.origin.y + floor((c.size.height - 56) / 2), 56, 56);
    CGFloat ctrlW = 3 * 34 + 4;
    CGFloat tx = NSMaxX(self.art.frame) + 14, tw = NSMaxX(c) - ctrlW - tx - 20;
    self.titleL.frame = NSMakeRect(tx, NSMaxY(c) - 14 - 18, tw, 18);
    self.subL.frame = NSMakeRect(tx, NSMaxY(c) - 14 - 18 - 17, tw, 16);
    self.elapsedL.frame = NSMakeRect(tx, c.origin.y + 13, 46, 14);
    self.remainL.frame = NSMakeRect(tx + tw - 50, c.origin.y + 13, 50, 14);
    CGFloat cy = NSMidY(c) - 17, x = NSMaxX(c) - 12 - 34;
    self.nextB.frame = NSMakeRect(x, cy, 34, 34); x -= 35;
    self.playB.frame = NSMakeRect(x, cy, 34, 34); x -= 35;
    self.prevB.frame = NSMakeRect(x, cy, 34, 34);
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
    [(dark ? [NSColor colorWithWhite:1 alpha:0.06] : [NSColor colorWithWhite:0 alpha:0.04]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:c xRadius:12 yRadius:12] fill];
    NSBezierPath *ce = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(c, 0.5, 0.5) xRadius:11.5 yRadius:11.5];
    ce.lineWidth = 1; [cSelEdge(self) setStroke]; [ce stroke];
    if (self.progress < 0 || self.duration <= 0) return;
    BOOL big = self.hoverBar || self.scrubbing;
    NSRect t = [self barRect]; if (big) t = NSInsetRect(t, 0, -1);
    CGFloat rad = t.size.height / 2;
    [(dark ? [NSColor colorWithWhite:1 alpha:0.14] : [NSColor colorWithWhite:0 alpha:0.12]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:t xRadius:rad yRadius:rad] fill];
    NSRect f = t; f.size.width = MAX(t.size.height, t.size.width * self.progress);
    [cAccent() setFill]; [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
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
@interface CTable : NSTableView
@property (nonatomic, copy) void (^onHover)(NSInteger row);
@property (nonatomic, strong) NSTrackingArea *hoverArea;
@end
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

@interface CField : NSTextField @end
@implementation CField
- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    NSText *ed = self.currentEditor;
    if (ok && [ed isKindOfClass:[NSTextView class]]) ((NSTextView *)ed).insertionPointColor = cAccent();
    return ok;
}
@end

#pragma mark - App

@class CSettings;
@interface CApp : NSObject <NSApplicationDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) CPanel *panel;
@property (nonatomic, strong) NSVisualEffectView *fx;
@property (nonatomic, strong) CField *field;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSView *separator, *footer, *footerLine;
@property (nonatomic, strong) NSImageView *searchIcon;
@property (nonatomic, strong) NSTextField *escPill, *footerLeft, *footerRight, *gridTitle;
@property (nonatomic, strong) CKeyHints *hints;
@property (nonatomic, strong) NSImageView *footerIcon;
@property (nonatomic, strong) CMediaView *media;
@property (nonatomic, strong) NSTimer *mediaTimer;
@property (nonatomic) BOOL hasNow, isPlaying;
@property (nonatomic, copy) NSString *nowTitle, *nowArtist, *nowApp;
@property (nonatomic, strong) NSImage *nowArt, *nowAppIcon;
@property (nonatomic, strong) NSDate *nowStamp;
@property (nonatomic) double nowDuration, nowElapsed, nowRate;
@property (nonatomic) BOOL ytmBusy;
@property (nonatomic, copy) NSString *ytmArtURL;
@property (nonatomic, strong) CGridView *grid;
@property (nonatomic) BOOL gridMode;
@property (nonatomic, strong) CChip *chip;
@property (nonatomic, strong) CQuickStrip *quick;
@property (nonatomic, strong) CHomeList *homeList;
@property (nonatomic) NSInteger homeApps, homeQuick;        // items = [apps…, quick actions…, list rows…] on the home screen
@property (nonatomic, strong) NSArray *homeEntries;         // list headers + rows
@property (nonatomic, strong) NSArray<NSDictionary *> *recentFiles;   // @{path, date}, newest first
@property (nonatomic, strong) NSMetadataQuery *recentQuery;
@property (nonatomic, strong) id recentObserver;
@property (nonatomic, copy) NSString *modeLabel;   // active prefix mode, shown as a chip in the search row
@property (nonatomic) BOOL cmdHeld;                // ⌘ down: rows show their ⌘1…⌘9 shortcuts
@property (nonatomic, strong) NSStatusItem *status;
@property (nonatomic, strong) NSArray<CItem *> *items;
@property (nonatomic) NSInteger selected;
@property (nonatomic, strong) NSArray<CItem *> *apps;          // scanned apps
@property (nonatomic, strong) NSMutableDictionary *usage;      // path -> @{count,last}
@property (nonatomic, strong) NSMutableDictionary *iconCache;
@property (nonatomic, strong) NSMutableArray<NSString *> *clips;
@property (nonatomic) NSInteger pbCount;
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) NSDate *configMtime;
@property (nonatomic, strong) NSRunningApplication *previousApp;
@property (nonatomic, strong) NSMetadataQuery *fileQuery;
@property (nonatomic, strong) id fileQueryObserver;
@property (nonatomic, strong) NSTimer *fileDebounce;
@property (nonatomic, strong) NSArray<NSString *> *dockCache;
@property (nonatomic) NSTimeInterval dockCacheAt;
@property (nonatomic, copy) NSString *currentQuery;
@property (nonatomic) EventHotKeyRef hotKeyRef;
- (void)toggle;
@property (nonatomic) NSTimeInterval lastScan;
@property (nonatomic) BOOL rebuilding;
@property (nonatomic, copy) NSString *snapshotDir;
@property (nonatomic) BOOL readmeMode;                       // --readme <dir>: curated screenshots with neutral sample data
@property (nonatomic, strong) NSArray<CItem *> *readmeApps;   // --snapshot <dir>: render the UI offscreen to PNGs and exit
@property (nonatomic, strong) NSDate *failedSource;
@property (nonatomic, strong) CSettings *settings;
- (NSString *)configPath;
- (void)loadConfig;
- (void)writeConfig:(NSDictionary *)c;
- (void)registerHotKey;
- (void)unregisterHotKey;
- (void)scanApps;
- (void)grantAX;
- (void)rebuild;
- (void)resetUsage;
- (void)openConfigFile;
- (void)setLaunchAtLogin:(BOOL)on;
- (NSString *)ytmBrowser;
@end

@interface CSettings : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow *window;
- (instancetype)initWithApp:(CApp *)app;
- (void)show;
- (void)showPage:(NSInteger)i;
@end

static const CGFloat kW = 720, kSearchH = 62, kRowH = 44, kGridH = 124, kFooterH = 40;
static const NSInteger kMaxRows = 9;

static NSString *shortAgo(NSTimeInterval t) {
    NSTimeInterval a = [NSDate date].timeIntervalSince1970 - t;
    if (a < 60) return @"Just now";
    if (a < 3600) return [NSString stringWithFormat:@"%.0fm ago", floor(a / 60)];
    if (a < 86400) return [NSString stringWithFormat:@"%.0fh ago", floor(a / 3600)];
    if (a < 2 * 86400) return @"Yesterday";
    return [NSString stringWithFormat:@"%.0fd ago", floor(a / 86400)];
}

static NSString *defaultBrowserName(void) {
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]];
    NSString *n = u.lastPathComponent.stringByDeletingPathExtension;
    return n.length ? n : @"Safari";
}

@implementation CApp

#pragma mark Config

- (NSString *)configPath { return [supportDir() stringByAppendingPathComponent:@"config.json"]; }

- (void)loadConfig {
    NSString *p = self.configPath; NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:p]) {
        NSDictionary *def = @{
            @"hotkey": @"cmd+space",
            @"editor": @"Zed",
            @"webSearch": @"https://duckduckgo.com/?q=%s",
            @"searchPrefixes": @{ @"g": @"https://www.google.com/search?q=%s",
                                  @"yt": @"https://www.youtube.com/results?search_query=%s",
                                  @"gh": @"https://github.com/search?q=%s",
                                  @"wiki": @"https://en.wikipedia.org/w/index.php?search=%s",
                                  @"x": @"https://x.com/search?q=%s",
                                  @"amz": @"https://www.amazon.com/s?k=%s" },
            @"links": @[ @{@"name": @"YouTube", @"url": @"https://youtube.com"},
                         @{@"name": @"GitHub", @"url": @"https://github.com"} ],
            @"appFolders": @[ @"/Applications", @"/Applications/Utilities", @"/System/Applications",
                              @"/System/Applications/Utilities", @"~/Applications" ]
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:def options:NSJSONWritingPrettyPrinted error:nil];
        [d writeToFile:p atomically:YES];
    }
    NSDate *mt = [[fm attributesOfItemAtPath:p error:nil] fileModificationDate];
    if (self.config && self.configMtime && [mt isEqualToDate:self.configMtime]) return;
    NSData *d = [NSData dataWithContentsOfFile:p];
    NSDictionary *c = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![c isKindOfClass:[NSDictionary class]]) c = @{};
    NSString *oldHK = self.config[@"hotkey"];
    self.config = c; self.configMtime = mt;
    if (oldHK && ![oldHK isEqualToString:(c[@"hotkey"] ?: @"cmd+space")]) [self registerHotKey];
}

#pragma mark Usage / frecency

- (NSString *)usagePath { return [supportDir() stringByAppendingPathComponent:@"usage.json"]; }
- (void)loadUsage {
    NSData *d = [NSData dataWithContentsOfFile:self.usagePath];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    self.usage = [o isKindOfClass:[NSDictionary class]] ? [o mutableCopy] : [NSMutableDictionary new];
}
- (void)recordUse:(NSString *)key {
    if (!key.length) return;
    NSDictionary *e = self.usage[key];
    NSInteger n = [e[@"count"] integerValue] + 1;
    self.usage[key] = @{@"count": @(n), @"last": @([NSDate date].timeIntervalSince1970)};
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.usage options:0 error:nil];
    [d writeToFile:self.usagePath atomically:YES];
}
- (double)usageBoost:(NSString *)key {
    NSDictionary *e = self.usage[key]; if (!e) return 0;
    double n = MIN([e[@"count"] doubleValue], 20);
    double age = [NSDate date].timeIntervalSince1970 - [e[@"last"] doubleValue];
    double recency = age < 3600 ? 12 : age < 86400 ? 8 : age < 7 * 86400 ? 4 : 0;
    return n * 1.5 + recency;
}

#pragma mark Apps

- (void)scanApps {
    self.lastScan = [NSDate date].timeIntervalSince1970;
    NSArray *folders = self.config[@"appFolders"] ?: @[@"/Applications", @"/System/Applications", @"~/Applications"];
    NSSet *have = [NSSet setWithArray:self.iconCache.allKeys ?: @[]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray *out = [NSMutableArray new]; NSMutableSet *seen = [NSMutableSet new];
        void (^addApp)(NSString *) = ^(NSString *path) {
            NSString *name = [[fm displayNameAtPath:path] stringByDeletingPathExtension];
            if (!name.length || [seen containsObject:path]) return;
            [seen addObject:path];
            CItem *i = [CItem new]; i.title = name; i.path = path; i.kind = @"Application";
            [out addObject:i];
        };
        for (NSString *f0 in folders) {
            NSString *f = [f0 stringByExpandingTildeInPath];
            for (NSString *n in [fm contentsOfDirectoryAtPath:f error:nil]) {
                NSString *p = [f stringByAppendingPathComponent:n];
                if ([n.pathExtension isEqualToString:@"app"]) addApp(p);
                else {
                    BOOL dir = NO;
                    if ([fm fileExistsAtPath:p isDirectory:&dir] && dir && ![n hasPrefix:@"."]) {
                        for (NSString *n2 in [fm contentsOfDirectoryAtPath:p error:nil])
                            if ([n2.pathExtension isEqualToString:@"app"]) addApp([p stringByAppendingPathComponent:n2]);
                    }
                }
            }
        }
        // System Settings panes (Ventura+) via URL scheme are not enumerable; add the common ones.
        NSDictionary *panes = @{ @"Wi-Fi": @"com.apple.wifi-settings-extension", @"Bluetooth": @"com.apple.BluetoothSettings",
                                 @"Displays": @"com.apple.Displays-Settings.extension", @"Sound": @"com.apple.Sound-Settings.extension",
                                 @"Keyboard": @"com.apple.Keyboard-Settings.extension", @"Battery": @"com.apple.Battery-Settings.extension",
                                 @"Privacy & Security": @"com.apple.settings.PrivacySecurity.extension", @"Notifications": @"com.apple.Notifications-Settings.extension",
                                 @"Login Items": @"com.apple.LoginItems-Settings.extension", @"Network": @"com.apple.Network-Settings.extension" };
        for (NSString *k in panes) {
            CItem *i = [CItem new]; i.title = [@"Settings › " stringByAppendingString:k]; i.kind = @"System Settings";
            i.path = [@"x-apple.systempreferences:" stringByAppendingString:panes[k]];
            i.symbol = @"gearshape";
            [out addObject:i];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ self.apps = out; if (self.panel.visible) [self refresh]; });
        NSMutableDictionary *icons = [NSMutableDictionary new];
        for (CItem *i in out) {
            if (![i.path hasPrefix:@"/"] || [have containsObject:i.path]) continue;
            @autoreleasepool { NSImage *pre = prerenderIcon([[NSWorkspace sharedWorkspace] iconForFile:[i.path stringByResolvingSymlinksInPath]]); if (pre) icons[i.path] = pre; }
        }
        if (icons.count) dispatch_async(dispatch_get_main_queue(), ^{ [self.iconCache addEntriesFromDictionary:icons]; });
    });
}

- (NSArray<NSString *> *)dockAppPaths {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.dockCache && now - self.dockCacheAt < 60) return self.dockCache;
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.apple.dock"];
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *t in d[@"persistent-apps"]) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        NSString *u = t[@"tile-data"][@"file-data"][@"_CFURLString"];
        NSString *p = [u isKindOfClass:[NSString class]] ? [[NSURL URLWithString:u] path] : nil;
        if (p.length) [r addObject:[p stringByStandardizingPath]];
    }
    self.dockCache = r; self.dockCacheAt = now;
    return r;
}

- (NSImage *)iconFor:(CItem *)it {
    if (it.icon) return it.icon;
    if (it.path.length && [it.path hasPrefix:@"/"]) {
        NSImage *img = self.iconCache[it.path];
        if (!img) {
            NSString *p = [it.path stringByResolvingSymlinksInPath];
            img = [[NSFileManager defaultManager] fileExistsAtPath:p] ? [[NSWorkspace sharedWorkspace] iconForFile:p]
                                                                      : [[NSWorkspace sharedWorkspace] iconForFileType:p.pathExtension.length ? p.pathExtension : @"public.data"];
            img.size = NSMakeSize(64, 64); self.iconCache[it.path] = img;
        }
        return img;
    }
    if ([it.kind isEqualToString:@"System Settings"]) {
        NSString *sp = @"/System/Applications/System Settings.app";
        if (![[NSFileManager defaultManager] fileExistsAtPath:sp]) sp = @"/System/Applications/System Preferences.app";
        NSImage *img = self.iconCache[sp];
        if (!img) { img = [[NSWorkspace sharedWorkspace] iconForFile:sp]; img.size = NSMakeSize(64, 64); self.iconCache[sp] = img; }
        return img;
    }
    return tileImage(it.symbol ?: @"circle", it.kind);
}

#pragma mark Providers

- (NSArray<CItem *> *)systemCommands {
    __weak CApp *ws = self;
    NSMutableArray *a = [NSMutableArray new];
    [a addObject:mk(@"Sleep", @"Put the Mac to sleep", @"System", @"moon.zzz", ^{ runShell(@"pmset sleepnow", nil); })];
    [a addObject:mk(@"Lock Screen", nil, @"System", @"lock", ^{ runShell(@"'/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession' -suspend", nil); })];
    [a addObject:mk(@"Restart", nil, @"System", @"arrow.clockwise", ^{ osa(@"tell application \"System Events\" to restart"); })];
    [a addObject:mk(@"Shut Down", nil, @"System", @"power", ^{ osa(@"tell application \"System Events\" to shut down"); })];
    [a addObject:mk(@"Log Out", nil, @"System", @"person.crop.circle.badge.xmark", ^{ osa(@"tell application \"System Events\" to log out"); })];
    [a addObject:mk(@"Empty Trash", nil, @"System", @"trash", ^{ osa(@"tell application \"Finder\" to empty trash"); })];
    [a addObject:mk(@"Toggle Dark Mode", nil, @"System", @"circle.lefthalf.filled", ^{ osa(@"tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"); })];
    [a addObject:mk(@"Toggle Hidden Files", @"Show/hide dotfiles in Finder", @"System", @"eye", ^{ runShell(@"if [ \"$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null)\" = \"1\" ]; then defaults write com.apple.finder AppleShowAllFiles -bool false; else defaults write com.apple.finder AppleShowAllFiles -bool true; fi; killall Finder", nil); })];
    [a addObject:mk(@"Eject All Disks", nil, @"System", @"eject", ^{ osa(@"tell application \"Finder\" to eject (every disk whose ejectable is true)"); })];
    [a addObject:mk(@"Mute / Unmute", nil, @"System", @"speaker.slash", ^{ osa(@"set volume output muted not (output muted of (get volume settings))"); })];
    [a addObject:mk(@"Start Screen Saver", nil, @"System", @"display", ^{ runShell(@"open -a ScreenSaverEngine", nil); })];
    [a addObject:mk(@"Show Desktop", @"Hide all apps", @"System", @"rectangle.on.rectangle", ^{ osa(@"tell application \"System Events\" to set visible of every process whose visible is true and name is not \"Finder\" to false"); })];
    [a addObject:mk(@"Quit All Apps", nil, @"System", @"xmark.circle", ^{
        for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
            if (r.activationPolicy == NSApplicationActivationPolicyRegular && ![r.bundleIdentifier isEqualToString:@"com.apple.finder"] && r != NSRunningApplication.currentApplication) [r terminate];
    })];
    NSString *np = self.hasNow ? [NSString stringWithFormat:@"%@%@", self.nowTitle, self.nowApp.length ? [@" — " stringByAppendingString:self.nowApp] : @""] : @"Controls whatever is playing";
    [a addObject:mk(@"Play / Pause", np, @"Media", @"playpause.fill", ^{ [ws mediaCommand:2]; })];
    [a addObject:mk(@"Skip to Next Track", np, @"Media", @"forward.end.fill", ^{ [ws mediaCommand:4]; })];
    [a addObject:mk(@"Back to Previous Track", np, @"Media", @"backward.end.fill", ^{ [ws mediaCommand:5]; })];
    [a addObject:mk(@"Play Recent", @"Resume your recently played music on YouTube Music", @"Media", @"clock.arrow.circlepath", ^{ [ws ytmPlayRecent]; })];
    [a addObject:mk(@"Empty Clipboard", nil, @"System", @"doc.on.clipboard", ^{ [[NSPasteboard generalPasteboard] clearContents]; [ws.clips removeAllObjects]; })];
    [a addObject:mk(@"Generate Password", @"Copies a strong 20-character password  \u00B7  type  pw 32  for more options", @"Password", @"key.fill", ^{ copySecret(genPassword(20, YES)); })];
    // Window management
    NSDictionary *wins = @{ @"Window: Left Half": @"left", @"Window: Right Half": @"right", @"Window: Top Half": @"top",
                            @"Window: Bottom Half": @"bottom", @"Window: Maximize": @"max", @"Window: Center": @"center" };
    for (NSString *k in wins) {
        NSString *mode = wins[k];
        [a addObject:mk(k, @"Front window of the app you were using", @"Window", @"macwindow", ^{ moveFrontWindow(ws.previousApp, mode); })];
    }
    // Centre
    [a addObject:mk(@"Centre: Settings", @"Hotkey, links, search prefixes, app folders", @"Centre", @"slider.horizontal.3", ^{ [ws openSettings]; })];
    [a addObject:mk(@"Centre: Rescan Apps", nil, @"Centre", @"arrow.triangle.2.circlepath", ^{ [ws scanApps]; })];
    [a addObject:mk(@"Centre: Rebuild", @"Recompile Centre.m and relaunch (no Terminal needed)", @"Centre", @"hammer", ^{ [ws rebuild]; })];
    [a addObject:mk(@"Centre: Toggle Start at Login", nil, @"Centre", @"sunrise", ^{ [ws toggleLoginItem]; })];
    [a addObject:mk(@"Centre: Grant Accessibility", @"Needed for window commands and auto-paste", @"Centre", @"hand.raised", ^{
        NSDictionary *o = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES}; AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
    })];
    [a addObject:mk(@"Centre: Quit", nil, @"Centre", @"xmark", ^{ [NSApp terminate:nil]; })];
    for (CItem *c in a) c.key = [@"cmd:" stringByAppendingString:c.title];
    return a;
}

- (NSArray<CItem *> *)appItemsFor:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    for (CItem *a in self.apps) {
        double s = fuzzyScore(q, a.title); if (s < 0) continue;
        [r addObject:[self appItem:a score:s + [self usageBoost:a.path]]];
    }
    return r;
}

- (CItem *)appItem:(CItem *)a score:(double)score {
        CItem *i = [CItem new]; i.title = a.title; i.path = a.path; i.kind = a.kind; i.symbol = a.symbol;
        i.score = score;
        NSString *path = a.path;
        __weak CApp *ws = self;
        if ([path hasPrefix:@"/"]) {
            i.action = ^{ [ws recordUse:path]; [[NSWorkspace sharedWorkspace] openFile:path]; };
            i.altAction = ^{ [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""]; };
            i.altHint = @"⌘↩ Reveal";
        } else {
            i.action = ^{ [ws recordUse:path]; openURLString(path); };
        }
        return i;
}

- (CItem *)calcItem:(NSString *)q {
    NSString *s = q.lowercaseString;
    NSRegularExpression *pct = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([\\d.]+)\\s*%\\s*of\\s*([\\d.]+)\\s*$" options:0 error:nil];
    NSTextCheckingResult *m = [pct firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    double result = 0; BOOL ok = NO;
    if (m) { result = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue] / 100.0 * [[s substringWithRange:[m rangeAtIndex:2]] doubleValue]; ok = YES; }
    else {
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-*/()^%, xabcdefghijklmnopqrstuvwxyz"];
        if ([s rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
        if ([s rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound) return nil;
        if ([s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-*/^%x("]].location == NSNotFound) return nil;
        // words must be known functions/constants
        NSRegularExpression *words = [NSRegularExpression regularExpressionWithPattern:@"[a-z]+" options:0 error:nil];
        NSSet *known = [NSSet setWithArray:@[@"sqrt", @"ln", @"log", @"exp", @"floor", @"ceiling", @"abs", @"trunc", @"pi", @"e", @"x"]];
        for (NSTextCheckingResult *w in [words matchesInString:s options:0 range:NSMakeRange(0, s.length)])
            if (![known containsObject:[s substringWithRange:w.range]]) return nil;
        NSString *e = s;
        e = [e stringByReplacingOccurrencesOfString:@"," withString:@""];
        e = [e stringByReplacingOccurrencesOfString:@"^" withString:@"**"];
        e = [[NSRegularExpression regularExpressionWithPattern:@"(?<=[\\d)])\\s*x\\s*(?=[\\d(])" options:0 error:nil] stringByReplacingMatchesInString:e options:0 range:NSMakeRange(0, e.length) withTemplate:@"*"];
        e = [[NSRegularExpression regularExpressionWithPattern:@"([\\d.]+)\\s*%" options:0 error:nil] stringByReplacingMatchesInString:e options:0 range:NSMakeRange(0, e.length) withTemplate:@"($1/100)"];
        e = [[NSRegularExpression regularExpressionWithPattern:@"\\bpi\\b" options:0 error:nil] stringByReplacingMatchesInString:e options:0 range:NSMakeRange(0, e.length) withTemplate:@"3.141592653589793"];
        e = [[NSRegularExpression regularExpressionWithPattern:@"\\be\\b" options:0 error:nil] stringByReplacingMatchesInString:e options:0 range:NSMakeRange(0, e.length) withTemplate:@"2.718281828459045"];
        e = [[NSRegularExpression regularExpressionWithPattern:@"(?<![\\d.])(\\d+)(?![\\d.])" options:0 error:nil] stringByReplacingMatchesInString:e options:0 range:NSMakeRange(0, e.length) withTemplate:@"$1.0"];
        if ([e rangeOfString:@"x"].location != NSNotFound) return nil;
        @try {
            NSExpression *ex = [NSExpression expressionWithFormat:e];
            id v = [ex expressionValueWithObject:nil context:nil];
            if ([v isKindOfClass:[NSNumber class]]) { result = [v doubleValue]; ok = isfinite(result); }
        } @catch (NSException *x) { ok = NO; }
    }
    if (!ok) return nil;
    NSNumberFormatter *f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterDecimalStyle;
    f.maximumFractionDigits = 8; f.usesGroupingSeparator = YES;
    NSString *txt = [f stringFromNumber:@(result)] ?: [NSString stringWithFormat:@"%g", result];
    NSString *plain = [NSString stringWithFormat:@"%.10g", result];
    CItem *i = mk([@"= " stringByAppendingString:txt], q, @"Calculator", @"function", ^{ copyText(plain); });
    i.altAction = i.action; i.score = 1000;
    return i;
}

- (NSArray<CItem *> *)passwordItems:(NSString *)rest {
    NSUInteger len = 20;
    NSInteger n = [rest integerValue];
    if (n > 0) len = (NSUInteger)MIN(MAX(n, 8), 128);
    NSMutableArray *r = [NSMutableArray new];
    NSString *strong = genPassword(len, YES), *plain = genPassword(len, NO), *phrase = genPassphrase(5), *pin = genPIN(6);
    NSString *strongSub = [NSString stringWithFormat:@"Strong  \u00B7  %lu characters, letters + numbers + symbols  \u00B7  ~%.0f bits", (unsigned long)len, pwBits(len, YES)];
    NSString *plainSub = [NSString stringWithFormat:@"No symbols  \u00B7  for sites that reject them  \u00B7  ~%.0f bits", pwBits(len, NO)];
    NSString *phraseSub = [NSString stringWithFormat:@"Passphrase  \u00B7  easy to type and remember  \u00B7  ~%.0f bits", 5 * log2((double)pwWordCount()) + log2(90.0)];
    CItem *a = mk(strong, strongSub, @"Password", @"key.fill", ^{ copySecret(strong); });
    CItem *b = mk(plain, plainSub, @"Password", @"textformat.abc", ^{ copySecret(plain); });
    CItem *c = mk(phrase, phraseSub, @"Password", @"text.quote", ^{ copySecret(phrase); });
    CItem *d = mk(pin, @"6-digit PIN", @"Password", @"number", ^{ copySecret(pin); });
    [r addObjectsFromArray:@[a, b, c, d]];
    return r;
}

- (NSArray<CItem *> *)linkItemsFor:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *l in (self.config[@"links"] ?: @[])) {
        if (![l isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = l[@"name"] ?: @"", *url = l[@"url"] ?: @"";
        double s = fuzzyScore(q, name); if (s < 0) continue;
        CItem *i = mk(name, url, @"Link", @"link", ^{ openURLString(url); });
        i.score = s - 5 + [self usageBoost:url];
        __weak CApp *ws = self; i.action = ^{ [ws recordUse:url]; openURLString(url); };
        [r addObject:i];
    }
    return r;
}

- (NSArray<CItem *> *)runningAppItems:(NSString *)q force:(BOOL)force {
    NSMutableArray *r = [NSMutableArray new];
    for (NSRunningApplication *a in [NSWorkspace sharedWorkspace].runningApplications) {
        if (a.activationPolicy != NSApplicationActivationPolicyRegular || !a.localizedName) continue;
        if (a == NSRunningApplication.currentApplication) continue;
        double s = q.length ? fuzzyScore(q, a.localizedName) : 0; if (s < 0) continue;
        CItem *i = [CItem new]; i.title = [@"Quit " stringByAppendingString:a.localizedName];
        i.subtitle = force ? @"Force quit" : @"⌘↩ Force quit"; i.kind = @"Process"; i.path = a.bundleURL.path;
        i.score = s;
        i.action = ^{ if (force) [a forceTerminate]; else [a terminate]; };
        i.altAction = ^{ [a forceTerminate]; };
        [r addObject:i];
    }
    return r;
}

- (NSArray<CItem *> *)clipItems:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    __weak CApp *ws = self;
    NSInteger n = 0;
    for (NSString *c in self.clips) {
        if (q.length && [c rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSString *one = [[c stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (one.length > 90) one = [[one substringToIndex:90] stringByAppendingString:@"…"];
        BOOL trusted = AXIsProcessTrusted();
        CItem *i = mk(one, [NSString stringWithFormat:@"%lu chars · %@", (unsigned long)c.length, trusted ? @"↩ Paste  ⌘↩ Copy only" : @"↩ Copy (grant Accessibility to auto-paste)"], @"Clipboard", @"doc.on.clipboard", ^{
            copyText(c);
            [ws hide];
            if (trusted && ws.previousApp) {
                [ws.previousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ simulatePaste(); });
            }
        });
        i.altAction = ^{ copyText(c); }; i.altHint = @"⌘↩ Copy";
        [r addObject:i];
        if (++n >= kMaxRows) break;
    }
    return r;
}

- (CItem *)webItem:(NSString *)q {
    NSString *tpl = self.config[@"webSearch"] ?: @"https://duckduckgo.com/?q=%s";
    NSString *url = [tpl stringByReplacingOccurrencesOfString:@"%s" withString:urlEncode(q)];
    CItem *i = mk([NSString stringWithFormat:@"Search the web for “%@”", q], nil, @"Web", @"magnifyingglass", ^{ openURLString(url); });
    i.score = -1000; return i;
}

- (CItem *)urlItem:(NSString *)q {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(https?://\\S+|www\\.\\S+|[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}(/\\S*)?)$" options:NSRegularExpressionCaseInsensitive error:nil];
    if (![re firstMatchInString:q options:0 range:NSMakeRange(0, q.length)]) return nil;
    NSString *url = [q hasPrefix:@"http"] ? q : [@"https://" stringByAppendingString:q];
    CItem *i = mk([@"Open " stringByAppendingString:q], url, @"URL", @"globe", ^{ openURLString(url); });
    i.score = 900; return i;
}

- (void)stopFileSearch {
    [self.fileDebounce invalidate]; self.fileDebounce = nil;
    if (self.fileQueryObserver) { [[NSNotificationCenter defaultCenter] removeObserver:self.fileQueryObserver]; self.fileQueryObserver = nil; }
    if (self.fileQuery) { [self.fileQuery stopQuery]; self.fileQuery = nil; }
}

// Spotlight file search in-process (NSMetadataQuery), debounced so fast typing issues one query instead of one per key.
- (void)startFileSearch:(NSString *)q onlyFiles:(BOOL)only {
    [self stopFileSearch];
    if (q.length < (only ? 1 : 3)) return;
    NSString *issued = q, *issuedQuery = self.currentQuery;
    __weak CApp *ws = self;
    self.fileDebounce = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:NO block:^(NSTimer *timer) {
        CApp *me = ws; if (!me) return;
        me.fileDebounce = nil;
        if (![me.currentQuery isEqualToString:issuedQuery] || !me.panel.visible) return;
        NSString *safe = [[issued stringByReplacingOccurrencesOfString:@"*" withString:@""] stringByReplacingOccurrencesOfString:@"?" withString:@""];
        if (!safe.length) return;
        NSMetadataQuery *mq = [NSMetadataQuery new];
        mq.searchScopes = @[NSHomeDirectory()];
        mq.predicate = [NSPredicate predicateWithFormat:@"%K LIKE[cd] %@", NSMetadataItemFSNameKey, [NSString stringWithFormat:@"*%@*", safe]];
        me.fileQuery = mq;
        me.fileQueryObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidFinishGatheringNotification object:mq
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            CApp *s = ws; if (!s || s.fileQuery != mq) return;
            [mq stopQuery];
            NSMutableArray<NSString *> *paths = [NSMutableArray new];
            NSUInteger n = MIN(mq.resultCount, (NSUInteger)400);
            for (NSUInteger k = 0; k < n && paths.count < 40; k++) {
                NSString *p = [[mq resultAtIndex:k] valueForAttribute:NSMetadataItemPathKey];
                if ([p isKindOfClass:[NSString class]] && p.length && ![p containsString:@"/Library/"]) [paths addObject:p];
            }
            [s stopFileSearch];
            if (![s.currentQuery isEqualToString:issuedQuery] || !s.panel.visible) return;
            NSMutableArray *files = [NSMutableArray new];
            for (NSString *line in paths) {
                NSString *name = line.lastPathComponent;
                double sc = fuzzyScore(issued, name); if (sc < 0) sc = 0;
                sc -= (double)[line componentsSeparatedByString:@"/"].count * 2; // prefer shallow
                CItem *i = [CItem new]; i.title = name; i.subtitle = [line.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath];
                i.kind = @"File"; i.path = line; i.score = sc - (only ? 0 : 60);
                i.action = ^{ [[NSWorkspace sharedWorkspace] openFile:line]; };
                i.altAction = ^{ [[NSWorkspace sharedWorkspace] selectFile:line inFileViewerRootedAtPath:@""]; };
                i.altHint = @"⌘↩ Reveal";
                [files addObject:i];
            }
            [files sortUsingComparator:^NSComparisonResult(CItem *x, CItem *y) { return x.score > y.score ? NSOrderedAscending : x.score < y.score ? NSOrderedDescending : NSOrderedSame; }];
            [s mergeFiles:files onlyFiles:only];
        }];
        if (![mq startQuery]) [me stopFileSearch];
    }];
}

- (void)mergeFiles:(NSArray<CItem *> *)files onlyFiles:(BOOL)only {
    NSMutableArray *all = [NSMutableArray new];
    if (only) {
        [all addObjectsFromArray:files];
        if (!all.count) [all addObject:mk(@"No files found", @"Spotlight indexing must be on for this folder", @"Files", @"doc", ^{})];
    }
    else {
        for (CItem *i in self.items) if (![i.kind isEqualToString:@"File"] && ![i.kind isEqualToString:@"Web"]) [all addObject:i];
        NSInteger room = MAX(0, 8 - (NSInteger)all.count); room = MIN(room, 4);
        NSInteger keep = MIN((NSInteger)files.count, MAX(room, 2));
        [all addObjectsFromArray:[files subarrayWithRange:NSMakeRange(0, keep)]];
        for (CItem *i in self.items) if ([i.kind isEqualToString:@"Web"]) [all addObject:i];
    }
    if (all.count > kMaxRows) all = [[all subarrayWithRange:NSMakeRange(0, kMaxRows)] mutableCopy];
    self.items = all; self.selected = MIN(self.selected, MAX(0, (NSInteger)all.count - 1));
    [self reloadTable];
}

#pragma mark Home (empty query)

- (NSArray<CItem *> *)mostUsedApps {
    NSMutableArray *out = [NSMutableArray new];
    // Most used: launch count via Centre first, then Dock order, then currently running apps.
    NSArray *dock = [self dockAppPaths];
    NSMutableSet *running = [NSMutableSet new];
    for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
        if (r.activationPolicy == NSApplicationActivationPolicyRegular && r.bundleURL.path) [running addObject:r.bundleURL.path];
    NSString *me = [NSBundle mainBundle].bundlePath;
    NSMutableDictionary<NSString *, NSNumber *> *rk = [NSMutableDictionary dictionaryWithCapacity:self.apps.count];
    for (CItem *a in self.apps) {
        if (!a.path.length) continue;
        double s = [self.usage[a.path][@"count"] doubleValue] * 1000;
        NSUInteger di = [dock indexOfObject:a.path]; if (di != NSNotFound) s += 500 - (double)di;
        if ([running containsObject:a.path]) s += 100;
        if ([a.path isEqualToString:me]) s = -1;
        rk[a.path] = @(s);
    }
    NSArray *sorted = [self.apps sortedArrayUsingComparator:^NSComparisonResult(CItem *a, CItem *b) {
        double x = a.path ? [rk[a.path] doubleValue] : 0, y = b.path ? [rk[b.path] doubleValue] : 0;
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : [a.title compare:b.title]; }];
    for (CItem *a in sorted) {
        if (out.count >= 8) break;
        if (![a.path hasPrefix:@"/"] || [rk[a.path] doubleValue] <= 0) continue;        // real apps with some signal only
        [out addObject:[self appItem:a score:0]];
    }
    return out;
}

- (NSArray<CItem *> *)quickActions {
    NSArray *order = @[@[@"Lock Screen", @"Lock"], @[@"Sleep", @"Sleep"], @[@"Toggle Dark Mode", @"Dark Mode"],
                       @[@"Generate Password", @"Password"], @[@"Show Desktop", @"Desktop"], @[@"Mute / Unmute", @"Mute"]];
    NSMutableDictionary *byTitle = [NSMutableDictionary new];
    for (CItem *c in [self systemCommands]) byTitle[c.title] = c;
    NSMutableArray *out = [NSMutableArray new];
    for (NSArray *o in order) { CItem *c = byTitle[o[0]]; if (!c) continue; c.title = o[1]; [out addObject:c]; }
    return out;
}

// Commands and quick links you ran, newest first (usage keys "cmd:<title>" and link URLs).
- (NSArray<CItem *> *)recentCommands:(NSInteger)limit exclude:(NSSet *)skip {
    NSMutableDictionary *byKey = [NSMutableDictionary new];
    for (CItem *c in [self systemCommands]) if (c.key) byKey[c.key] = c;
    NSMutableDictionary *links = [NSMutableDictionary new];
    for (NSDictionary *l in ([self.config[@"links"] isKindOfClass:[NSArray class]] ? self.config[@"links"] : @[]))
        if ([l isKindOfClass:[NSDictionary class]] && [l[@"url"] isKindOfClass:[NSString class]]) links[l[@"url"]] = l;
    NSMutableArray *keys = [NSMutableArray new];
    for (NSString *k in self.usage) if ((byKey[k] || links[k]) && ![skip containsObject:k]) [keys addObject:k];
    [keys sortUsingComparator:^NSComparisonResult(NSString *x, NSString *y) {
        double a = [self.usage[x][@"last"] doubleValue], b = [self.usage[y][@"last"] doubleValue];
        return a > b ? NSOrderedAscending : a < b ? NSOrderedDescending : NSOrderedSame; }];
    NSMutableArray *out = [NSMutableArray new];
    __weak CApp *ws = self;
    for (NSString *k in keys) {
        if ((NSInteger)out.count >= limit) break;
        CItem *i = byKey[k];
        if (!i) {
            NSString *url = k, *name = [links[k][@"name"] isKindOfClass:[NSString class]] ? links[k][@"name"] : url;
            i = mk(name, nil, @"Link", @"link", ^{ [ws recordUse:url]; openURLString(url); });
        }
        i.subtitle = nil;
        i.detail = shortAgo([self.usage[k][@"last"] doubleValue]);
        [out addObject:i];
    }
    return out;
}

// Files you opened anywhere on the Mac in the last two weeks (Spotlight's last-used date). Cached; refreshed on every show.
- (void)startRecentFilesQuery {
    if (self.recentQuery) return;
    NSMetadataQuery *mq = [NSMetadataQuery new];
    mq.searchScopes = @[NSHomeDirectory()];
    mq.predicate = [NSPredicate predicateWithFormat:@"kMDItemLastUsedDate >= %@", [NSDate dateWithTimeIntervalSinceNow:-14 * 86400]];
    mq.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"kMDItemLastUsedDate" ascending:NO]];
    self.recentQuery = mq;
    __weak CApp *ws = self;
    self.recentObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidFinishGatheringNotification object:mq
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        CApp *me = ws; if (!me) return;
        [mq stopQuery];
        if (me.recentObserver) [[NSNotificationCenter defaultCenter] removeObserver:me.recentObserver];
        me.recentObserver = nil; me.recentQuery = nil;
        NSMutableArray *out = [NSMutableArray new];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger n = MIN(mq.resultCount, (NSUInteger)300);
        for (NSUInteger k = 0; k < n && out.count < 6; k++) {
            NSMetadataItem *it = [mq resultAtIndex:k];
            NSString *p = [it valueForAttribute:NSMetadataItemPathKey];
            NSDate *d = [it valueForAttribute:@"kMDItemLastUsedDate"];
            NSString *ct = [it valueForAttribute:NSMetadataItemContentTypeKey];
            if (![p isKindOfClass:[NSString class]] || ![d isKindOfClass:[NSDate class]]) continue;
            if ([p containsString:@"/Library/"] || [p containsString:@"/."] || [p containsString:@".app/"] || [p hasSuffix:@".app"]) continue;
            if ([ct isEqual:@"public.folder"] || [ct isEqual:@"com.apple.application-bundle"]) continue;
            if (![fm fileExistsAtPath:p]) continue;
            [out addObject:@{@"path": p, @"date": d}];
        }
        BOOL changed = ![out isEqualToArray:me.recentFiles ?: @[]];
        me.recentFiles = out;
        if (changed && me.panel.visible && me.gridMode && !me.field.stringValue.length) {
            NSInteger keep = me.selected;
            [me refresh];
            if (keep < (NSInteger)me.items.count) [me homeSelect:keep];
        }
    }];
    if (![mq startQuery]) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.recentObserver];
        self.recentObserver = nil; self.recentQuery = nil;
    }
}

- (void)buildHome {
    BOOL extras = ![self.config[@"showHomeExtras"] isEqual:@NO];
    NSArray *apps = self.readmeApps ?: ([self.config[@"showMostUsed"] isEqual:@NO] ? @[] : [self mostUsedApps]);
    NSArray *quick = extras ? [self quickActions] : @[];
    NSMutableArray *entries = [NSMutableArray new], *rows = [NSMutableArray new];
    if (extras) {
        NSArray *clips = [self clipItems:@""];
        if (clips.count) {
            [entries addObject:@"Clipboard"];
            for (NSUInteger k = 0; k < MIN(clips.count, (NSUInteger)2); k++) {
                CItem *c = clips[k]; c.subtitle = nil;
                if (k < self.clips.count) c.detail = [NSString stringWithFormat:@"%lu chars", (unsigned long)self.clips[k].length];
                [entries addObject:c]; [rows addObject:c];
            }
        }
        NSMutableArray *files = [NSMutableArray new];
        for (NSDictionary *f in self.recentFiles) {
            if (files.count >= 3) break;
            NSString *p = f[@"path"];
            CItem *i = [CItem new]; i.title = p.lastPathComponent; i.subtitle = [p.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath];
            i.kind = @"File"; i.path = p; i.detail = shortAgo([f[@"date"] timeIntervalSince1970]);
            i.action = ^{ [[NSWorkspace sharedWorkspace] openFile:p]; };
            i.altAction = ^{ [[NSWorkspace sharedWorkspace] selectFile:p inFileViewerRootedAtPath:@""]; };
            i.altHint = @"⌘↩ Reveal";
            [files addObject:i];
        }
        if (files.count) { [entries addObject:@"Recent Files"]; [entries addObjectsFromArray:files]; [rows addObjectsFromArray:files]; }
        NSMutableSet *skip = [NSMutableSet new]; for (CItem *c in quick) if (c.key) [skip addObject:c.key];
        NSArray *cmds = [self recentCommands:2 exclude:skip];
        if (cmds.count) { [entries addObject:@"Recent Commands"]; [entries addObjectsFromArray:cmds]; [rows addObjectsFromArray:cmds]; }
    }
    NSMutableArray *all = [NSMutableArray arrayWithArray:apps];
    [all addObjectsFromArray:quick]; [all addObjectsFromArray:rows];
    self.homeApps = (NSInteger)apps.count; self.homeQuick = (NSInteger)quick.count; self.homeEntries = entries;
    self.gridMode = all.count > 0;
    self.items = all; self.selected = 0;
    [self reloadTable];
}

// Selection inside the home screen: apps row [0,a), quick actions [a,a+q), list rows [a+q,n).
- (void)syncHomeSelection {
    NSInteger s = self.selected, a = self.homeApps, q = self.homeQuick;
    self.grid.selected = s < a ? s : -1;
    self.quick.selected = (s >= a && s < a + q) ? s - a : -1;
    self.homeList.selected = s;
}
- (void)homeSelect:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.items.count) return;
    self.selected = i; [self syncHomeSelection]; [self layoutForRows:self.items.count];
}
- (void)homeMoveHorizontal:(NSInteger)d {
    NSInteger s = self.selected, a = self.homeApps, q = self.homeQuick;
    if (s < a) [self homeSelect:(s + d + a) % a];
    else if (s < a + q) [self homeSelect:a + (s - a + d + q) % q];
    else [self homeMoveVertical:d];                    // list rows: ←/→ act like ↑/↓
}
- (void)homeMoveVertical:(NSInteger)d {
    NSInteger s = self.selected, a = self.homeApps, q = self.homeQuick, n = (NSInteger)self.items.count, t;
    if (!n) return;
    if (d > 0) {
        if (s < a) t = q ? a : (a + q < n ? a + q : s);
        else if (s < a + q) t = a + q < n ? a + q : 0;
        else t = s + 1 < n ? s + 1 : 0;
    } else {
        if (s > a + q) t = s - 1;
        else if (s == a + q) t = q ? a : (a ? 0 : n - 1);
        else if (s >= a) t = a ? 0 : n - 1;
        else t = n - 1;                                // from the apps row, wrap to the bottom
    }
    [self homeSelect:t];
}

#pragma mark Query → items

- (void)refresh {
    NSString *q = [self.field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    self.currentQuery = q;
    self.modeLabel = nil;
    [self stopFileSearch];
    NSMutableArray *out = [NSMutableArray new];
    NSComparator byScore = ^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame; };

    if (!q.length) { [self buildHome]; return; }
    self.gridMode = NO;
    NSString *lower = q.lowercaseString;
    NSRange sp = [q rangeOfString:@" "];
    NSString *head = sp.location == NSNotFound ? lower : [lower substringToIndex:sp.location];
    NSString *rest = sp.location == NSNotFound ? @"" : [[q substringFromIndex:sp.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([head isEqualToString:@"kill"] || [head isEqualToString:@"quit"]) {
        self.modeLabel = [head isEqualToString:@"kill"] ? @"Force Quit" : @"Quit Apps";
        [out addObjectsFromArray:[self runningAppItems:rest force:[head isEqualToString:@"kill"]]];
        [out sortUsingComparator:byScore];
    } else if ([head isEqualToString:@"clip"] || [head isEqualToString:@"v"] || [head isEqualToString:@"paste"]) {
        self.modeLabel = @"Clipboard";
        [out addObjectsFromArray:[self clipItems:rest]];
        if (!out.count) [out addObject:mk(@"Clipboard history is empty", @"Copy something and it will appear here", @"Clipboard", @"doc.on.clipboard", ^{})];
    } else if ([head isEqualToString:@"f"] || [head isEqualToString:@"file"] || [head isEqualToString:@"find"]) {
        self.modeLabel = @"Files";
        [out addObject:mk([NSString stringWithFormat:@"Searching files for “%@”…", rest], nil, @"Files", @"doc", ^{})];
        [self startFileSearch:rest onlyFiles:YES];
    } else if ([q hasPrefix:@">"]) {
        self.modeLabel = @"Shell";
        NSString *cmd = [[q substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        CItem *i = mk([@"Run in Terminal: " stringByAppendingString:cmd], @"⌘↩ Run silently and copy output", @"Shell", @"terminal", ^{
            NSString *esc = [cmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]; esc = [esc stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            osa([NSString stringWithFormat:@"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell", esc]);
        });
        i.altAction = ^{ runShell(cmd, ^(NSString *o) { copyText(o); }); };
        [out addObject:i];
    } else if ([head isEqualToString:@"pw"] || [head isEqualToString:@"pwgen"] || ([head isEqualToString:@"password"] && rest.length)) {
        self.modeLabel = @"Password";
        [out addObjectsFromArray:[self passwordItems:rest]];
    } else if ([self.config[@"searchPrefixes"] isKindOfClass:[NSDictionary class]] && [self.config[@"searchPrefixes"][head] isKindOfClass:[NSString class]] && rest.length) {
        NSString *tpl = self.config[@"searchPrefixes"][head];
        NSString *host = [NSURL URLWithString:[tpl stringByReplacingOccurrencesOfString:@"%s" withString:@""]].host;
        if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
        self.modeLabel = host.length ? host : head;
        NSString *url = [tpl stringByReplacingOccurrencesOfString:@"%s" withString:urlEncode(rest)];
        [out addObject:mk([NSString stringWithFormat:@"Search %@ for “%@”", head, rest], url, @"Web", @"magnifyingglass", ^{ openURLString(url); })];
    } else {
        CItem *calc = [self calcItem:q]; if (calc) [out addObject:calc];
        CItem *url = [self urlItem:q]; if (url) [out addObject:url];
        NSMutableArray *general = [NSMutableArray new];
        [general addObjectsFromArray:[self appItemsFor:q]];
        [general addObjectsFromArray:[self linkItemsFor:q]];
        for (CItem *c in [self systemCommands]) { double s = fuzzyScore(q, c.title); if (s >= 0) { c.score = s - 8; [general addObject:c]; } }
        [general sortUsingComparator:byScore];
        NSInteger cap = calc ? 5 : 7;
        if (general.count > (NSUInteger)cap) general = [[general subarrayWithRange:NSMakeRange(0, cap)] mutableCopy];
        [out addObjectsFromArray:general];
        if (q.length >= 3) { NSArray *cl = [self clipItems:q]; if (cl.count) [out addObject:cl.firstObject]; }
        if (!calc) [out addObject:[self webItem:q]];
        if (!calc && !url && ![self.config[@"fileResults"] isEqual:@NO]) [self startFileSearch:q onlyFiles:NO];
    }
    if (out.count > kMaxRows) out = [[out subarrayWithRange:NSMakeRange(0, kMaxRows)] mutableCopy];
    self.items = out; self.selected = 0; [self reloadTable];
}

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
    si.contentTintColor = [NSColor tertiaryLabelColor]; si.imageScaling = NSImageScaleProportionallyUpOrDown;
    [fx addSubview:si]; self.searchIcon = si;

    CField *t = [[CField alloc] initWithFrame:NSMakeRect(54, 0, kW - 54 - 22, 28)];
    t.font = [NSFont systemFontOfSize:20 weight:NSFontWeightRegular];
    t.bezeled = NO; t.bordered = NO; t.drawsBackground = NO; t.focusRingType = NSFocusRingTypeNone;
    t.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Search apps, commands and files…" attributes:@{NSFontAttributeName: t.font, NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]}];
    t.delegate = self;
    [fx addSubview:t]; self.field = t;
    CChip *chip = [[CChip alloc] initWithFrame:NSZeroRect]; chip.hidden = YES;
    [fx addSubview:chip]; self.chip = chip;

    NSTextField *esc = [NSTextField labelWithString:@""]; esc.hidden = YES;   // kept for layout compatibility
    [fx addSubview:esc]; self.escPill = esc;

    CHairline *sep = [[CHairline alloc] initWithFrame:NSMakeRect(0, 0, kW, 1)];
    [fx addSubview:sep]; self.separator = sep;

    NSTextField *gt = [NSTextField labelWithString:@"Most Used"];
    gt.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]; gt.textColor = [NSColor secondaryLabelColor];
    [fx addSubview:gt]; self.gridTitle = gt;
    CGridView *grid = [[CGridView alloc] initWithFrame:NSMakeRect(0, 0, kW, kCellH)];
    __weak CApp *ws = self;
    grid.iconFor = ^NSImage *(CItem *i) { return [ws iconFor:i]; };
    grid.onPick = ^(NSInteger i) { ws.selected = i; [ws runSelected:NO]; };
    grid.onHover = ^(NSInteger i) { [ws hoverSelect:i]; };
    [fx addSubview:grid]; self.grid = grid;

    CQuickStrip *qs = [[CQuickStrip alloc] initWithFrame:NSMakeRect(0, 0, kW, kQuickH)]; qs.selected = -1;
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
    fi.frame = NSMakeRect(18, floor((kFooterH - 18) / 2), 18, 18); fi.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSTextField *fL = [NSTextField labelWithString:@"Centre"];
    fL.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; fL.textColor = [NSColor secondaryLabelColor];
    fL.frame = NSMakeRect(42, floor((kFooterH - 16) / 2), 200, 16);
    NSTextField *fR = [NSTextField labelWithString:@""]; fR.hidden = YES;
    CKeyHints *hints = [[CKeyHints alloc] initWithFrame:NSMakeRect(kW - 18 - 480, 0, 480, kFooterH - 1)];
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
        if (e.keyCode == 53) { [self hide]; return nil; }
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
    CGFloat bodyH = mediaH + (home ? appsH + quickH + listH : (rows > 0 ? rows * kRowH + 12 : 0));
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
            self.gridTitle.frame = NSMakeRect(kGridX + 6, y - 28, 200, 15);
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
                             @"Shell": @"Run", @"System Settings": @"Open Settings", @"Media": @"Control Playback", @"Password": @"Copy Password" };
    NSString *verb = sel ? (verbs[sel.kind ?: @""] ?: @"Run Command") : @"Open";
    NSMutableArray *h = [NSMutableArray arrayWithObject:@[verb, @"↩"]];
    if (sel.altAction && sel.altAction != sel.action) {
        NSString *alt = sel.altHint.length ? [[sel.altHint stringByReplacingOccurrencesOfString:@"⌘↩" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"Alternate";
        [h addObject:@[alt, @"⌘", @"↩"]];
    }
    if (showMedia) [h addObject:@[@"Play/Pause", @"⌘", @"P"]];
    [h addObject:@[@"Settings", @"⌘", @","]];
    self.hints.hints = h;
}

// Pointer moved onto a row / grid cell: it becomes the selection (Enter, footer hints and ⌘↩ follow it).
- (void)hoverSelect:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.items.count || i == self.selected) return;
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
    self.cmdHeld = NO;
    if ([NSDate date].timeIntervalSince1970 - self.lastScan > 120) [self scanApps];
    [self positionPanel];
    self.field.stringValue = @"";
    [self refresh];
    [self startRecentFilesQuery];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.field];
    [self refreshNowPlaying];
    [self.mediaTimer invalidate];
    __weak CApp *ws = self;
    self.mediaTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        if ([ws ytmMode]) [ws refreshYTM]; else if (!ws.media.hidden) [ws updateMediaView]; }];
}
- (void)hide { [self.panel orderOut:nil]; [self stopFileSearch]; [self.mediaTimer invalidate]; self.mediaTimer = nil; }


#pragma mark YouTube Music (targets the YTM tab in a Chromium browser via AppleScript + page JavaScript)
static NSString *const kYTMStatusJS = @"(()=>{const b=document.querySelector('ytmusic-player-bar');const v=document.querySelector('video');if(!b||!v||!v.src)return 'EMPTY';const q=s=>{const e=b.querySelector(s);return e?e.textContent.trim():''};const i=b.querySelector('img.image');return JSON.stringify({t:q('.title'),a:q('.byline').split('•')[0].trim(),art:i?i.src:'',p:!v.paused,c:v.currentTime||0,d:v.duration||0})})()";
static NSString *const kYTMToggleJS = @"(()=>{const v=document.querySelector('video');const b=document.querySelector('#play-pause-button');if(!v||!v.src||!b)return 'EMPTY';b.click();return 'OK'})()";
static NSString *const kYTMNextJS = @"(()=>{const b=document.querySelector('ytmusic-player-bar .next-button');if(!b)return 'EMPTY';b.click();return 'OK'})()";
static NSString *const kYTMPrevJS = @"(()=>{const b=document.querySelector('ytmusic-player-bar .previous-button');if(!b)return 'EMPTY';b.click();return 'OK'})()";
static NSString *const kYTMEnsurePlayJS = @"(()=>{const v=document.querySelector('video');const b=document.querySelector('#play-pause-button');if(v&&v.src&&v.paused&&b)b.click();return 'OK'})()";
static NSString *const kYTMStartURL = @"https://music.youtube.com/watch?list=LM";
static NSString *const kYTMRecentURL = @"https://music.youtube.com/history";
// On the history page: once a track is loaded make sure it plays; before that, press play on the most recent song.
static NSString *const kYTMRecentKickJS = @"(()=>{const v=document.querySelector('video');if(v&&v.src){if(v.paused){const p=document.querySelector('#play-pause-button');if(p)p.click()}return 'OK'}const b=document.querySelector('ytmusic-responsive-list-item-renderer ytmusic-play-button-renderer');if(b){b.click();return 'CLICKED'}return 'WAIT'})()";

- (BOOL)ytmMode { return [self.config[@"mediaYTM"] boolValue]; }
// The browser that hosts YouTube Music: the one set in Settings if it's still installed, otherwise the Mac's default browser.
- (NSString *)ytmBrowser {
    NSString *b = self.config[@"ytmBrowser"];
    if ([b isKindOfClass:[NSString class]] && b.length && [[NSWorkspace sharedWorkspace] fullPathForApplication:b]) return b;
    return defaultBrowserName();
}

- (NSString *)ytmScript:(NSString *)js {
    NSString *app = [self ytmBrowser];
    return [NSString stringWithFormat:
        @"if application \"%@\" is not running then return \"NOTRUNNING\"\n"
         "tell application \"%@\"\n"
         "repeat with w in windows\n repeat with t in tabs of w\n  if URL of t contains \"music.youtube.com\" then return (execute t javascript \"%@\")\n end repeat\nend repeat\n"
         "return \"NOTAB\"\nend tell", app, app, js];
}

- (NSString *)ytmProblem:(NSString *)o {
    if ([o containsString:@"JavaScript"]) return [NSString stringWithFormat:@"In %@: View › Developer › Allow JavaScript from Apple Events", [self ytmBrowser]];
    if ([o containsString:@"-1743"] || [o containsString:@"Not authorized"]) return @"Allow Centre in System Settings › Privacy & Security › Automation";
    if ([o containsString:@"-1728"] || [o containsString:@"execute"]) return [NSString stringWithFormat:@"%@ doesn't support scripting", [self ytmBrowser]];
    return nil;
}

- (void)refreshYTM {
    if (self.ytmBusy) return;
    self.ytmBusy = YES;
    __weak CApp *ws = self;
    runOsa([self ytmScript:kYTMStatusJS], ^(NSString *o) {
        ws.ytmBusy = NO;
        BOOL had = ws.hasNow;
        ws.hasNow = YES;
        ws.nowApp = @"YouTube Music";
        if (!ws.nowAppIcon) {
            NSString *p = [[NSWorkspace sharedWorkspace] fullPathForApplication:[ws ytmBrowser]];
            if (p) ws.nowAppIcon = [[NSWorkspace sharedWorkspace] iconForFile:p];
        }
        NSDictionary *d = [o hasPrefix:@"{"] ? [NSJSONSerialization JSONObjectWithData:[o dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([d isKindOfClass:[NSDictionary class]]) {
            ws.nowTitle = [d[@"t"] description] ?: @"";
            ws.nowArtist = [d[@"a"] description] ?: @"";
            ws.isPlaying = [d[@"p"] boolValue];
            ws.nowElapsed = [d[@"c"] doubleValue]; ws.nowDuration = [d[@"d"] doubleValue];
            ws.nowStamp = [NSDate date]; ws.nowRate = ws.isPlaying ? 1 : 0;
            NSString *art = [d[@"art"] description] ?: @"";
            if (art.length && ![art isEqualToString:ws.ytmArtURL]) {
                ws.ytmArtURL = art;
                NSString *big = [[NSRegularExpression regularExpressionWithPattern:@"=w\\d+-h\\d+" options:0 error:nil]
                                 stringByReplacingMatchesInString:art options:0 range:NSMakeRange(0, art.length) withTemplate:@"=w240-h240"];
                NSURL *u = [NSURL URLWithString:big];
                if (u) [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                    NSImage *img = data ? [[NSImage alloc] initWithData:data] : nil;
                    if (img) dispatch_async(dispatch_get_main_queue(), ^{ if ([art isEqualToString:ws.ytmArtURL]) { ws.nowArt = img; [ws updateMediaView]; } });
                }] resume];
            }
        } else {
            NSString *problem = [ws ytmProblem:o];
            ws.nowTitle = @"YouTube Music";
            ws.nowArtist = problem ?: @"Press play to start your Liked Music";
            ws.isPlaying = NO; ws.nowDuration = 0; ws.nowArt = nil; ws.ytmArtURL = nil;
        }
        [ws updateMediaView];
        if (had != ws.hasNow && ws.panel.visible && ws.field.stringValue.length == 0) [ws reloadTable];
    });
}

- (void)ytmStart { [self ytmStartURL:kYTMStartURL kick:kYTMEnsurePlayJS label:@"Starting your Liked Music…"]; }
- (void)ytmPlayRecent { [self ytmStartURL:kYTMRecentURL kick:kYTMRecentKickJS label:@"Starting your recently played music…"]; }

- (void)ytmStartURL:(NSString *)startURL kick:(NSString *)kickJS label:(NSString *)label {
    // Chromium defers media in tabs that have never been shown, so the tab is brought forward inside its
    // window (the browser itself stays in the background) until playback starts, then the previous tab returns.
    NSString *app = [self ytmBrowser];
    NSString *script = [NSString stringWithFormat:
        @"tell application \"%@\"\n"
         "set found to false\nset winId to 0\nset prevIdx to 0\nset tabIdx to 0\n"
         "repeat with w in windows\n set i to 0\n repeat with t in tabs of w\n  set i to i + 1\n"
         "  if URL of t contains \"music.youtube.com\" then\n   set URL of t to \"%@\"\n   set winId to id of w\n   set prevIdx to active tab index of w\n   set tabIdx to i\n   set found to true\n   exit repeat\n  end if\n end repeat\n if found then exit repeat\nend repeat\n"
         "if not found then\n if (count of windows) = 0 then make new window\n set w to window 1\n set winId to id of w\n set prevIdx to active tab index of w\n"
         " make new tab at end of tabs of w with properties {URL:\"%@\"}\n set tabIdx to count of tabs of w\nend if\n"
         "set active tab index of (window id winId) to tabIdx\n"
         "return (winId as text) & \"|\" & (prevIdx as text) & \"|\" & (tabIdx as text)\nend tell", app, startURL, startURL];
    __weak CApp *ws = self;
    self.nowTitle = @"YouTube Music"; self.nowArtist = label; [self updateMediaView];
    runOsa(script, ^(NSString *o) {
        NSString *problem = [ws ytmProblem:o];
        if (problem) { ws.nowArtist = problem; [ws updateMediaView]; return; }
        NSArray *parts = [o componentsSeparatedByString:@"|"];
        if (parts.count != 3) { [ws refreshYTM]; return; }
        [ws ytmWaitForPlayback:0 window:parts[0] previous:[parts[1] integerValue] tab:[parts[2] integerValue] kick:kickJS];
    });
}

- (void)ytmWaitForPlayback:(NSInteger)attempt window:(NSString *)winId previous:(NSInteger)prev tab:(NSInteger)tab kick:(NSString *)kickJS {
    __weak CApp *ws = self;
    NSString *app = [self ytmBrowser];
    runOsa([self ytmScript:kYTMStatusJS], ^(NSString *o) {
        NSDictionary *d = [o hasPrefix:@"{"] ? [NSJSONSerialization JSONObjectWithData:[o dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        BOOL playing = [d isKindOfClass:[NSDictionary class]] && [d[@"p"] boolValue];
        if (playing) {
            if (prev > 0 && prev != tab)
                runOsa([NSString stringWithFormat:@"tell application \"%@\" to set active tab index of (window id %@) to %ld", app, winId, (long)prev], nil);
            [ws refreshYTM];
            return;
        }
        if (attempt >= 20) {   // ~20 s: leave the tab showing so the user can press play there
            ws.nowArtist = [NSString stringWithFormat:@"Couldn't start automatically — press play in %@", app];
            [ws updateMediaView];
            return;
        }
        if (attempt >= 2 && attempt % 3 == 2) runOsa([ws ytmScript:kickJS], nil);   // page loaded but waiting for a play gesture
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws ytmWaitForPlayback:attempt + 1 window:winId previous:prev tab:tab kick:kickJS];
        });
    });
}

- (void)ytmCommand:(int)cmd {
    NSString *js = cmd == 4 ? kYTMNextJS : cmd == 5 ? kYTMPrevJS : kYTMToggleJS;
    __weak CApp *ws = self;
    if (cmd == 2 && self.nowDuration > 0) { self.nowElapsed = [self currentElapsed]; self.nowStamp = [NSDate date]; self.isPlaying = !self.isPlaying; self.nowRate = self.isPlaying ? 1 : 0; [self updateMediaView]; }
    runOsa([self ytmScript:js], ^(NSString *o) {
        if ([o isEqualToString:@"NOTRUNNING"] || [o isEqualToString:@"NOTAB"] || ([o isEqualToString:@"EMPTY"] && cmd == 2)) { [ws ytmStart]; return; }
        NSString *problem = [ws ytmProblem:o];
        if (problem) { ws.nowArtist = problem; [ws updateMediaView]; return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshYTM]; });
    });
}

#pragma mark Now Playing
- (void)startMediaObservers {
    loadMediaRemote();
    if (MRRegister) MRRegister(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"])
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshNowPlaying) name:n object:nil];
}
- (void)refreshNowPlaying {
    if ([self ytmMode]) { if (self.panel.visible) [self refreshYTM]; return; }
    loadMediaRemote();
    if (!MRGetInfo) return;
    __weak CApp *ws = self;
    MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *d = (__bridge NSDictionary *)info;
        NSString *title = [d[@"kMRMediaRemoteNowPlayingInfoTitle"] isKindOfClass:[NSString class]] ? d[@"kMRMediaRemoteNowPlayingInfoTitle"] : @"";
        BOOL had = ws.hasNow;
        BOOL sameTrack = [title isEqualToString:ws.nowTitle ?: @""];
        ws.hasNow = title.length > 0;
        ws.nowTitle = title;
        ws.nowArtist = [d[@"kMRMediaRemoteNowPlayingInfoArtist"] isKindOfClass:[NSString class]] ? d[@"kMRMediaRemoteNowPlayingInfoArtist"] : @"";
        NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        NSImage *img = [art isKindOfClass:[NSData class]] ? [[NSImage alloc] initWithData:art] : nil;
        // Browsers briefly publish info without artwork on play/pause — keep the last artwork for the same track.
        if (img || !sameTrack) ws.nowArt = img;
        ws.nowDuration = [d[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        ws.nowElapsed = [d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        ws.nowStamp = [d[@"kMRMediaRemoteNowPlayingInfoTimestamp"] isKindOfClass:[NSDate class]] ? d[@"kMRMediaRemoteNowPlayingInfoTimestamp"] : [NSDate date];
        ws.nowRate = [d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
        ws.isPlaying = ws.nowRate > 0;
        if (MRGetPID) MRGetPID(dispatch_get_main_queue(), ^(int pid) {
            NSRunningApplication *ra = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
            ws.nowApp = ra.localizedName ?: @""; ws.nowAppIcon = ra.icon; [ws updateMediaView]; });
        if (MRIsPlaying) MRIsPlaying(dispatch_get_main_queue(), ^(Boolean p) { ws.isPlaying = p; [ws updateMediaView]; });
        [ws updateMediaView];
        if (had != ws.hasNow && ws.panel.visible && ws.field.stringValue.length == 0) [ws reloadTable];
    });
}
- (void)updateMediaView {
    CMediaView *m = self.media; if (!m) return;
    m.titleL.stringValue = self.nowTitle ?: @"";
    NSString *sub = self.nowArtist ?: @"";
    if (self.nowApp.length) sub = sub.length ? [NSString stringWithFormat:@"%@  ·  %@", sub, self.nowApp] : self.nowApp;
    m.subL.stringValue = sub;
    m.art.image = self.nowArt ?: (self.nowAppIcon ?: [NSApp applicationIconImage]);
    [m setPlaying:self.isPlaying];
    [m setElapsed:[self currentElapsed] duration:self.nowDuration];
    [m setNeedsDisplay:YES];
}
- (double)currentElapsed {
    double el = self.nowElapsed;
    if (self.isPlaying && self.nowStamp) el += -[self.nowStamp timeIntervalSinceNow] * (self.nowRate > 0 ? self.nowRate : 1);
    return self.nowDuration > 0 ? MIN(MAX(el, 0), self.nowDuration) : MAX(el, 0);
}
// Jump to a point in the track (click or drag on the progress bar).
- (void)mediaSeek:(double)fraction {
    if (self.nowDuration <= 0) return;
    double t = MAX(0, MIN(self.nowDuration - 0.5, fraction * self.nowDuration));
    self.nowElapsed = t; self.nowStamp = [NSDate date]; [self updateMediaView];
    __weak CApp *ws = self;
    if ([self ytmMode]) {
        runOsa([self ytmScript:[NSString stringWithFormat:@"(()=>{const v=document.querySelector('video');if(!v)return 'EMPTY';v.currentTime=%.2f;return 'OK'})()", t]], ^(NSString *o) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshYTM]; }); });
        return;
    }
    loadMediaRemote();
    if (MRSetElapsed) MRSetElapsed(t);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshNowPlaying]; });
}
- (void)mediaCommand:(int)cmd {   // 2 toggle, 4 next, 5 previous
    if ([self ytmMode]) { [self ytmCommand:cmd]; return; }
    loadMediaRemote();
    BOOL sent = MRSend ? MRSend(cmd, NULL) : NO;
    if (!sent) postMediaKey(cmd == 4 ? 17 : cmd == 5 ? 18 : 16);
    if (cmd == 2) { self.nowElapsed = [self currentElapsed]; self.nowStamp = [NSDate date]; self.isPlaying = !self.isPlaying; [self updateMediaView]; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refreshNowPlaying]; });
}
- (void)toggle { if (self.panel.visible && self.panel.keyWindow) [self hide]; else [self show]; }

- (void)windowDidResignKey:(NSNotification *)n { if (self.panel.visible) [self hide]; }

- (void)runSelected:(BOOL)alt {
    if (self.selected < 0 || self.selected >= (NSInteger)self.items.count) return;
    CItem *i = self.items[self.selected];
    if (i.key.length) [self recordUse:i.key];          // feeds Recent Commands
    CAction a = alt ? (i.altAction ?: i.action) : i.action;
    [self hide];
    if (a) a();
}

- (void)rowClicked:(id)s { NSInteger r = self.table.clickedRow; if (r >= 0) { self.selected = r; [self runSelected:NO]; } }

- (void)moveSelection:(NSInteger)d {
    if (!self.items.count) return;
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

#pragma mark NSTextField delegate
- (void)controlTextDidChange:(NSNotification *)n { [self refresh]; }
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (self.gridMode) {
        if (sel == @selector(moveDown:)) { [self homeMoveVertical:1]; return YES; }
        if (sel == @selector(moveUp:)) { [self homeMoveVertical:-1]; return YES; }
        if (sel == @selector(moveRight:)) { [self homeMoveHorizontal:1]; return YES; }
        if (sel == @selector(moveLeft:)) { [self homeMoveHorizontal:-1]; return YES; }
    }
    if (sel == @selector(moveDown:)) { [self moveSelection:1]; return YES; }
    if (sel == @selector(moveUp:)) { [self moveSelection:-1]; return YES; }
    if (sel == @selector(insertNewline:)) { [self runSelected:NO]; return YES; }
    if (sel == @selector(cancelOperation:) || sel == @selector(complete:)) { [self hide]; return YES; }
    if (sel == @selector(insertTab:)) {
        if (self.selected < (NSInteger)self.items.count) { CItem *i = self.items[self.selected];
            if ([i.kind isEqualToString:@"Application"] || [i.kind isEqualToString:@"Recent"]) { self.field.stringValue = i.title; [tv setSelectedRange:NSMakeRange(i.title.length, 0)]; [self refresh]; } }
        return YES;
    }
    return NO;
}

#pragma mark Table
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return self.items.count; }
- (BOOL)selectionShouldChangeInTableView:(NSTableView *)t { return NO; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    CRowView *v = [t makeViewWithIdentifier:@"row" owner:self];
    if (!v) { v = [[CRowView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)]; v.identifier = @"row"; }
    CItem *i = self.items[row];
    [v setTitle:i.title subtitle:i.subtitle];
    NSImage *img = [self iconFor:i];
    v.iconView.image = img;
    v.iconView.contentTintColor = img.template ? [NSColor secondaryLabelColor] : nil;
    v.selected = (row == self.selected);
    [v setKind:(i.detail ?: i.kind) shortcut:(self.cmdHeld && row < 9) ? [NSString stringWithFormat:@"\u2318%ld", (long)row + 1] : nil];
    [v setNeedsDisplay:YES]; [v setNeedsLayout:YES];
    return v;
}

#pragma mark Clipboard monitor
- (void)pollClipboard {
    if ([self.config[@"clipboardHistory"] isEqual:@NO]) { if (self.clips.count) [self.clips removeAllObjects]; return; }
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    if (pb.changeCount == self.pbCount) return;
    self.pbCount = pb.changeCount;
    if ([pb.types containsObject:@"org.nspasteboard.ConcealedType"] || [pb.types containsObject:@"org.nspasteboard.TransientType"]) return;
    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (!s.length || s.length > 20000) return;
    if ([[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) return;
    [self.clips removeObject:s]; [self.clips insertObject:s atIndex:0];
    while (self.clips.count > 100) [self.clips removeLastObject];
}

#pragma mark Hotkey
static OSStatus hotKeyHandler(EventHandlerCallRef next, EventRef evt, void *ud) {
    CApp *app = (__bridge CApp *)ud;
    EventHotKeyID hk; hk.signature = 0; hk.id = 1;
    GetEventParameter(evt, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
    UInt32 which = hk.id;
    if (which == 1) dispatch_async(dispatch_get_main_queue(), ^{ [app toggle]; });
    return noErr;
}
- (void)registerHotKey {
    static BOOL installed = NO;
    if (!installed) {
        EventTypeSpec spec; spec.eventClass = kEventClassKeyboard; spec.eventKind = kEventHotKeyPressed;
        InstallApplicationEventHandler(&hotKeyHandler, 1, &spec, (__bridge void *)self, NULL);
        installed = YES;
    }
    if (self.hotKeyRef) { UnregisterEventHotKey(self.hotKeyRef); self.hotKeyRef = NULL; }
    NSString *spec = [(self.config[@"hotkey"] ?: @"cmd+space") lowercaseString];
    UInt32 mods = 0; UInt32 key = kVK_Space;
    NSDictionary *keys = hotkeyKeyMap();
    for (NSString *part in [spec componentsSeparatedByString:@"+"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t isEqualToString:@"cmd"] || [t isEqualToString:@"command"]) mods |= cmdKey;
        else if ([t isEqualToString:@"alt"] || [t isEqualToString:@"option"] || [t isEqualToString:@"opt"]) mods |= optionKey;
        else if ([t isEqualToString:@"ctrl"] || [t isEqualToString:@"control"]) mods |= controlKey;
        else if ([t isEqualToString:@"shift"]) mods |= shiftKey;
        else if (keys[t]) key = [keys[t] unsignedIntValue];
    }
    EventHotKeyID hkid; hkid.signature = 'CNTR'; hkid.id = 1;
    EventHotKeyRef ref = NULL;
    OSStatus st = RegisterEventHotKey(key, mods, hkid, GetApplicationEventTarget(), 0, &ref);
    if (st == noErr) self.hotKeyRef = ref;
    else NSLog(@"Centre: could not register hotkey %@ (err %d) — is Spotlight's shortcut still bound?", spec, (int)st);
    [self updateStatusMenu];
}

- (void)unregisterHotKey {
    if (self.hotKeyRef) { UnregisterEventHotKey(self.hotKeyRef); self.hotKeyRef = NULL; }
}

#pragma mark Status item / login item
// Menu-bar icon is opt-in (Settings › General › "Show in menu bar"); hidden by default.
- (void)updateStatusItem {
    BOOL want = [self.config[@"showMenuBarIcon"] boolValue];
    if (want && !self.status) {
        self.status = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        NSImage *si = symbolImage(@"circle.circle"); si.template = YES;
        self.status.button.image = si;
        [self updateStatusMenu];
    } else if (!want && self.status) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.status];
        self.status = nil;
    }
}
- (void)updateStatusMenu {
    NSMenu *m = [NSMenu new];
    NSString *hk = prettyHotkey(self.config[@"hotkey"] ?: @"cmd+space");
    [m addItemWithTitle:[NSString stringWithFormat:@"Open Centre  (%@)", hk] action:@selector(show) keyEquivalent:@""].target = self;
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Settings…" action:@selector(openSettings) keyEquivalent:@","].target = self;
    [m addItemWithTitle:@"Rescan Apps" action:@selector(scanApps) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Grant Accessibility (window commands, auto-paste)" action:@selector(grantAX) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Start at Login (toggle)" action:@selector(toggleLoginItem) keyEquivalent:@""].target = self;
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Quit Centre" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    self.status.menu = m;
}
- (void)openConfigFile {
    // Always a text editor: config "editor" app name → Zed → TextEdit. Never the browser that owns .json.
    NSString *ed = [self.config[@"editor"] isKindOfClass:[NSString class]] ? self.config[@"editor"] : @"Zed";
    runShell([NSString stringWithFormat:@"open -a '%@' '%@' 2>/dev/null || open -e '%@'", ed, self.configPath, self.configPath], nil);
}

#pragma mark Settings
- (void)openSettings {
    [self hide];
    if (!self.settings) self.settings = [[CSettings alloc] initWithApp:self];
    [self.settings show];
}
- (void)writeConfig:(NSDictionary *)c {
    NSData *d = [NSJSONSerialization dataWithJSONObject:c options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!d) return;
    id oldFolders = self.config[@"appFolders"];
    [d writeToFile:self.configPath atomically:YES];
    self.configMtime = nil; [self loadConfig];
    [self registerHotKey];
    [self updateStatusItem];
    if (![oldFolders isEqual:self.config[@"appFolders"]]) [self scanApps];
}
- (void)setLaunchAtLogin:(BOOL)on {
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    NSString *s = on
        ? [NSString stringWithFormat:@"tell application \"System Events\"\nif not (exists login item \"Centre\") then make login item at end with properties {path:\"%@\", hidden:true}\nend tell", bundle]
        : @"tell application \"System Events\"\nif exists login item \"Centre\" then delete login item \"Centre\"\nend tell";
    osa(s);
}
- (void)resetUsage { self.usage = [NSMutableDictionary new]; [[NSFileManager defaultManager] removeItemAtPath:self.usagePath error:nil]; }
- (void)grantAX { NSDictionary *o = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES}; AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o); }
- (void)toggleLoginItem {
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    NSString *script = [NSString stringWithFormat:
        @"tell application \"System Events\"\n"
         "if exists login item \"Centre\" then\n delete login item \"Centre\"\n return \"removed\"\n"
         "else\n make login item at end with properties {path:\"%@\", hidden:false}\n return \"added\"\nend if\nend tell", bundle];
    osa(script);
}

#pragma mark Self-rebuild
- (NSString *)sourceDir { return [[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent]; }
- (BOOL)sourceIsNewer {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [self.sourceDir stringByAppendingPathComponent:@"Centre.m"];
    NSDate *s = [[fm attributesOfItemAtPath:src error:nil] fileModificationDate];
    NSDate *b = [[fm attributesOfItemAtPath:[NSBundle mainBundle].executablePath error:nil] fileModificationDate];
    return s && b && [s compare:b] == NSOrderedDescending;
}
- (NSDate *)sourceDate {
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:[self.sourceDir stringByAppendingPathComponent:@"Centre.m"] error:nil] fileModificationDate];
}
- (void)rebuild { [self rebuildQuietly:NO]; }
// quiet = triggered by the file watcher: a failed build is logged to build.log and retried on the next save, no alert.
- (void)rebuildQuietly:(BOOL)quiet {
    NSString *dir = self.sourceDir;
    if (self.rebuilding || ![[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"centre"]]) return;
    self.rebuilding = YES;
    NSDate *src = [self sourceDate];
    runShell([NSString stringWithFormat:@"cd '%@' && chmod +x centre && CENTRE_NO_LAUNCH=1 ./centre build 2>&1", dir], ^(NSString *out) {
        if ([out containsString:@"Built "] && ![out containsString:@"error:"]) {
            // Success: hand over to the fresh binary. The helper outlives us, waits, then opens the new build.
            NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh";
            t.arguments = @[@"-c", [NSString stringWithFormat:@"sleep 1; open '%@'", [NSBundle mainBundle].bundlePath]];
            [t launch];
            [NSApp terminate:nil];
            return;
        }
        self.rebuilding = NO; self.failedSource = src;
        if (quiet) return;
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *al = [NSAlert new]; al.messageText = @"Centre could not rebuild";
        al.informativeText = out.length > 3000 ? [out substringFromIndex:out.length - 3000] : out;
        [al runModal];
    });
}

#pragma mark Lifecycle
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
    }
}
- (void)runSnapshots {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    self.iconCache = [NSMutableDictionary new]; self.clips = [NSMutableArray new]; self.items = @[];
    [self loadUsage]; [self loadConfig];
    [self buildUI];
    [self scanApps];
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

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (self.snapshotDir) { [self runSnapshots]; return; }
    if ([self sourceIsNewer]) { [self rebuild]; return; }
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.y.centre.show" object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { [self show]; }];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.iconCache = [NSMutableDictionary new]; self.clips = [NSMutableArray new]; self.items = @[];
    self.pbCount = [NSPasteboard generalPasteboard].changeCount;
    [self loadUsage]; [self loadConfig];
    [self buildUI];
    [self startMediaObservers];
    [self registerHotKey];
    [self updateStatusItem];
    [self scanApps];
    [self startRecentFilesQuery];
    [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(pollClipboard) userInfo:nil repeats:YES];
    // Auto-rebuild: when Centre.m changes on disk, recompile and relaunch (only while the panel is hidden).
    [NSTimer scheduledTimerWithTimeInterval:4 repeats:YES block:^(NSTimer *t) {
        if (self.rebuilding || self.panel.visible || self.settings.window.visible || ![self sourceIsNewer]) return;
        NSDate *src = [self sourceDate];
        if (self.failedSource && src && [src isEqualToDate:self.failedSource]) return;   // same broken source: wait for the next save
        [self rebuildQuietly:YES];
    }];
    // Manual launch → show. A relaunch right after a rebuild stays hidden until the hotkey.
    NSDate *built = [[[NSFileManager defaultManager] attributesOfItemAtPath:[NSBundle mainBundle].executablePath error:nil] fileModificationDate];
    if (!built || -[built timeIntervalSinceNow] > 90) [self show];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)a hasVisibleWindows:(BOOL)f { [self show]; return NO; }
- (void)applicationWillTerminate:(NSNotification *)n { if (self.hotKeyRef) UnregisterEventHotKey(self.hotKeyRef); }
@end


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
@property (nonatomic) BOOL axShown;   // Accessibility state the General page was built with
@end

static NSArray *settingsPages(void) {
    return @[@[@"General", @"gearshape.fill", @"System"], @[@"Search", @"magnifyingglass", @"Web"],
             @[@"Quick Links", @"link", @"Link"], @[@"Advanced", @"wrench.and.screwdriver.fill", @"Centre"]];
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
    login.action = @selector(loginChanged:);

    [self addHeader:@"Launcher" note:nil];
    [self addFull:setCard(@[setRow(@"Keyboard shortcut", @"Click, then press the new combination.", hk),
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

    NSView *ax;
    if (AXIsProcessTrusted()) {
        NSStackView *ok = [NSStackView stackViewWithViews:@[[NSImageView imageViewWithImage:tintedImage(symSized(@"checkmark.circle.fill", 13, NSFontWeightRegular), [NSColor systemGreenColor])],
                                                             setLabel(@"Granted", 12, NSFontWeightMedium, [NSColor secondaryLabelColor])]];
        ok.spacing = 5; ax = ok;
    } else {
        ax = [self button:@"Grant Access…" target:self.app action:@selector(grantAX)];
    }
    [self addHeader:@"Permissions" note:nil];
    [self addFull:setCard(@[setRow(@"Accessibility", @"Needed for window snapping and auto-paste.", ax)])];
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
                            setRow(@"Rebuild Centre", @"Recompile from Centre.m and relaunch.", [self button:@"Rebuild" target:self.app action:@selector(rebuild)])])];
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
    // Refresh the Accessibility status after returning from System Settings.
    // Only rebuild when the status actually changed, so clicking back into the window never jumps the page.
    if (self.page == 0 && self.pageStack && !self.hotkeyButton.monitor && AXIsProcessTrusted() != self.axShown) [self showPage:0];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Single instance: if another Centre is already running, tell it to show and exit.
        NSString *snapDir = nil;
        BOOL readme = NO;
        for (int i = 1; i + 1 < argc; i++) {
            if (!strcmp(argv[i], "--snapshot")) snapDir = [NSString stringWithUTF8String:argv[i + 1]];
            if (!strcmp(argv[i], "--readme")) { snapDir = [NSString stringWithUTF8String:argv[i + 1]]; readme = YES; }
        }
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"com.y.centre";
        pid_t me = [NSProcessInfo processInfo].processIdentifier;
        if (!snapDir) for (NSRunningApplication *r in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid]) {
            if (r.processIdentifier != me && !r.terminated) {
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.y.centre.show" object:nil userInfo:nil deliverImmediately:YES];
                return 0;
            }
        }
        NSApplication *app = [NSApplication sharedApplication];
        CApp *d = [CApp new];
        d.snapshotDir = snapDir; d.readmeMode = readme;
        app.delegate = d;
        // Minimal main menu so Cmd+C/V/X/A work inside the search field.
        NSMenu *bar = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new]; [bar addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Centre"]; appItem.submenu = appMenu;
        [appMenu addItemWithTitle:@"Settings…" action:@selector(openSettings) keyEquivalent:@","].target = d;
        [appMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
        [appMenu addItemWithTitle:@"Quit Centre" action:@selector(terminate:) keyEquivalent:@"q"];
        NSMenuItem *editItem = [NSMenuItem new]; [bar addItem:editItem];
        NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"]; editItem.submenu = edit;
        [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        app.mainMenu = bar;
        [app run];
    }
    return 0;
}
