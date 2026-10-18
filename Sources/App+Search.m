// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"

@implementation CApp (Search)

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
    [a addObject:mk(@"Clear Clipboard", @"Clears the clipboard and Centre's clipboard history", @"System", @"doc.on.clipboard", ^{ [[NSPasteboard generalPasteboard] clearContents]; [ws.clips removeAllObjects]; showHUD(@"Clipboard cleared", @"checkmark.circle.fill"); })];
    [a addObject:mk(@"Generate Password", @"Copies a strong 20-character password  \u00B7  type  pw 32  for more options", @"Password", @"key.fill", ^{ copySecret(genPassword(20, YES)); })];
    // Window management
    NSDictionary *wins = @{ @"Window: Left Half": @"left", @"Window: Right Half": @"right", @"Window: Top Half": @"top",
                            @"Window: Bottom Half": @"bottom", @"Window: Maximize": @"max", @"Window: Center": @"center",
                            @"Window: Left Third": @"leftThird", @"Window: Center Third": @"centerThird", @"Window: Right Third": @"rightThird",
                            @"Window: Left Two Thirds": @"leftTwoThirds", @"Window: Right Two Thirds": @"rightTwoThirds",
                            @"Window: Next Display": @"nextDisplay" };
    for (NSString *k in wins) {
        NSString *mode = wins[k];
        [a addObject:mk(k, @"Front window of the app you were using", @"Window", @"macwindow", ^{ moveFrontWindow(ws.previousApp, mode); })];
    }
    BOOL awake = self.awakeAssertion != 0;
    CItem *aw = mk(@"Keep Awake", awake ? @"On — your Mac won't sleep · ↩ turns it off" : @"Stops your Mac and display sleeping until you turn it off",
                   @"Awake", awake ? @"sun.max.fill" : @"sun.max", ^{ [ws toggleKeepAwake]; });
    aw.verb = awake ? @"Turn Off" : @"Turn On";
    [a addObject:aw];
    // Doorways into Centre's modes: pin them, or give them their own shortcut
    CItem *(^door)(NSString *, NSString *, NSString *, NSString *, NSString *) = ^CItem *(NSString *t, NSString *sub, NSString *kind, NSString *sym, NSString *q) {
        CItem *d = mk(t, sub, kind, sym, ^{ [ws enterQuery:q]; }); d.keepsPanel = YES; d.verb = @"Open"; return d; };
    [a addObject:door(@"Switch Window", @"Every open window, searchable  ·  or type  w  and a space", @"Open Window", @"macwindow.on.rectangle", @"w ")];
    [a addObject:door(@"Transform Text", @"Change the selection or clipboard: case, JSON, Base64, clean URLs…  ·  tx", @"Transform", @"wand.and.stars", @"tx ")];
    [a addObject:door(@"Snippets", @"Saved text you paste anywhere  ·  snip", @"Snippet", @"text.quote", @"snip ")];
    [a addObject:door(@"Emoji", @"Search every emoji by name  ·  or type :name", @"Emoji", @"face.smiling", @":")];
    [a addObject:door(@"System Info", @"Battery, IP address, disk space, uptime  ·  info", @"Info", @"info.circle", @"info")];
    // Centre
    [a addObject:mk(@"Centre: Settings", @"Hotkey, links, search prefixes, app folders", @"Centre", @"slider.horizontal.3", ^{ [ws openSettings]; })];
    [a addObject:mk(@"Centre: Rescan Apps", nil, @"Centre", @"arrow.triangle.2.circlepath", ^{ [ws scanApps]; })];
    [a addObject:mk(@"Centre: Rebuild", @"Recompile from Sources and relaunch (no Terminal needed)", @"Centre", @"hammer", ^{ [ws rebuild]; })];
    [a addObject:mk(@"Centre: Toggle Start at Login", nil, @"Centre", @"sunrise", ^{ [ws toggleLoginItem]; })];
    [a addObject:mk(@"Centre: Grant Accessibility", @"Needed for window commands and auto-paste", @"Centre", @"hand.raised", ^{ [ws grantAX]; })];
    [a addObject:mk(@"Centre: Quit", nil, @"Centre", @"xmark", ^{ [NSApp terminate:nil]; })];
    for (CItem *c in a) c.key = [@"cmd:" stringByAppendingString:c.title];
    NSDictionary *confirm = @{ @"Restart": @"Press ↩ again to restart", @"Shut Down": @"Press ↩ again to shut down",
                               @"Log Out": @"Press ↩ again to log out", @"Empty Trash": @"Press ↩ again — this can't be undone",
                               @"Quit All Apps": @"Press ↩ again to quit every app" };
    for (CItem *c in a) c.confirm = confirm[c.title];
    NSDictionary *synonyms = @{ @"Clear Clipboard": @"empty clipboard delete clipboard history wipe",
                                @"Empty Trash": @"clear trash delete bin", @"Lock Screen": @"lock mac",
                                @"Sleep": @"sleep mac suspend", @"Toggle Dark Mode": @"light mode appearance theme",
                                @"Show Desktop": @"hide all apps windows", @"Mute / Unmute": @"sound volume audio silence",
                                @"Shut Down": @"power off turn off", @"Quit All Apps": @"close all apps",
                                @"Toggle Hidden Files": @"show hidden dotfiles", @"Generate Password": @"new password random",
                                @"Keep Awake": @"caffeinate no sleep prevent sleep stay awake", @"Window: Next Display": @"move window other screen monitor",
                                @"Switch Window": @"windows switcher tabs alt tab", @"Transform Text": @"uppercase lowercase case json base64 format convert text",
                                @"Snippets": @"text expander templates canned replies", @"Emoji": @"emoji smiley symbols picker",
                                @"System Info": @"battery ip address disk space uptime memory about this mac" };
    for (CItem *c in a) c.keywords = synonyms[c.title];
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

// Calculator and unit conversions ("12*7+3", "15% of 200", "5 km to mi"). Logic lives in Util.m and is self-tested.
- (CItem *)calcItem:(NSString *)q {
    double result = 0;
    NSString *converted = convertUnits(q, &result);
    if (!converted && !evaluateMath(q, &result)) return nil;
    NSString *plain = [NSString stringWithFormat:@"%.10g", result];
    CItem *i = mk([@"= " stringByAppendingString:converted ?: formatNumber(result)], q, @"Calculator", converted ? @"arrow.left.arrow.right" : @"function", ^{
        copyText(plain); showHUD([@"Copied " stringByAppendingString:plain], @"checkmark.circle.fill"); });
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
        i.key = url;                                   // runSelected records use by key; pins and hotkeys use it too
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
            } else showHUD(@"Copied · paste with ⌘V", @"doc.on.clipboard.fill");
        });
        i.altAction = ^{ copyText(c); showHUD(@"Copied", @"doc.on.clipboard.fill"); }; i.altHint = @"⌘↩ Copy";
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
        NSMutableSet *shown = [NSMutableSet new]; for (CItem *i in all) if (i.path) [shown addObject:i.path];
        files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CItem *f, id _) { return ![shown containsObject:f.path]; }]];
        NSInteger keep = MIN((NSInteger)files.count, MAX(room, 2));
        [all addObjectsFromArray:[files subarrayWithRange:NSMakeRange(0, keep)]];
        for (CItem *i in self.items) if ([i.kind isEqualToString:@"Web"]) [all addObject:i];
    }
    if (all.count > kMaxRows) all = [[all subarrayWithRange:NSMakeRange(0, kMaxRows)] mutableCopy];
    self.items = all; self.selected = MIN(self.selected, MAX(0, (NSInteger)all.count - 1));
    [self reloadTable];
}

#pragma mark Folders and paths

- (CItem *)fileItem:(NSString *)path folder:(BOOL)folder score:(double)score {
    NSString *tilde = [path stringByAbbreviatingWithTildeInPath];
    CItem *i = [CItem new];
    i.title = [path isEqualToString:@"/"] ? @"Macintosh HD" : [[NSFileManager defaultManager] displayNameAtPath:path];
    i.subtitle = [tilde.stringByDeletingLastPathComponent isEqualToString:@""] ? @"/" : tilde.stringByDeletingLastPathComponent;
    i.kind = folder ? @"Folder" : @"File"; i.path = path; i.score = score;
    i.completion = folder ? ([tilde hasSuffix:@"/"] ? tilde : [tilde stringByAppendingString:@"/"]) : tilde;
    __weak CApp *ws = self;
    i.action = ^{ [ws recordUse:path]; [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]]; };
    i.altAction = ^{ [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""]; };
    i.altHint = @"⌘↩ Reveal in Finder";
    return i;
}

// "/documents", "~/doc/rep", "/applications/saf": the folder or file, never a web search. Tab completes like a shell.
- (NSArray<CItem *> *)pathItems:(NSString *)q {
    NSDictionary *res = pathCompletions(q, NSHomeDirectory(), kMaxRows);
    NSMutableArray *r = [NSMutableArray new];
    NSString *dir = res[@"dir"];
    BOOL browsing = [q hasSuffix:@"/"] || [q isEqualToString:@"~"];
    if (dir && browsing) {
        CItem *here = [self fileItem:dir folder:YES score:1000];
        here.title = [@"Open " stringByAppendingString:here.title]; here.verb = @"Open Folder";
        [r addObject:here];
    }
    for (NSDictionary *f in res[@"items"]) {
        CItem *i = [self fileItem:f[@"path"] folder:[f[@"dir"] boolValue] score:[f[@"score"] doubleValue]];
        [r addObject:i];
    }
    if (!r.count) {
        NSString *where = dir ? [dir stringByAbbreviatingWithTildeInPath] : nil;
        CItem *none = mk(where ? [NSString stringWithFormat:@"Nothing matching in %@", where] : @"No folder by that name",
                         @"Tab completes names · ~ is your home folder", @"Folder", @"folder", ^{});
        if (dir) none.action = ^{ [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]]; };
        [r addObject:none];
    }
    if (r.count > kMaxRows) [r removeObjectsInRange:NSMakeRange(kMaxRows, r.count - kMaxRows)];
    return r;
}

// Standard folders and everything visible in the home folder, so "documents" or "downloads" opens the folder.
- (NSArray<CItem *> *)folderItemsFor:(NSString *)q {
    static NSArray<NSString *> *cached; static NSDate *stamp;
    if (!cached || -stamp.timeIntervalSinceNow > 30) {
        NSString *home = NSHomeDirectory(); NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableOrderedSet *paths = [NSMutableOrderedSet orderedSetWithObjects:home, @"/Applications", nil];
        for (NSString *n in [fm contentsOfDirectoryAtPath:home error:nil]) {
            BOOL d = NO; NSString *p = [home stringByAppendingPathComponent:n];
            if (![n hasPrefix:@"."] && [fm fileExistsAtPath:p isDirectory:&d] && d) [paths addObject:p];
        }
        NSString *icloud = [home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs"];
        if ([fm fileExistsAtPath:icloud]) [paths addObject:icloud];
        cached = paths.array; stamp = [NSDate date];
    }
    NSMutableArray *r = [NSMutableArray new];
    for (NSString *p in cached) {
        NSString *name = [p isEqualToString:NSHomeDirectory()] ? @"Home" : [p hasSuffix:@"CloudDocs"] ? @"iCloud Drive" : p.lastPathComponent;
        double s = fuzzyScore(q, name);
        if (s < 0 && [p isEqualToString:NSHomeDirectory()]) s = fuzzyScore(q, NSUserName());
        if (s < 0) continue;
        CItem *i = [self fileItem:p folder:YES score:s - 6 + [self usageBoost:p]];
        i.title = name;
        [r addObject:i];
    }
    return r;
}

#pragma mark Query → items

- (void)refresh {
    NSString *q = [self.field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    self.currentQuery = q;
    self.modeLabel = nil;
    self.armedItem = nil; self.armedSubtitle = nil;          // new items, nothing armed
    [self stopFileSearch];
    NSMutableArray *out = [NSMutableArray new];
    NSComparator byScore = ^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame; };

    if (!q.length) { [self buildHome]; return; }
    self.gridMode = NO;
    NSString *lower = q.lowercaseString;
    NSRange sp = [q rangeOfString:@" "];
    NSString *head = sp.location == NSNotFound ? lower : [lower substringToIndex:sp.location];
    NSString *rest = sp.location == NSNotFound ? @"" : [[q substringFromIndex:sp.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // "w " (just the keyword and a space) already means the mode, even though the query itself is trimmed
    NSString *raw = self.field.stringValue;
    BOOL spaced = sp.location != NSNotFound || ([raw hasSuffix:@" "] && raw.length > q.length);
    if ([q hasPrefix:@":"] || ([head isEqualToString:@"emoji"] && spaced)) {
        self.modeLabel = @"Emoji";
        NSString *eq = [q hasPrefix:@":"] ? [[q substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : rest;
        [out addObjectsFromArray:[self emojiItems:eq]];
    } else if (([head isEqualToString:@"w"] && spaced) || [head isEqualToString:@"windows"] || ([head isEqualToString:@"switch"] && spaced)) {
        self.modeLabel = @"Windows";
        [out addObjectsFromArray:[self windowItems:rest]];
    } else if (([head isEqualToString:@"tx"] || [head isEqualToString:@"transform"]) && (spaced || [head isEqualToString:@"tx"])) {
        self.modeLabel = self.selectedText.length ? @"Transform Selection" : @"Transform Clipboard";
        [out addObjectsFromArray:[self transformItems:rest]];
    } else if ([head isEqualToString:@"snip"] || [head isEqualToString:@"snippets"] || [head isEqualToString:@"snippet"]) {
        self.modeLabel = @"Snippets";
        NSArray *sn = [self snippetItems:rest];
        if (sn.count) [out addObjectsFromArray:sn];
        else {
            __weak CApp *ws = self;
            CItem *e = mk(rest.length ? @"No snippet matches" : @"No snippets yet", @"↩ opens Settings › Snippets to add one", @"Snippet", @"text.quote", ^{ [ws openSettingsPage:@"Snippets"]; });
            e.verb = @"Open Settings"; [out addObject:e];
        }
    } else if ([head isEqualToString:@"port"] && spaced) {
        self.modeLabel = @"Port";
        [out addObjectsFromArray:[self portItems:rest]];
    } else if (([head isEqualToString:@"info"] || [head isEqualToString:@"sysinfo"]) && !rest.length) {
        self.modeLabel = @"System Info";
        [out addObjectsFromArray:[self systemInfoItems]];
    } else if ([head isEqualToString:@"kill"] || [head isEqualToString:@"quit"]) {
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
    } else if ([q hasPrefix:@"/"] || [q hasPrefix:@"~"]) {
        self.modeLabel = @"Folders";
        [out addObjectsFromArray:[self pathItems:q]];
    } else if ([q hasPrefix:@">"]) {
        self.modeLabel = @"Shell";
        NSString *cmd = [[q substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        CItem *i = mk([@"Run in Terminal: " stringByAppendingString:cmd], @"⌘↩ Run silently and copy output", @"Shell", @"terminal", ^{
            NSString *esc = [cmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]; esc = [esc stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            osa([NSString stringWithFormat:@"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell", esc]);
        });
        i.altAction = ^{ runUserShell(cmd, ^(NSString *o) { copyText(o); showHUD(o.length ? @"Output copied" : @"Done · no output", @"terminal.fill"); }); };
        [out addObject:i];
    } else if ([head isEqualToString:@"pw"] || [head isEqualToString:@"pwgen"] || ([head isEqualToString:@"password"] && rest.length)) {
        self.modeLabel = @"Password";
        [out addObjectsFromArray:[self passwordItems:rest]];
    } else if ([head isEqualToString:@"define"]) {
        self.modeLabel = @"Dictionary";
        [out addObjectsFromArray:[self defineItems:rest]];
    } else if ([head isEqualToString:@"timer"] || [head isEqualToString:@"timers"]) {
        self.modeLabel = @"Timer";
        [out addObjectsFromArray:[self timerItems:rest]];
    } else if (([head isEqualToString:@"vol"] || [head isEqualToString:@"volume"]) && rest.length) {
        self.modeLabel = @"Volume";
        [out addObjectsFromArray:[self volumeItems:rest]];
    } else if ([self.config[@"searchPrefixes"] isKindOfClass:[NSDictionary class]] && [self.config[@"searchPrefixes"][head] isKindOfClass:[NSString class]] && rest.length) {
        NSString *tpl = self.config[@"searchPrefixes"][head];
        NSString *host = [NSURL URLWithString:[tpl stringByReplacingOccurrencesOfString:@"%s" withString:@""]].host;
        if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
        self.modeLabel = host.length ? host : head;
        NSString *url = [tpl stringByReplacingOccurrencesOfString:@"%s" withString:urlEncode(rest)];
        [out addObject:mk([NSString stringWithFormat:@"Search %@ for “%@”", head, rest], url, @"Web", @"magnifyingglass", ^{ openURLString(url); })];
    } else {
        CItem *calc = [self timeItem:q] ?: [self calcItem:q]; if (calc) [out addObject:calc];
        CItem *url = [self urlItem:q]; if (url) [out addObject:url];
        NSMutableArray *general = [NSMutableArray new];
        [general addObjectsFromArray:[self appItemsFor:q]];
        [general addObjectsFromArray:[self linkItemsFor:q]];
        [general addObjectsFromArray:[self folderItemsFor:q]];
        [general addObjectsFromArray:[self customItemsFor:q]];
        [general addObjectsFromArray:[self snippetItems:q]];
        for (CItem *c in [self appContextItems]) { double s = fuzzyScore(q, c.title); if (s >= 0) { c.score = s - 10; [general addObject:c]; } }
        if (q.length >= 3) for (NSString *n in transformNames()) {           // "upper" → UPPERCASE the selection or clipboard
            BOOL prefix = NO;
            for (NSString *w in [[n.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "] componentsSeparatedByString:@" "]) if ([w hasPrefix:lower]) prefix = YES;
            double s = fuzzyScore(q, n); if (!prefix || s < 0) continue;
            CItem *t = [self transformItem:n]; t.score = s - 14; [general addObject:t];
        }
        if (q.length >= 2 && self.windowList.count) {                      // a window whose title you remember
            NSInteger n = 0;
            for (CItem *w in [self windowItems:q]) { if (w.score < 60 || n++ >= 2) break; w.score -= 18; [general addObject:w]; }
        }
        for (CItem *c in [self systemCommands]) {
            double s = fuzzyScore(q, c.title);
            if (c.keywords.length) {                      // synonyms match too, a little below an exact title match
                double ks = fuzzyScore(q, c.keywords); if (ks >= 0) s = MAX(s, ks - 2);
            }
            if (s < 0) continue;
            c.score = s - 8 + [self usageBoost:c.key] - (c.confirm.length || [c.title isEqualToString:@"Centre: Quit"] ? 6 : 0);
            [general addObject:c];
        }
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
@end
