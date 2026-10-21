// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Context: what you were doing when you opened Centre (selected text, the app in front, its windows),
// plus small instant tools — transforms, time zones, ports, emoji and system info.
#import "App.h"
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/sysctl.h>
#import <signal.h>

static NSString *flat(NSString *s, NSUInteger max) {
    NSString *t = [[[s ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" ⏎ "]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length <= max) return t;
    NSUInteger end = [t rangeOfComposedCharacterSequenceAtIndex:max].location;   // never split an emoji or accented letter
    return [[t substringToIndex:end] stringByAppendingString:@"…"];
}

static NSDictionary *browserKinds(void) {
    return @{ @"com.brave.Browser": @"chromium", @"com.google.Chrome": @"chromium", @"com.microsoft.edgemac": @"chromium",
              @"com.vivaldi.Vivaldi": @"chromium", @"company.thebrowser.Browser": @"chromium", @"net.imput.helium": @"chromium",
              @"org.chromium.Chromium": @"chromium", @"com.apple.Safari": @"safari", @"com.apple.SafariTechnologyPreview": @"safari" };
}

@implementation CApp (Context)

#pragma mark Capture (runs as Centre opens, before the panel takes focus)

- (void)captureContext {
    self.selectedText = nil;
    NSRunningApplication *fr = [NSWorkspace sharedWorkspace].frontmostApplication;
    BOOL me = fr == NSRunningApplication.currentApplication;
    self.contextBundleID = me ? nil : fr.bundleIdentifier;
    self.contextAppName = me ? nil : fr.localizedName;
    if (me || [self.config[@"contextActions"] isEqual:@NO] || !AXIsProcessTrusted()) return;
    // Ask the front app itself (a timeout set on the system-wide element would apply to every AX call Centre makes).
    AXUIElementRef sys = AXUIElementCreateApplication(fr.processIdentifier);
    AXUIElementSetMessagingTimeout(sys, 0.12);                   // a frozen app must never delay the panel
    CFTypeRef focused = NULL;
    if (AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess && focused) {
        AXUIElementSetMessagingTimeout((AXUIElementRef)focused, 0.12);
        CFTypeRef sel = NULL;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXSelectedTextAttribute, &sel) == kAXErrorSuccess && sel) {
            if (CFGetTypeID(sel) == CFStringGetTypeID()) {
                NSString *s = (__bridge NSString *)sel;
                if (s.length <= 20000 && [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) self.selectedText = [s copy];
            }
            CFRelease(sel);
        }
        CFRelease(focused);
    }
    CFRelease(sys);
}

#pragma mark Selected text

- (NSArray<CItem *> *)selectionItems {
    NSString *s = self.selectedText;
    if (!s.length) return @[];
    __weak CApp *ws = self;
    NSString *trim = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *r = [NSMutableArray new];
    NSString *tpl = ([self.config[@"webSearch"] isKindOfClass:[NSString class]] ? self.config[@"webSearch"] : @"https://duckduckgo.com/?q=%s");
    NSString *search = [tpl stringByReplacingOccurrencesOfString:@"%s" withString:urlEncode(trim)];
    CItem *web = mk([NSString stringWithFormat:@"Search the web for “%@”", flat(trim, 46)], nil, @"Web", @"magnifyingglass", ^{ openURLString(search); });
    web.verb = @"Search";
    [r addObject:web];
    NSString *url = cleanURL(trim);
    BOOL oneWord = trim.length <= 40 && [trim rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound
                   && [trim rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
    if (url && [trim rangeOfString:@"://"].location != NSNotFound) {
        CItem *o = mk(@"Open the selected link", flat(trim, 60), @"URL", @"globe", ^{ openURLString(trim); });
        o.verb = @"Open Link"; [r addObject:o];
    } else if (oneWord) {
        CItem *d = mk([NSString stringWithFormat:@"Define “%@”", trim], @"macOS dictionary, offline", @"Dictionary", @"character.book.closed.fill", ^{ [ws enterQuery:[@"define " stringByAppendingString:trim]]; });
        d.keepsPanel = YES; d.verb = @"Define"; [r addObject:d];
    } else {
        NSString *tr = [@"https://translate.google.com/?sl=auto&tl=en&op=translate&text=" stringByAppendingString:urlEncode(trim)];
        CItem *t = mk(@"Translate to English", @"Opens Google Translate with the selection", @"Web", @"character.bubble", ^{ openURLString(tr); });
        t.verb = @"Translate"; [r addObject:t];
    }
    CItem *tx = mk(@"Transform selection…", textStats(s), @"Transform", @"wand.and.stars", ^{ [ws enterQuery:@"tx "]; });
    tx.keepsPanel = YES; tx.verb = @"Choose Transform";
    [r addObject:tx];
    return r;
}

// Swap the query without closing the panel (used by rows that lead somewhere: Define, Transform…).
- (void)enterQuery:(NSString *)q {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.panel.visible) [self show];
        self.field.stringValue = q;
        NSText *ed = self.field.currentEditor; if (ed) ed.selectedRange = NSMakeRange(q.length, 0);
        [self refresh];
    });
}

#pragma mark Transforms

- (NSString *)transformSource:(BOOL *)fromSelection {
    if (self.selectedText.length) { if (fromSelection) *fromSelection = YES; return self.selectedText; }
    if (fromSelection) *fromSelection = NO;
    return [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
}

- (CItem *)transformItem:(NSString *)name {
    BOOL sel = NO; NSString *src = [self transformSource:&sel];
    BOOL big = src.length > 100000;                                 // megabytes of log text: transform only when you choose one
    NSString *out = (src.length && !big) ? transformText(name, src) : nil;
    BOOL same = out && [out isEqualToString:src];
    static NSDictionary *icons; static dispatch_once_t once;
    dispatch_once(&once, ^{
        icons = @{ @"UPPERCASE": @"textformat.size.larger", @"lowercase": @"textformat.size.smaller", @"Title Case": @"textformat",
                   @"Sentence case": @"text.alignleft", @"camelCase": @"chevron.left.forwardslash.chevron.right",
                   @"snake_case": @"chevron.left.forwardslash.chevron.right", @"kebab-case": @"chevron.left.forwardslash.chevron.right",
                   @"Trim Whitespace": @"scissors", @"Join Lines": @"arrow.right.to.line", @"Sort Lines": @"arrow.up.arrow.down",
                   @"Unique Lines": @"line.3.horizontal.decrease", @"Reverse Lines": @"arrow.uturn.down", @"JSON Pretty": @"curlybraces",
                   @"JSON Minify": @"curlybraces", @"URL Encode": @"link", @"URL Decode": @"link", @"Base64 Encode": @"number",
                   @"Base64 Decode": @"number", @"Straight Quotes": @"quote.opening", @"Clean URL": @"sparkles" };
    });
    NSString *sub = !src.length ? @"Select text or copy something first"
                  : !out ? @"Doesn't apply to this text"
                  : same ? @"No change"
                  : [@"→ " stringByAppendingString:flat(out, 70)];
    __weak CApp *ws = self;
    CItem *i = mk(name, sub, @"Transform", icons[name] ?: @"wand.and.stars", nil);
    i.key = [@"tx:" stringByAppendingString:name];
    i.detail = sel ? @"Selection" : @"Clipboard";
    if (big) {
        i.subtitle = @"Large text · ↩ applies it";
        i.action = ^{ NSString *o = transformText(name, src); if (o && ![o isEqualToString:src]) [ws deliverText:o paste:YES]; else NSBeep(); };
        i.verb = sel ? @"Replace Selection" : @"Paste Result";
        return i;
    }
    if (out && !same) {
        i.action = ^{ [ws deliverText:out paste:YES]; };            // replaces the selection, or pastes the clipboard's new form
        i.altAction = ^{ copyText(out); showHUD([name stringByAppendingString:@" · copied"], @"doc.on.clipboard.fill"); };
        i.altHint = @"⌘↩ Copy";
        i.verb = sel ? @"Replace Selection" : @"Paste Result";
    } else i.action = ^{ NSBeep(); };
    return i;
}

- (NSArray<CItem *> *)transformItems:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    BOOL sel = NO; NSString *src = [self transformSource:&sel];
    if (!q.length && src.length && src.length <= 100000) {
        CItem *st = mk(textStats(src), flat(src, 70), @"Transform", @"textformat.123", ^{ copyText(textStats(src)); showHUD(@"Counts copied", @"doc.on.clipboard.fill"); });
        st.detail = sel ? @"Selection" : @"Clipboard"; st.verb = @"Copy Counts"; st.score = 10000;
        [r addObject:st];
    }
    for (NSString *n in transformNames()) {
        double s = q.length ? fuzzyScore(q, n) : 0; if (s < 0) continue;
        CItem *i = [self transformItem:n];
        i.score = s + (([i.subtitle hasPrefix:@"→"]) ? 1 : 0) + [self usageBoost:i.key];
        [r addObject:i];
    }
    [r sortUsingComparator:^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame; }];
    if (r.count > kMaxRows) [r removeObjectsInRange:NSMakeRange(kMaxRows, r.count - kMaxRows)];
    return r;
}

#pragma mark The app you came from

- (NSArray<CItem *> *)appContextItems {
    NSString *bid = self.contextBundleID, *app = self.contextAppName ?: @"the app";
    if (!bid.length || [self.config[@"contextActions"] isEqual:@NO]) return @[];
    NSMutableArray *r = [NSMutableArray new];
    NSString *kind = browserKinds()[bid];
    // Automation errors (-1743) mean macOS hasn't let Centre talk to that app yet; say where to allow it.
    void (^problem)(NSString *) = ^(NSString *o) {
        if ([o containsString:@"-1743"]) showHUDFor([NSString stringWithFormat:@"Allow Centre to control %@ in System Settings › Privacy & Security › Automation", app], @"hand.raised.fill", 4);
        else showHUDFor([NSString stringWithFormat:@"%@ didn't answer: %@", app, flat(o, 60)], @"exclamationmark.triangle.fill", 3);
    };
    if (kind) {
        BOOL safari = [kind isEqualToString:@"safari"];
        NSString *script = safari
            ? [NSString stringWithFormat:@"tell application id \"%@\" to return (URL of front document) & linefeed & (name of front document)", bid]
            : [NSString stringWithFormat:@"tell application id \"%@\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)", bid];
        void (^withPage)(void (^)(NSString *url, NSString *title)) = ^(void (^use)(NSString *, NSString *)) {
            runOsa(script, ^(NSString *o) {
                NSArray *p = [o componentsSeparatedByString:@"\n"];
                NSString *u = p.firstObject ?: @"";
                if (![u containsString:@"://"]) { problem(o); return; }
                use(u, p.count > 1 ? p[1] : u);
            });
        };
        CItem *a = mk(@"Copy Page URL", app, @"Context", @"link", ^{ withPage(^(NSString *u, NSString *t) { copyText(u); showHUD(@"Page URL copied", @"link"); }); });
        CItem *b = mk(@"Copy as Markdown Link", @"[Title](url) — for notes and chats", @"Context", @"text.badge.plus", ^{
            withPage(^(NSString *u, NSString *t) {
                NSString *safe = [[t stringByReplacingOccurrencesOfString:@"[" withString:@"("] stringByReplacingOccurrencesOfString:@"]" withString:@")"];
                copyText([NSString stringWithFormat:@"[%@](%@)", safe, u]); showHUD(@"Markdown link copied", @"text.badge.plus"); }); });
        CItem *c = mk(@"Copy Clean URL", @"Without tracking parameters (utm, fbclid…)", @"Context", @"sparkles", ^{
            withPage(^(NSString *u, NSString *t) { copyText(cleanURL(u) ?: u); showHUD(@"Clean URL copied", @"sparkles"); }); });
        for (CItem *i in @[a, b, c]) { i.verb = @"Copy"; [r addObject:i]; }
    } else if ([bid isEqualToString:@"com.apple.finder"]) {
        NSString *here = @"tell application \"Finder\" to return POSIX path of (insertion location as alias)";
        CItem *t = mk(@"Open Terminal Here", @"In the folder Finder is showing", @"Context", @"terminal", ^{
            runOsa(here, ^(NSString *o) { if (![o hasPrefix:@"/"]) { problem(o); return; } runShell([NSString stringWithFormat:@"open -a Terminal %@", shellQuote(o)], nil); }); });
        CItem *p = mk(@"Copy Folder Path", nil, @"Context", @"folder", ^{
            runOsa(here, ^(NSString *o) { if (![o hasPrefix:@"/"]) { problem(o); return; } copyText(o); showHUD([@"Copied " stringByAppendingString:[o stringByAbbreviatingWithTildeInPath]], @"folder"); }); });
        CItem *s = mk(@"Copy Selected File Paths", @"One per line", @"Context", @"doc.on.doc", ^{
            runOsa(@"set out to \"\"\ntell application \"Finder\" to set sel to selection as alias list\nrepeat with f in sel\nset out to out & POSIX path of f & linefeed\nend repeat\nreturn out", ^(NSString *o) {
                if (![o hasPrefix:@"/"]) { if (o.length) problem(o); else showHUD(@"Nothing selected in Finder", @"doc.on.doc"); return; }
                copyText(o); NSUInteger n = [o componentsSeparatedByString:@"\n"].count;
                showHUD([NSString stringWithFormat:@"Copied %lu path%@", (unsigned long)n, n == 1 ? @"" : @"s"], @"doc.on.doc"); }); });
        CItem *nf = mk(@"New Text File Here", @"Creates “Untitled.txt” and selects it", @"Context", @"doc.badge.plus", ^{
            runOsa(here, ^(NSString *o) {
                if (![o hasPrefix:@"/"]) { problem(o); return; }
                NSString *path = [o stringByAppendingPathComponent:@"Untitled.txt"]; NSInteger n = 2;
                while ([[NSFileManager defaultManager] fileExistsAtPath:path]) path = [o stringByAppendingPathComponent:[NSString stringWithFormat:@"Untitled %ld.txt", (long)n++]];
                if ([@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
                else showHUD(@"Couldn't create a file in this folder", @"exclamationmark.triangle.fill"); }); });
        for (CItem *i in @[t, p, s, nf]) { i.verb = @"Run"; [r addObject:i]; }
    }
    return r;
}

#pragma mark Windows (AX: every window of every app, read in the background as Centre opens)

- (void)refreshWindowList {
    if (!AXIsProcessTrusted()) { self.windowList = @[]; return; }
    NSMutableArray *apps = [NSMutableArray new];
    for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
        if (r.activationPolicy == NSApplicationActivationPolicyRegular && r != NSRunningApplication.currentApplication && !r.terminated) [apps addObject:r];
    NSRunningApplication *front = self.previousApp;
    if (front && [apps containsObject:front]) { [apps removeObject:front]; [apps insertObject:front atIndex:0]; }
    static NSUInteger generation; NSUInteger mine = ++generation;  // a slow older scan must not overwrite a newer one
    __weak CApp *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *out = [NSMutableArray new];
        for (NSRunningApplication *r in apps) {
            AXUIElementRef ae = AXUIElementCreateApplication(r.processIdentifier);
            AXUIElementSetMessagingTimeout(ae, 0.2);
            CFTypeRef wins = NULL;
            if (AXUIElementCopyAttributeValue(ae, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins && CFGetTypeID(wins) == CFArrayGetTypeID()) {
                for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
                    AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
                    CFTypeRef sub = NULL; AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, &sub);
                    BOOL standard = !sub || CFEqual(sub, kAXStandardWindowSubrole); if (sub) CFRelease(sub);
                    if (!standard) continue;
                    CFTypeRef t = NULL; AXUIElementCopyAttributeValue(w, kAXTitleAttribute, &t);
                    NSString *title = (t && CFGetTypeID(t) == CFStringGetTypeID()) ? [(__bridge NSString *)t copy] : nil;
                    if (t) CFRelease(t);
                    CFTypeRef mn = NULL; AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute, &mn);
                    BOOL mini = mn && CFGetTypeID(mn) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)mn); if (mn) CFRelease(mn);
                    [out addObject:@{@"title": title.length ? title : (r.localizedName ?: @"Window"), @"app": r.localizedName ?: @"",
                                     @"pid": @(r.processIdentifier), @"path": r.bundleURL.path ?: @"", @"min": @(mini), @"win": (__bridge id)w}];
                }
            }
            if (wins) CFRelease(wins);
            CFRelease(ae);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            CApp *me = ws; if (!me || mine != generation) return;
            me.windowList = out;
            if (me.panel.visible && [me.modeLabel isEqualToString:@"Windows"]) [me refresh];
        });
    });
}

- (CItem *)windowItem:(NSDictionary *)d {
    NSString *title = d[@"title"], *app = d[@"app"];
    pid_t pid = [d[@"pid"] intValue]; BOOL mini = [d[@"min"] boolValue];
    id win = d[@"win"];
    CItem *i = [CItem new];
    i.title = title; i.subtitle = mini ? [app stringByAppendingString:@" · minimised"] : ([title isEqualToString:app] ? nil : app);
    i.kind = @"Open Window"; i.detail = @"Window"; i.path = [d[@"path"] length] ? d[@"path"] : nil; i.verb = @"Switch to Window";
    i.action = ^{
        AXUIElementRef w = (__bridge AXUIElementRef)win;
        AXUIElementSetMessagingTimeout(w, 0.5);                  // a hung app can't freeze Centre
        if (mini) AXUIElementSetAttributeValue(w, kAXMinimizedAttribute, kCFBooleanFalse);
        AXUIElementPerformAction(w, kAXRaiseAction);
        AXUIElementSetAttributeValue(w, kAXMainAttribute, kCFBooleanTrue);
        [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    };
    i.altAction = ^{
        AXUIElementRef w = (__bridge AXUIElementRef)win; CFTypeRef btn = NULL;
        AXUIElementSetMessagingTimeout(w, 0.5);
        if (AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute, &btn) == kAXErrorSuccess && btn) { AXUIElementPerformAction((AXUIElementRef)btn, kAXPressAction); CFRelease(btn); }
        else showHUD(@"That window can't be closed from here", @"exclamationmark.circle.fill");
    };
    i.altHint = @"⌘↩ Close Window";
    return i;
}

- (NSArray<CItem *> *)windowItems:(NSString *)q {
    if (!AXIsProcessTrusted()) {
        CItem *g = mk(@"Allow Accessibility to switch windows", @"Centre reads window titles through Accessibility", @"Centre", @"hand.raised", nil);
        __weak CApp *ws = self; g.action = ^{ [ws grantAX]; }; return @[g];
    }
    if (!self.windowList) return @[mk(@"Reading windows…", nil, @"Open Window", @"macwindow.on.rectangle", nil)];
    NSMutableArray *r = [NSMutableArray new];
    NSUInteger order = 0;
    for (NSDictionary *d in self.windowList) {
        double s = 0;
        if (q.length) { s = MAX(fuzzyScore(q, d[@"title"]), fuzzyScore(q, d[@"app"]) - 6); if (s < 0) { order++; continue; } }
        CItem *i = [self windowItem:d]; i.score = s - (double)order++ * 0.01;     // ties keep front-to-back order
        [r addObject:i];
    }
    [r sortUsingComparator:^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame; }];
    if (!r.count) [r addObject:mk(q.length ? @"No window matches" : @"No open windows", @"Windows on other Spaces may not be listed", @"Open Window", @"macwindow", nil)];
    if (r.count > kMaxRows) [r removeObjectsInRange:NSMakeRange(kMaxRows, r.count - kMaxRows)];
    return r;
}

#pragma mark Time zones

- (CItem *)timeItem:(NSString *)q {
    NSDictionary *t = timeQuery(q, [NSDate date], [NSTimeZone localTimeZone]);
    if (!t) return nil;
    NSString *v = t[@"value"];
    CItem *i = mk(t[@"title"], t[@"subtitle"], @"Time", @"clock", ^{ copyText(v); showHUD([@"Copied " stringByAppendingString:v], @"clock"); });
    i.score = 1000; i.verb = @"Copy Time";
    return i;
}

#pragma mark Ports (port 3000)

- (NSArray<CItem *> *)portItems:(NSString *)port {
    NSInteger p = port.integerValue;
    if (p <= 0 || p > 65535 || [port rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location != NSNotFound)
        return @[mk(@"Type a port number", @"port 3000 shows what's listening and lets you stop it", @"Port", @"network", nil)];
    NSString *issued = self.currentQuery;
    __weak CApp *ws = self;
    runShell([NSString stringWithFormat:@"/usr/sbin/lsof -nP -iTCP:%ld -sTCP:LISTEN -Fpc 2>/dev/null", (long)p], ^(NSString *out) {
        CApp *me = ws; if (!me || ![me.currentQuery isEqualToString:issued] || !me.panel.visible) return;
        NSMutableArray *r = [NSMutableArray new];
        for (NSDictionary *d in parseLsof(out)) {
            pid_t pid = [d[@"pid"] intValue]; NSString *name = d[@"name"] ?: @"process";
            CItem *i = mk([NSString stringWithFormat:@"Stop %@ on port %ld", name, (long)p], [NSString stringWithFormat:@"PID %d", pid], @"Port", @"network", ^{
                if (kill(pid, SIGTERM) == 0) showHUD([NSString stringWithFormat:@"Stopped %@ (port %ld)", name, (long)p], @"checkmark.circle.fill");
                else showHUD(@"Couldn't stop it — it may belong to another user", @"exclamationmark.triangle.fill"); });
            i.altAction = ^{ kill(pid, SIGKILL); showHUD([NSString stringWithFormat:@"Force-stopped %@", name], @"xmark.octagon.fill"); };
            i.altHint = @"⌘↩ Force Stop"; i.verb = @"Stop Process";
            [r addObject:i];
        }
        if (!r.count) [r addObject:mk([NSString stringWithFormat:@"Nothing is listening on port %ld", (long)p], @"The port is free", @"Port", @"checkmark.circle", nil)];
        me.items = r; me.selected = 0; [me reloadTable];
    });
    return @[mk([NSString stringWithFormat:@"Checking port %ld…", (long)p], nil, @"Port", @"network", nil)];
}

#pragma mark Emoji (:smile or emoji heart)

- (NSArray<CItem *> *)emojiItems:(NSString *)q {
    static NSMutableDictionary *imgs; if (!imgs) imgs = [NSMutableDictionary new];
    NSMutableArray *r = [NSMutableArray new];
    __weak CApp *ws = self;
    NSString *lq = q.lowercaseString;
    NSArray *table = emojiTable();
    if (!lq.length) {                                                 // just ":" — the everyday ones first
        NSArray *fav = @[@"😂", @"😊", @"😍", @"👍", @"🙏", @"🔥", @"🎉", @"😭", @"✅"];
        NSMutableArray *picked = [NSMutableArray new];
        for (NSString *f in fav) for (NSArray *e in table) if ([[e[0] stringByReplacingOccurrencesOfString:@"\uFE0F" withString:@""] isEqualToString:f]) { [picked addObject:e]; break; }
        table = picked;
    }
    for (NSArray *e in table) {
        NSString *name = e[1];
        double s = 0;
        if (lq.length) {
            s = fuzzyScore(lq, name);
            for (NSString *w in [name componentsSeparatedByString:@" "]) if ([w hasPrefix:lq]) { s = MAX(s, 120 - (double)w.length * 0.2); break; }
            s -= (double)name.length * 0.15;                          // "heart" before "speaking head in silhouette"
            if (s < 0 || (s < 40 && lq.length > 2)) continue;           // keep scattered matches out of the way
        }
        NSString *ch = e[0];
        CItem *i = mk(transformText(@"Sentence case", name), nil, @"Emoji", nil, ^{ [ws deliverText:ch paste:YES]; });
        NSImage *img = imgs[ch];
        if (!img) {
            img = [NSImage imageWithSize:NSMakeSize(26, 26) flipped:NO drawingHandler:^BOOL(NSRect rr) {
                NSDictionary *a = @{NSFontAttributeName: [NSFont fontWithName:@"Apple Color Emoji" size:20] ?: [NSFont systemFontOfSize:20]};
                NSSize sz = [ch sizeWithAttributes:a];
                [ch drawAtPoint:NSMakePoint((rr.size.width - sz.width) / 2, (rr.size.height - sz.height) / 2) withAttributes:a]; return YES; }];
            imgs[ch] = img;
        }
        i.icon = img; i.verb = @"Paste Emoji";
        i.altAction = ^{ copyText(ch); showHUD([ch stringByAppendingString:@" copied"], @"doc.on.clipboard.fill"); }; i.altHint = @"⌘↩ Copy";
        i.score = s;
        [r addObject:i];
    }
    [r sortUsingComparator:^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame; }];
    if (r.count > kMaxRows) [r removeObjectsInRange:NSMakeRange(kMaxRows, r.count - kMaxRows)];
    if (!r.count) [r addObject:mk(@"No emoji by that name", @"Try a simpler word: heart, fire, smile", @"Emoji", @"face.smiling", nil)];
    return r;
}

#pragma mark System info (info)

- (NSArray<CItem *> *)systemInfoItems {
    NSMutableArray *r = [NSMutableArray new];
    CItem *(^row)(NSString *, NSString *, NSString *) = ^CItem *(NSString *label, NSString *value, NSString *sym) {
        CItem *i = mk(value, label, @"Info", sym, ^{ copyText(value); showHUD([label stringByAppendingString:@" copied"], @"doc.on.clipboard.fill"); });
        i.detail = label; i.verb = @"Copy"; i.subtitle = nil;
        return i;
    };
    // Battery
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    if (list && CFArrayGetCount(list) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, 0));
        NSInteger cap = [d[@kIOPSCurrentCapacityKey] integerValue], max = MAX([d[@kIOPSMaxCapacityKey] integerValue], 1);
        BOOL charging = [d[@kIOPSIsChargingKey] boolValue]; BOOL ac = [d[@kIOPSPowerSourceStateKey] isEqual:@kIOPSACPowerValue];
        NSInteger pct = cap * 100 / max;
        NSString *state = charging ? @" · charging" : ac ? @" · on power" : @"";
        [r addObject:row(@"Battery", [NSString stringWithFormat:@"%ld%%%@", (long)pct, state], pct > 60 ? @"battery.100" : pct > 20 ? @"battery.50" : @"battery.25")];
    }
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    // Local IP
    struct ifaddrs *ifs = NULL; NSString *ip = nil;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *a = ifs; a && !ip; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET || strncmp(a->ifa_name, "en", 2) != 0) continue;
            char buf[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, buf, sizeof buf);
            ip = [NSString stringWithUTF8String:buf];
        }
        freeifaddrs(ifs);
    }
    [r addObject:row(@"Local IP", ip ?: @"Not connected", @"wifi")];
    CItem *pub = mk(@"Public IP", @"Looks it up when you press ↩, then copies it", @"Info", @"globe", ^{
        runShell(@"curl -s --max-time 4 https://api.ipify.org", ^(NSString *o) {
            NSString *t = [o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length && t.length < 46 && [t rangeOfString:@" "].location == NSNotFound) { copyText(t); showHUD([@"Public IP " stringByAppendingString:t], @"globe"); }
            else showHUD(@"Couldn't reach the internet", @"wifi.exclamationmark"); }); });
    pub.verb = @"Look Up"; [r addObject:pub];
    // Disk, memory, uptime, system
    NSNumber *free = nil;
    [[NSURL fileURLWithPath:@"/"] getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    if (free) [r addObject:row(@"Disk free", [NSByteCountFormatter stringFromByteCount:free.longLongValue countStyle:NSByteCountFormatterCountStyleFile], @"internaldrive")];
    [r addObject:row(@"Memory", [NSByteCountFormatter stringFromByteCount:(long long)[NSProcessInfo processInfo].physicalMemory countStyle:NSByteCountFormatterCountStyleMemory], @"memorychip")];
    NSTimeInterval up = [NSProcessInfo processInfo].systemUptime;
    long days = (long)(up / 86400), hours = (long)fmod(up, 86400) / 3600, mins = (long)fmod(up, 3600) / 60;
    [r addObject:row(@"Uptime", days ? [NSString stringWithFormat:@"%ld day%@ %ld h", days, days == 1 ? @"" : @"s", hours] : [NSString stringWithFormat:@"%ld h %ld min", hours, mins], @"clock.arrow.circlepath")];
    char model[64] = {0}; size_t len = sizeof model;
    NSString *mdl = sysctlbyname("hw.model", model, &len, NULL, 0) == 0 ? [NSString stringWithUTF8String:model] : @"Mac";
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    [r addObject:row(@"System", [NSString stringWithFormat:@"macOS %ld.%ld.%ld · %@", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion, mdl], @"desktopcomputer")];
    return r;
}

@end
