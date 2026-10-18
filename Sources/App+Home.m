// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"

@implementation CApp (Home)

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
    if (self.timers.count) {   // running timers come first: they're time-sensitive
        NSArray *ts = [self activeTimerItems];
        [entries addObject:@"Timers"]; [entries addObjectsFromArray:ts]; [rows addObjectsFromArray:ts];
    }
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
    if (self.armedItem && self.items[i] != self.armedItem) [self disarm];
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
@end
