// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// The deck: what makes Home answer "what was I just doing?"
//   Context Home  — from a browser, its other open tabs; from a terminal, your last commands (Finder actions live in App+Context).
//   Tab search    — any open tab in Brave, Chrome, Arc, Edge or Safari, by title or address; ↩ jumps straight to it.
//   Notes         — "note buy milk" keeps a line on Home until you tick it off.
//   Ambient line  — battery, network, next event and running timers, quietly under the search field.
#import "App.h"
#import <ifaddrs.h>
#import <net/if.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

// Browsers whose tabs Centre can read and switch to (Chromium family share one dictionary; Safari has its own).
static NSDictionary<NSString *, NSString *> *tabBrowsers(void) {
    return @{@"com.brave.Browser": @"chromium", @"com.brave.Browser.beta": @"chromium", @"com.google.Chrome": @"chromium",
             @"company.thebrowser.Browser": @"chromium", @"com.microsoft.edgemac": @"chromium", @"com.vivaldi.Vivaldi": @"chromium",
             @"net.imput.helium": @"chromium", @"com.apple.Safari": @"safari"};
}
static NSSet<NSString *> *terminalApps(void) {
    return [NSSet setWithArray:@[@"com.apple.Terminal", @"com.googlecode.iterm2", @"dev.warp.Warp-Stable", @"com.mitchellh.ghostty", @"net.kovidgoyal.kitty", @"org.alacritty"]];
}
static NSString *oneLine(NSString *s, NSUInteger max) {
    NSString *t = [[s stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return t.length > max ? [[t substringToIndex:[t rangeOfComposedCharacterSequenceAtIndex:max].location] stringByAppendingString:@"…"] : t;
}

@implementation CApp (Deck)

#pragma mark - Open tabs

// Read every tab of every running supported browser, off the main thread; cached until the next time Centre opens.
- (void)refreshTabs {
    if ([self.config[@"tabSearch"] isEqual:@NO] || self.tabsBusy) return;
    NSMutableArray *browsers = [NSMutableArray new];
    for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
        if (r.bundleIdentifier && tabBrowsers()[r.bundleIdentifier] && !r.terminated) [browsers addObject:@[r.bundleIdentifier, r.localizedName ?: @"Browser"]];
    if (!browsers.count) { self.browserTabs = @[]; return; }
    self.tabsBusy = YES;
    __weak CApp *ws = self;
    NSMutableArray *all = [NSMutableArray new];
    __block NSUInteger left = browsers.count;
    for (NSArray *b in browsers) {
        NSString *bid = b[0]; BOOL safari = [tabBrowsers()[bid] isEqualToString:@"safari"];
        // One line per tab: window index, tab index, active flag, title, URL (tab-separated; titles can't hold tabs).
        NSString *src = [NSString stringWithFormat:
            @"set out to \"\"\ntell application id \"%@\"\nset wi to 0\nrepeat with w in windows\nset wi to wi + 1\nset ti to 0\n"
             "set act to %@\nrepeat with t in tabs of w\nset ti to ti + 1\nset out to out & wi & tab & ti & tab & (ti = act) & tab & %@ & tab & (URL of t) & linefeed\nend repeat\nend repeat\nend tell\nreturn out",
            bid, safari ? @"(index of current tab of w)" : @"(active tab index of w)", safari ? @"(name of t)" : @"(title of t)"];
        runOsa(src, ^(NSString *o) {                                            // runs on Centre's script queue; answers on the main thread
            for (NSString *line in [o componentsSeparatedByString:@"\n"]) {
                NSArray *f = [line componentsSeparatedByString:@"\t"];
                if (f.count < 5 || ![f[4] containsString:@"://"]) continue;    // errors (not allowed yet, no windows) yield no lines
                [all addObject:@{@"bid": bid, @"app": b[1], @"w": @([f[0] integerValue]), @"t": @([f[1] integerValue]),
                                 @"active": @([f[2] isEqualToString:@"true"]), @"title": [f[3] length] ? f[3] : f[4], @"url": f[4]}];
            }
            if (--left) return;
            CApp *me = ws; if (!me) return;
            me.tabsBusy = NO; me.browserTabs = all;
            if (!me.panel.visible || me.selected > 0) return;                     // never pull the selection from under you
            if (me.field.stringValue.length || [tabBrowsers()[me.contextBundleID ?: @""] length]) [me refresh];
        });
    }
}
- (void)switchToTab:(NSDictionary *)t {
    BOOL safari = [tabBrowsers()[t[@"bid"]] isEqualToString:@"safari"];
    NSString *src = safari
        ? [NSString stringWithFormat:@"tell application id \"%@\"\nset current tab of window %@ to tab %@ of window %@\nset index of window %@ to 1\nactivate\nend tell", t[@"bid"], t[@"w"], t[@"t"], t[@"w"], t[@"w"]]
        : [NSString stringWithFormat:@"tell application id \"%@\"\nset active tab index of window %@ to %@\nset index of window %@ to 1\nactivate\nend tell", t[@"bid"], t[@"w"], t[@"t"], t[@"w"]];
    runOsa(src, ^(NSString *o) {
        if ([o containsString:@"-1743"]) showHUDFor([NSString stringWithFormat:@"Allow Centre to control %@ in System Settings › Privacy & Security › Automation", t[@"app"]], @"hand.raised.fill", 4);
        else if ([o containsString:@"error"] || [o containsString:@"Invalid index"]) showHUD(@"That tab has closed", @"xmark.circle");
    });
}
- (CItem *)tabItem:(NSDictionary *)t {
    __weak CApp *ws = self;
    NSString *host = [NSURL URLWithString:t[@"url"]].host ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    CItem *i = mk(oneLine(t[@"title"], 90), host, @"Tab", @"square.on.square", ^{ [ws switchToTab:t]; });
    i.altAction = ^{ copyText(t[@"url"]); showHUD(@"Tab address copied", @"link"); }; i.altHint = @"⌘↩ Copy Link";
    i.verb = @"Switch to Tab"; i.detail = t[@"app"];
    return i;
}
- (NSArray<CItem *> *)tabItemsFor:(NSString *)q limit:(NSUInteger)limit {
    if (!self.browserTabs.count || (q.length == 1)) return @[];
    NSMutableArray *scored = [NSMutableArray new];
    for (NSDictionary *t in self.browserTabs) {
        double s = q.length ? MAX(fuzzyScore(q, t[@"title"]), fuzzyScore(q, [NSURL URLWithString:t[@"url"]].host ?: @"") - 4) : 50;   // "" = all, in order
        if (s < 0) continue;
        CItem *i = [self tabItem:t]; i.score = s - 4; [scored addObject:i];
    }
    [scored sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame; }];
    return scored.count > limit ? [scored subarrayWithRange:NSMakeRange(0, limit)] : scored;
}

#pragma mark - Context Home

// What Home shows for the app you were in, on top of the Finder and page actions in App+Context.
- (NSArray<CItem *> *)deckContextItems {
    NSString *bid = self.contextBundleID ?: @"";
    NSMutableArray *r = [NSMutableArray new];
    if (tabBrowsers()[bid]) {                                                    // the other tabs of the window you were in
        NSArray *mine = [self.browserTabs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"bid == %@ AND w == 1 AND active == NO", bid]];
        for (NSDictionary *t in [mine subarrayWithRange:NSMakeRange(0, MIN(mine.count, (NSUInteger)3))]) { CItem *i = [self tabItem:t]; i.detail = @"Tab"; [r addObject:i]; }
    } else if ([terminalApps() containsObject:bid]) {
        for (NSString *cmd in [self recentShellCommands:4]) {
            __weak CApp *ws = self;
            CItem *i = mk(cmd, nil, @"Shell History", @"chevron.right.square", ^{ [ws deliverText:cmd paste:YES]; });
            i.altAction = ^{ copyText(cmd); showHUD(@"Command copied", @"doc.on.clipboard.fill"); }; i.altHint = @"⌘↩ Copy";
            i.verb = @"Paste Command"; i.detail = @"Paste"; i.previewText = cmd;
            [r addObject:i];
        }
    }
    return r;
}
// Your last distinct shell commands (zsh or bash history), newest first, skipping the trivial ones.
- (NSArray<NSString *> *)recentShellCommands:(NSUInteger)n {
    NSString *home = NSHomeDirectory();
    NSString *path = [home stringByAppendingPathComponent:@".zsh_history"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = [home stringByAppendingPathComponent:@".bash_history"];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path]; if (!fh) return @[];
    unsigned long long size = [fh seekToEndOfFile];
    [fh seekToFileOffset:size > 65536 ? size - 65536 : 0];                       // the tail is enough
    NSData *d = [fh readDataToEndOfFile]; [fh closeFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    NSSet *trivial = [NSSet setWithArray:@[@"ls", @"ll", @"la", @"cd", @"clear", @"exit", @"pwd", @"history", @"cd ..", @"cd ~"]];
    NSMutableArray *out = [NSMutableArray new]; NSMutableSet *seen = [NSMutableSet new];
    for (NSString *raw in [[s componentsSeparatedByString:@"\n"] reverseObjectEnumerator]) {
        NSString *c = raw;
        if ([c hasPrefix:@": "]) { NSRange semi = [c rangeOfString:@";"]; if (semi.location == NSNotFound) continue; c = [c substringFromIndex:semi.location + 1]; }   // zsh extended history
        c = [c stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (c.length < 3 || c.length > 300 || [c hasSuffix:@"\\"] || [trivial containsObject:c] || [seen containsObject:c]) continue;
        [seen addObject:c]; [out addObject:c];
        if (out.count >= n) break;
    }
    return out;
}

#pragma mark - Notes

- (NSString *)notesPath { return [supportDir() stringByAppendingPathComponent:@"notes.json"]; }
- (void)loadNotes {
    NSData *d = [NSData dataWithContentsOfFile:[self notesPath]];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    self.notes = [NSMutableArray new];
    if ([o isKindOfClass:[NSArray class]]) for (NSDictionary *e in o) if ([e isKindOfClass:[NSDictionary class]] && [e[@"text"] isKindOfClass:[NSString class]]) [self.notes addObject:e];
}
- (void)saveNotes {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.notes ?: @[] options:0 error:nil];
    if (![d writeToFile:[self notesPath] atomically:YES]) showHUD(@"Couldn't save your notes", @"exclamationmark.triangle.fill");
}
- (void)addNote:(NSString *)text {
    if (!self.notes) [self loadNotes];
    [self.notes insertObject:@{@"id": [NSUUID UUID].UUIDString, @"text": text, @"added": @([NSDate date].timeIntervalSince1970)} atIndex:0];
    [self saveNotes];
    showHUD(@"Noted", @"checkmark.circle");
}
- (void)finishNote:(NSString *)nid {
    NSUInteger i = [self.notes indexOfObjectPassingTest:^BOOL(NSDictionary *e, NSUInteger k, BOOL *stop) { return [e[@"id"] isEqual:nid]; }];
    if (i == NSNotFound) return;
    [self.notes removeObjectAtIndex:i]; [self saveNotes];
    showHUD(@"Done", @"checkmark.circle.fill");
}
- (NSArray<CItem *> *)noteItems {
    if (!self.notes) [self loadNotes];
    NSMutableArray *out = [NSMutableArray new];
    __weak CApp *ws = self;
    for (NSDictionary *e in self.notes) {
        NSString *text = e[@"text"], *nid = e[@"id"];
        CItem *i = mk(oneLine(text, 90), nil, @"Note", @"circle", ^{ [ws finishNote:nid]; });
        i.altAction = ^{ copyText(text); showHUD(@"Note copied", @"doc.on.clipboard.fill"); }; i.altHint = @"⌘↩ Copy";
        i.verb = @"Tick Off"; i.detail = shortAgo([e[@"added"] doubleValue]); i.previewText = text.length > 90 ? text : nil;
        [out addObject:i];
    }
    return out;
}

#pragma mark - Search

- (NSArray<CItem *> *)deckItemsFor:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    __weak CApp *ws = self;
    NSString *lower = q.lowercaseString;
    if ([lower hasPrefix:@"note "] && q.length > 5) {                            // note buy milk
        NSString *text = [[q substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (text.length) {
            CItem *i = mk([NSString stringWithFormat:@"Note “%@”", oneLine(text, 70)], @"Stays on Home until you tick it off", @"Note", @"square.and.pencil", ^{ [ws addNote:text]; });
            i.verb = @"Add Note"; i.score = 3000; [r addObject:i];
        }
        return r;
    }
    if (q.length >= 4 && [@"notes" hasPrefix:lower]) {
        NSArray *items = [self noteItems]; NSInteger k = 0;
        for (CItem *i in items) { i.score = 60 - k++; [r addObject:i]; }
        if (!items.count) { CItem *e = mk(@"No notes yet", @"Type “note” and a line to keep one on Home", @"Note", @"square.and.pencil", nil); e.score = 40; [r addObject:e]; }
    } else if (q.length >= 3) {
        for (CItem *i in [self noteItems]) { double s = fuzzyScore(q, i.title); if (s >= 0) { i.score = s - 10; [r addObject:i]; } }
    }
    if (q.length >= 2) [r addObjectsFromArray:[self tabItemsFor:q limit:3]];
    return r;
}

#pragma mark - Ambient line

// Battery, network, the next event and the first running timer: @[symbol, text] each, left to right.
- (NSArray<NSArray<NSString *> *> *)ambientSegments {
    if ([self.config[@"ambientLine"] isEqual:@NO]) return @[];
    if (self.readmeMode) return @[@[@"", @"Fri 23 Oct  9:41"], @[@"calendar", @"Design review  10:30"], @[@"battery.75", @"76%"], @[@"wifi", @"Online"]];   // fixed, for public screenshots
    NSMutableArray *seg = [NSMutableArray new];
    for (NSDictionary *t in self.timers) {
        NSDate *end = [t[@"end"] isKindOfClass:[NSDate class]] ? t[@"end"] : nil; if (!end) continue;
        NSString *label = [t[@"label"] description].length ? [t[@"label"] description] : @"Timer";
        [seg addObject:@[@"timer", [NSString stringWithFormat:@"%@  %@", oneLine(label, 20), fmtTime(MAX(0, end.timeIntervalSinceNow))]]];
        break;
    }
    static NSArray *evCache; static NSTimeInterval evAt;                     // the calendar is read at most every 30 s
    if (!evCache || [NSDate date].timeIntervalSince1970 - evAt > 30) { evCache = [self nextEvent] ?: @[]; evAt = [NSDate date].timeIntervalSince1970; }
    NSArray *ev = evCache.count ? evCache : nil;
    if (ev && ![ev[1] isEqualToString:@"Calendar"]) {                            // skip the "allow access" prompt here; the glance asks
        BOOL clear = [ev[1] isEqualToString:@"Nothing else today"];
        NSString *when = [[ev[2] componentsSeparatedByString:@"  ·  "] firstObject];
        [seg addObject:@[@"calendar", clear ? @"Clear day" : [NSString stringWithFormat:@"%@  %@", oneLine(ev[1], 26), when]]];
    }
    CFTypeRef info = IOPSCopyPowerSourcesInfo(); CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    if (list && CFArrayGetCount(list) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, 0));
        if ([d[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) {
            NSInteger pct = [d[@kIOPSCurrentCapacityKey] integerValue] * 100 / MAX([d[@kIOPSMaxCapacityKey] integerValue], 1);
            BOOL chg = [d[@kIOPSIsChargingKey] boolValue];
            NSString *sym = chg ? @"battery.100.bolt" : pct > 80 ? @"battery.100" : pct > 55 ? @"battery.75" : pct > 30 ? @"battery.50" : pct > 12 ? @"battery.25" : @"battery.0";
            [seg addObject:@[sym, [NSString stringWithFormat:@"%ld%%", (long)pct]]];
        }
    }
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    BOOL online = NO; struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *a = ifs; a; a = a->ifa_next)
            if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP) && !(a->ifa_flags & IFF_LOOPBACK) && strncmp(a->ifa_name, "en", 2) == 0) { online = YES; break; }
        freeifaddrs(ifs);
    }
    [seg addObject:online ? @[@"wifi", @"Online"] : @[@"wifi.slash", @"Offline"]];
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale autoupdatingCurrentLocale];
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEdMMMjmm" options:0 locale:f.locale];
    [seg insertObject:@[@"", [[f stringFromDate:[NSDate date]] stringByReplacingOccurrencesOfString:@" " withString:@" "]] atIndex:0];   // the time leads, unadorned
    return seg;
}
- (void)updateAmbient { self.ambient.segments = [self ambientSegments]; }
@end
