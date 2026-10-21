// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "Centre.h"

@implementation CItem @end

CItem *mk(NSString *title, NSString *sub, NSString *kind, NSString *symbol, CAction action) {
    CItem *i = [CItem new]; i.title = title; i.subtitle = sub; i.kind = kind; i.symbol = symbol; i.action = action; return i;
}
#pragma mark - Helpers

NSString *supportDir(void) {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Centre"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void runTask(NSString *launch, NSArray<NSString *> *args, void (^done)(NSString *out)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *t = [NSTask new];
        t.launchPath = launch; t.arguments = args;
        NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = p;
        @try { [t launch]; } @catch (NSException *e) { if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(e.reason); }); return; }
        NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(s); });
    });
}
void runShell(NSString *cmd, void (^done)(NSString *out)) { runTask(@"/bin/sh", @[@"-c", cmd], done); }
void runUserShell(NSString *cmd, void (^done)(NSString *out)) { runTask(@"/bin/zsh", @[@"-lc", cmd], done); }

// AppleScript runs in-process on one serial queue (no osascript process per call); compiled scripts are cached.
void runOsa(NSString *script, void (^done)(NSString *out)) {
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
void osa(NSString *script) { runOsa(script, nil); }

#pragma mark Password generator
// arc4random_uniform is cryptographically secure on macOS (kernel-seeded ChaCha20).
NSString *pwPick(NSString *pool) {
    unichar c = [pool characterAtIndex:arc4random_uniform((uint32_t)pool.length)];
    return [NSString stringWithCharacters:&c length:1];
}
static NSString *const kPwLower = @"abcdefghijkmnopqrstuvwxyz", *const kPwUpper = @"ABCDEFGHJKLMNPQRSTUVWXYZ",
                     *const kPwDigit = @"23456789", *const kPwSymbol = @"!@#$%^&*-_=+?";
NSString *genPassword(NSUInteger len, BOOL symbols) {
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
double pwBits(NSUInteger len, BOOL symbols) {
    double pool = kPwLower.length + kPwUpper.length + kPwDigit.length + (symbols ? kPwSymbol.length : 0);
    return len * log2(pool);
}
NSString *genPassphrase(NSUInteger nWords) {
    static NSArray *words; static dispatch_once_t once;
    dispatch_once(&once, ^{ words = @[@"acorn", @"amber", @"anchor", @"apple", @"arrow", @"aspen", @"atlas", @"autumn", @"badge", @"bamboo", @"banner", @"barley", @"basil", @"beacon", @"berry", @"birch", @"bison", @"blossom", @"bolt", @"breeze", @"brick", @"bridge", @"brook", @"bubble", @"cabin", @"cactus", @"camel", @"candle", @"canyon", @"cargo", @"carrot", @"castle", @"cedar", @"cherry", @"cider", @"cinder", @"citrus", @"clover", @"cobalt", @"comet", @"copper", @"coral", @"cosmos", @"cotton", @"crane", @"crater", @"cricket", @"crystal", @"cypress", @"dagger", @"daisy", @"delta", @"desert", @"diesel", @"dolphin", @"dragon", @"drift", @"eagle", @"ember", @"engine", @"falcon", @"feather", @"fern", @"fiddle", @"flint", @"forest", @"fossil", @"fountain", @"fox", @"galaxy", @"garnet", @"ginger", @"glacier", @"globe", @"granite", @"grape", @"gravel", @"harbor", @"hazel", @"heron", @"hollow", @"honey", @"horizon", @"indigo", @"iris", @"island", @"ivory", @"jade", @"jasmine", @"jungle", @"kettle", @"kiwi", @"lagoon", @"lantern", @"lava", @"lemon", @"lily", @"linen", @"lotus", @"lumen", @"magnet", @"mango", @"maple", @"marble", @"meadow", @"melon", @"meteor", @"mint", @"mirror", @"mosaic", @"motor", @"nectar", @"nickel", @"nova", @"oasis", @"ocean", @"olive", @"onyx", @"orbit", @"orchid", @"otter", @"paddle", @"panda", @"paper", @"parrot", @"pebble", @"pepper", @"pilot", @"pine", @"planet", @"plum", @"polar", @"poppy", @"prism", @"puzzle", @"quartz", @"quill", @"rabbit", @"radar", @"raven", @"reef", @"ribbon", @"river", @"robin", @"rocket", @"saddle", @"saffron", @"salmon", @"sapphire", @"satin", @"scarlet", @"shadow", @"shell", @"sierra", @"silver", @"sketch", @"slate", @"solar", @"sparrow", @"spice", @"spruce", @"summit", @"sunset", @"swift", @"tango", @"thistle", @"thunder", @"tiger", @"timber", @"topaz", @"tulip", @"tundra", @"velvet", @"violet", @"walnut", @"willow", @"winter", @"zephyr"]; });
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < nWords; i++) [parts addObject:[words[arc4random_uniform((uint32_t)words.count)] capitalizedString]];
    [parts addObject:[NSString stringWithFormat:@"%u", 10 + arc4random_uniform(90)]];
    return [parts componentsJoinedByString:@"-"];
}
NSUInteger pwWordCount(void) { return 178; }
NSString *genPIN(NSUInteger len) {
    NSMutableString *p = [NSMutableString string];
    for (NSUInteger i = 0; i < len; i++) [p appendFormat:@"%u", arc4random_uniform(10)];
    return p;
}
// Copies a secret: marked concealed so clipboard managers (and Centre's own history) skip it, and cleared after 90 s.
void copySecret(NSString *s) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:@[NSPasteboardTypeString, @"org.nspasteboard.ConcealedType", @"org.nspasteboard.TransientType"] owner:nil];
    [pb setString:s forType:NSPasteboardTypeString];
    [pb setString:@"" forType:@"org.nspasteboard.ConcealedType"];
    [pb setString:@"" forType:@"org.nspasteboard.TransientType"];
    NSInteger cc = pb.changeCount;
    showHUD(@"Password copied · clears in 90 s", @"key.fill");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([NSPasteboard generalPasteboard].changeCount == cc) [[NSPasteboard generalPasteboard] clearContents];
    });
}

void copyText(NSString *s) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents]; [pb setString:s forType:NSPasteboardTypeString];
}

void openURLString(NSString *s) {
    NSURL *u = [NSURL URLWithString:s];
    if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

NSString *urlEncode(NSString *s) {
    NSMutableCharacterSet *cs = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [cs addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs] ?: s;
}

// Fuzzy subsequence score. < 0 means no match.
double fuzzyScore(NSString *query, NSString *target) {
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

NSImage *symbolImage(NSString *name) {
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
NSImage *prerenderIcon(NSImage *src) {
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
#pragma mark - Hotkey helpers

NSDictionary<NSString *, NSNumber *> *hotkeyKeyMap(void) {
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

NSString *prettyHotkey(NSString *spec) {
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

static CGFloat gReserve = 0; static CGDirectDisplayID gReserveDisplay = 0; static BOOL gReserveTop = NO;
void setTaskbarReserve(NSScreen *screen, CGFloat height, BOOL top) {
    gReserve = screen ? MAX(0, height) : 0; gReserveTop = top;
    gReserveDisplay = screen ? [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : 0;
}
NSRect usableFrame(NSScreen *screen) {
    NSRect v = screen.visibleFrame;
    if (gReserve > 0 && [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == gReserveDisplay) {
        if (!gReserveTop) v.origin.y += gReserve;
        v.size.height -= gReserve;
    }
    return v;
}

void moveFrontWindow(NSRunningApplication *app, NSString *mode) {
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
    NSRect v = usableFrame(scr), r = v;
    CGSize curSize = CGSizeZero; CFTypeRef sv = NULL;
    AXUIElementCopyAttributeValue((AXUIElementRef)win, kAXSizeAttribute, &sv);
    if (sv) { AXValueGetValue((AXValueRef)sv, kAXValueTypeCGSize, &curSize); CFRelease(sv); }
    CGFloat third = floor(v.size.width / 3);
    if ([mode isEqualToString:@"left"])       r.size.width = floor(v.size.width / 2);
    else if ([mode isEqualToString:@"leftThird"])   r.size.width = third;
    else if ([mode isEqualToString:@"centerThird"]) { r.size.width = third; r.origin.x = v.origin.x + third; }
    else if ([mode isEqualToString:@"rightThird"])  { r.size.width = third; r.origin.x = NSMaxX(v) - third; }
    else if ([mode isEqualToString:@"leftTwoThirds"])  r.size.width = third * 2;
    else if ([mode isEqualToString:@"rightTwoThirds"]) { r.size.width = third * 2; r.origin.x = NSMaxX(v) - third * 2; }
    else if ([mode isEqualToString:@"nextDisplay"]) {   // same relative position and size on the next screen
        NSArray<NSScreen *> *all = NSScreen.screens;
        if (all.count < 2 || curSize.width <= 0) { CFRelease(win); CFRelease(appEl); return; }
        NSScreen *next = all[([all indexOfObject:scr] + 1) % all.count];
        NSRect nv = usableFrame(next);
        NSRect wr = NSMakeRect(cur.x, H - cur.y - curSize.height, curSize.width, curSize.height);
        CGFloat fx = (wr.origin.x - v.origin.x) / v.size.width, fy = (wr.origin.y - v.origin.y) / v.size.height;
        CGFloat fw = MIN(wr.size.width / v.size.width, 1), fh = MIN(wr.size.height / v.size.height, 1);
        r = NSMakeRect(nv.origin.x + MAX(fx, 0) * nv.size.width, nv.origin.y + MAX(fy, 0) * nv.size.height, fw * nv.size.width, fh * nv.size.height);
    }
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

void simulatePaste(void) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef d = CGEventCreateKeyboardEvent(src, (CGKeyCode)9, true);
    CGEventRef u = CGEventCreateKeyboardEvent(src, (CGKeyCode)9, false);
    CGEventSetFlags(d, kCGEventFlagMaskCommand); CGEventSetFlags(u, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, d); CGEventPost(kCGHIDEventTap, u);
    CFRelease(d); CFRelease(u); if (src) CFRelease(src);
}
NSImage *symSize(NSString *name, CGFloat pt) {
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightSemibold]];
}

NSString *fmtTime(double sec) {
    if (!(sec >= 0) || isinf(sec)) sec = 0;
    long t = (long)floor(sec + 0.5), h = t / 3600, m = (t % 3600) / 60, x = t % 60;
    return h > 0 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, x] : [NSString stringWithFormat:@"%ld:%02ld", m, x];
}

NSString *shortAgo(NSTimeInterval t) {
    NSTimeInterval a = [NSDate date].timeIntervalSince1970 - t;
    if (a < 60) return @"Just now";
    if (a < 3600) return [NSString stringWithFormat:@"%.0fm ago", floor(a / 60)];
    if (a < 86400) return [NSString stringWithFormat:@"%.0fh ago", floor(a / 3600)];
    if (a < 2 * 86400) return @"Yesterday";
    return [NSString stringWithFormat:@"%.0fd ago", floor(a / 86400)];
}

NSString *defaultBrowserName(void) {
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]];
    NSString *n = u.lastPathComponent.stringByDeletingPathExtension;
    return n.length ? n : @"Safari";
}

#pragma mark Numbers, units and durations (pure; covered by SelfTest.m)

NSString *formatNumber(double v) {
    static NSNumberFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterDecimalStyle; f.maximumFractionDigits = 6; f.usesGroupingSeparator = YES; });
    return [f stringFromNumber:@(v)] ?: [NSString stringWithFormat:@"%g", v];
}

// "12*7+3", "2^10", "15% of 200", "sqrt(2)". YES with the value, NO when q isn't a calculation.
BOOL evaluateMath(NSString *q, double *out) {
    NSString *s = q.lowercaseString;
    NSRegularExpression *pct = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([\\d.]+)\\s*%\\s*of\\s*([\\d.]+)\\s*$" options:0 error:nil];
    NSTextCheckingResult *m = [pct firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (m) { *out = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue] / 100.0 * [[s substringWithRange:[m rangeAtIndex:2]] doubleValue]; return YES; }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-*/()^%, xabcdefghijklmnopqrstuvwxyz"];
    if ([s rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    if ([s rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound) return NO;
    if ([s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-*/^%x("]].location == NSNotFound) return NO;
    NSRegularExpression *words = [NSRegularExpression regularExpressionWithPattern:@"[a-z]+" options:0 error:nil];
    NSSet *known = [NSSet setWithArray:@[@"sqrt", @"ln", @"log", @"exp", @"floor", @"ceiling", @"abs", @"trunc", @"pi", @"e", @"x"]];
    for (NSTextCheckingResult *w in [words matchesInString:s options:0 range:NSMakeRange(0, s.length)])
        if (![known containsObject:[s substringWithRange:w.range]]) return NO;
    NSString *e = [s stringByReplacingOccurrencesOfString:@"," withString:@""];
    e = [e stringByReplacingOccurrencesOfString:@"^" withString:@"**"];
    NSArray *rewrites = @[@[@"(?<=[\\d)])\\s*x\\s*(?=[\\d(])", @"*"], @[@"([\\d.]+)\\s*%", @"($1/100)"],
                          @[@"\\bpi\\b", @"3.141592653589793"], @[@"\\be\\b", @"2.718281828459045"], @[@"(?<![\\d.])(\\d+)(?![\\d.])", @"$1.0"]];
    for (NSArray *rw in rewrites)
        e = [[NSRegularExpression regularExpressionWithPattern:rw[0] options:0 error:nil] stringByReplacingMatchesInString:e options:0 range:NSMakeRange(0, e.length) withTemplate:rw[1]];
    if ([e rangeOfString:@"x"].location != NSNotFound) return NO;
    @try {
        id v = [[NSExpression expressionWithFormat:e] expressionValueWithObject:nil context:nil];
        if ([v isKindOfClass:[NSNumber class]] && isfinite([v doubleValue])) { *out = [v doubleValue]; return YES; }
    } @catch (NSException *x) {}
    return NO;
}

// "5 km to mi", "70 kg in lb", "100 f to c", "90 min to h", "2 gb in mb". Returns "3.106856 mi" and the value, or nil.
NSString *convertUnits(NSString *q, double *out) {
    static NSDictionary<NSString *, NSArray *> *units; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *u = [NSMutableDictionary new];
        void (^add)(NSString *, NSString *, double, NSString *) = ^(NSString *aliases, NSString *cat, double factor, NSString *shown) {
            for (NSString *a in [aliases componentsSeparatedByString:@" "]) u[a] = @[cat, @(factor), shown];
        };
        add(@"mm millimeter millimeters millimetre millimetres", @"length", 0.001, @"mm");
        add(@"cm centimeter centimeters centimetre centimetres", @"length", 0.01, @"cm");
        add(@"m meter meters metre metres", @"length", 1, @"m");
        add(@"km kilometer kilometers kilometre kilometres", @"length", 1000, @"km");
        add(@"in inch inches", @"length", 0.0254, @"in");
        add(@"ft foot feet", @"length", 0.3048, @"ft");
        add(@"yd yard yards", @"length", 0.9144, @"yd");
        add(@"mi mile miles", @"length", 1609.344, @"mi");
        add(@"mg milligram milligrams", @"mass", 0.000001, @"mg");
        add(@"g gram grams", @"mass", 0.001, @"g");
        add(@"kg kilo kilos kilogram kilograms", @"mass", 1, @"kg");
        add(@"lb lbs pound pounds", @"mass", 0.45359237, @"lb");
        add(@"oz ounce ounces", @"mass", 0.028349523125, @"oz");
        add(@"st stone stones", @"mass", 6.35029318, @"st");
        add(@"ml milliliter milliliters millilitre millilitres", @"volume", 0.001, @"ml");
        add(@"l liter liters litre litres", @"volume", 1, @"L");
        add(@"tsp teaspoon teaspoons", @"volume", 0.00492892159375, @"tsp");
        add(@"tbsp tablespoon tablespoons", @"volume", 0.01478676478125, @"tbsp");
        add(@"floz", @"volume", 0.0295735295625, @"fl oz");
        add(@"cup cups", @"volume", 0.2365882365, @"cups");
        add(@"pt pint pints", @"volume", 0.473176473, @"pt");
        add(@"gal gallon gallons", @"volume", 3.785411784, @"gal");
        add(@"ms millisecond milliseconds", @"time", 0.001, @"ms");
        add(@"s sec secs second seconds", @"time", 1, @"s");
        add(@"min mins minute minutes", @"time", 60, @"min");
        add(@"h hr hrs hour hours", @"time", 3600, @"h");
        add(@"d day days", @"time", 86400, @"days");
        add(@"wk week weeks", @"time", 604800, @"weeks");
        add(@"b byte bytes", @"data", 1, @"B");
        add(@"kb kilobyte kilobytes", @"data", 1e3, @"KB");
        add(@"mb megabyte megabytes", @"data", 1e6, @"MB");
        add(@"gb gigabyte gigabytes", @"data", 1e9, @"GB");
        add(@"tb terabyte terabytes", @"data", 1e12, @"TB");
        add(@"kmh kph km/h", @"speed", 1 / 3.6, @"km/h");
        add(@"mph", @"speed", 0.44704, @"mph");
        add(@"m/s mps", @"speed", 1, @"m/s");
        add(@"kn knot knots", @"speed", 0.514444, @"kn");
        add(@"c °c celsius", @"temp", 0, @"°C");
        add(@"f °f fahrenheit", @"temp", 1, @"°F");
        add(@"k kelvin", @"temp", 2, @"K");
        units = u;
    });
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(-?[\\d.,]+)\\s*([a-z°/]+)\\s+(?:to|in|as)\\s+([a-z°/]+)\\s*$"
                                                                        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:q options:0 range:NSMakeRange(0, q.length)];
    if (!m) return nil;
    double v = [[[q substringWithRange:[m rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"," withString:@""] doubleValue];
    NSArray *a = units[[q substringWithRange:[m rangeAtIndex:2]].lowercaseString], *b = units[[q substringWithRange:[m rangeAtIndex:3]].lowercaseString];
    if (!a || !b || ![a[0] isEqualToString:b[0]]) return nil;
    double r;
    if ([a[0] isEqualToString:@"temp"]) {
        int from = [a[1] intValue], to = [b[1] intValue];
        double k = from == 0 ? v + 273.15 : from == 1 ? (v - 32) * 5 / 9 + 273.15 : v;
        r = to == 0 ? k - 273.15 : to == 1 ? (k - 273.15) * 9 / 5 + 32 : k;
    } else r = v * [a[1] doubleValue] / [b[1] doubleValue];
    *out = r;
    return [NSString stringWithFormat:@"%@ %@", formatNumber([[NSString stringWithFormat:@"%.6g", r] doubleValue]), b[2]];   // 6 significant figures
}

// "10m", "90s", "1h30m", "45min", "1:30" (m:ss), "25" (minutes). Seconds, or 0 when s isn't a duration.
NSTimeInterval parseDuration(NSString *s) {
    NSString *t = [[s.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsJoinedByString:@""];
    if (!t.length) return 0;
    NSRegularExpression *colon = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+):(\\d{2})$" options:0 error:nil];
    NSTextCheckingResult *m = [colon firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (m) return [[t substringWithRange:[m rangeAtIndex:1]] doubleValue] * 60 + [[t substringWithRange:[m rangeAtIndex:2]] doubleValue];
    if ([[NSRegularExpression regularExpressionWithPattern:@"^\\d+(\\.\\d+)?$" options:0 error:nil] firstMatchInString:t options:0 range:NSMakeRange(0, t.length)])
        return t.doubleValue * 60;
    NSRegularExpression *parts = [NSRegularExpression regularExpressionWithPattern:@"^(?:(\\d+(?:\\.\\d+)?)h(?:rs?|ours?)?)?(?:(\\d+(?:\\.\\d+)?)m(?:ins?|inutes?)?)?(?:(\\d+)s(?:ecs?|econds?)?)?$" options:0 error:nil];
    m = [parts firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (!m) return 0;
    double total = 0, mult[] = {3600, 60, 1};
    for (NSUInteger g = 1; g <= 3; g++) if ([m rangeAtIndex:g].location != NSNotFound) total += [[t substringWithRange:[m rangeAtIndex:g]] doubleValue] * mult[g - 1];
    return total;
}

// One path step, matched the way people type it: exact name, then any case, then a unique-enough prefix
// ("doc" → Documents). Listing first keeps the folder's real capitalisation on case-insensitive disks.
static NSString *stepInto(NSString *dir, NSString *c) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *lc = c.lowercaseString, *hit = nil;
    if ([names containsObject:c]) hit = c;
    if (!hit) for (NSString *n in names) if ([n.lowercaseString isEqualToString:lc]) { hit = n; break; }
    if (!hit) for (NSString *n in names) {
        BOOL d = NO;
        if (![n hasPrefix:@"."] && [n.lowercaseString hasPrefix:lc] && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:n] isDirectory:&d] && d) { hit = n; break; }
    }
    if (!hit) hit = c;                                    // unlistable folder (no permission yet): trust the typed name
    NSString *next = [dir stringByAppendingPathComponent:hit]; BOOL d = NO;
    return [fm fileExistsAtPath:next isDirectory:&d] && d ? next : nil;
}

static NSString *resolveDir(NSString *base, NSArray<NSString *> *comps) {
    NSString *cur = base;
    for (NSString *c in comps) {
        if (!c.length || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."]) { cur = cur.stringByDeletingLastPathComponent; continue; }
        cur = stepInto(cur, c); if (!cur) return nil;
    }
    return cur;
}

static NSArray<NSDictionary *> *listMatches(NSString *dir, NSString *partial, double penalty) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray new]; NSUInteger scanned = 0;
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (++scanned > 4000) break;
        if ([n hasPrefix:@"."] && ![partial hasPrefix:@"."]) continue;
        if ([n isEqualToString:@"Icon\r"]) continue;
        double s = partial.length ? fuzzyScore(partial, n) : 0; if (s < 0) continue;
        NSString *p = [dir stringByAppendingPathComponent:n]; BOOL d = NO;
        [fm fileExistsAtPath:p isDirectory:&d];
        BOOL folder = d && ![[NSWorkspace sharedWorkspace] isFilePackageAtPath:p];
        [out addObject:@{@"path": p, @"dir": @(folder), @"score": @(s + (folder ? 4 : 0) - penalty)}];
    }
    return out;
}

// Path completion for "/documents", "~/doc/rep", "/applications/saf". A "/" path that doesn't match anything
// strong from the disk root is also tried from the home folder, because people type "/Documents" meaning theirs.
// Returns @{dir: the folder being listed (or nil), items: [{path, dir, score}] best first}.
NSDictionary *pathCompletions(NSString *q, NSString *home, NSUInteger limit) {
    if (!([q hasPrefix:@"/"] || [q hasPrefix:@"~"])) return @{@"items": @[]};
    BOOL tilde = [q hasPrefix:@"~"];
    NSString *rel = tilde ? [q substringFromIndex:1] : q;
    NSMutableArray<NSString *> *comps = [[rel componentsSeparatedByString:@"/"] mutableCopy];
    NSString *partial = @"";
    if (rel.length && ![rel hasSuffix:@"/"]) { partial = comps.lastObject; [comps removeLastObject]; }
    NSArray *bases = tilde ? @[home] : @[@"/", home];
    NSString *shown = nil; NSMutableArray *items = [NSMutableArray new];
    for (NSUInteger b = 0; b < bases.count; b++) {
        NSString *dir = resolveDir(bases[b], comps); if (!dir) continue;
        NSArray *found = listMatches(dir, partial, b);
        double best = -1; for (NSDictionary *f in found) best = MAX(best, [f[@"score"] doubleValue]);
        if (!shown) shown = dir;
        [items addObjectsFromArray:found];
        // The root answered well (or the user is browsing it): no need to look in home.
        if (b == 0 && !tilde && (best >= 100 || (!partial.length && comps.count))) break;
        if (b == 0 && !tilde && !partial.length && !comps.count) break;   // bare "/" lists the disk root
    }
    double top = -1; for (NSDictionary *f in items) top = MAX(top, [f[@"score"] doubleValue]);
    if (top >= 100) [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *f, id _) { return [f[@"score"] doubleValue] >= 60; }]];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double x = [a[@"score"] doubleValue], y = [b[@"score"] doubleValue];
        if (x != y) return x > y ? NSOrderedAscending : NSOrderedDescending;
        return [[a[@"path"] lastPathComponent] localizedCaseInsensitiveCompare:[b[@"path"] lastPathComponent]];
    }];
    if (items.count > limit) [items removeObjectsInRange:NSMakeRange(limit, items.count - limit)];
    if (top >= 100 && shown && items.count && ![[items.firstObject[@"path"] stringByDeletingLastPathComponent] isEqualToString:shown])
        shown = [items.firstObject[@"path"] stringByDeletingLastPathComponent];
    return shown ? @{@"dir": shown, @"items": items} : @{@"items": items};
}
