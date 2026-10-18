// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"
#import "Settings.h"
#import <ServiceManagement/ServiceManagement.h>


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
            BOOL isDir = NO;   // skip broken symlinks and Finder alias files that only look like apps
            if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return;
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
            NSString *fill = i.completion.length ? i.completion
                           : ([i.kind isEqualToString:@"Application"] || [i.kind isEqualToString:@"Recent"]) ? i.title : nil;
            if (fill) { self.field.stringValue = fill; [tv setSelectedRange:NSMakeRange(fill.length, 0)]; [self refresh]; } }
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
    BOOL wasFailed = self.hotkeyFailed;
    self.hotkeyFailed = (st != noErr);
    if (st == noErr) self.hotKeyRef = ref;
    else {
        NSLog(@"Centre: could not register hotkey %@ (err %d)", spec, (int)st);
        if (!wasFailed && !self.snapshotDir)   // say it once, not on every config reload
            showHUDFor([NSString stringWithFormat:@"%@ is taken by another app — pick a new shortcut in Settings", prettyHotkey(spec)], @"exclamationmark.triangle.fill", 4);
    }
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
// macOS 13+: a real login item (SMAppService). Older systems: System Events.
- (BOOL)launchesAtLogin {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return [self.config[@"launchAtLogin"] boolValue];
}
- (void)setLaunchAtLogin:(BOOL)on {
    if (@available(macOS 13.0, *)) {
        NSError *e = nil;
        BOOL ok = on ? [SMAppService.mainAppService registerAndReturnError:&e] : [SMAppService.mainAppService unregisterAndReturnError:&e];
        if (!ok && on) showHUDFor(@"macOS didn't add Centre to Login Items — check System Settings › General", @"exclamationmark.triangle.fill", 4);
        if (on)   // drop any old-style item so Centre doesn't start twice
            osa(@"tell application \"System Events\"\nif exists login item \"Centre\" then delete login item \"Centre\"\nend tell");
        return;
    }
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    NSString *s = on
        ? [NSString stringWithFormat:@"tell application \"System Events\"\nif not (exists login item \"Centre\") then make login item at end with properties {path:\"%@\", hidden:true}\nend tell", bundle]
        : @"tell application \"System Events\"\nif exists login item \"Centre\" then delete login item \"Centre\"\nend tell";
    osa(s);
}
- (void)resetUsage { self.usage = [NSMutableDictionary new]; [[NSFileManager defaultManager] removeItemAtPath:self.usagePath error:nil]; }
// A switch left on from an earlier build belongs to that build's signature: it looks granted but doesn't apply.
// Clear Centre's entry first so macOS asks fresh and the new switch belongs to this build.
- (void)grantAX {
    if (AXIsProcessTrusted()) return;
    runShell(@"/usr/bin/tccutil reset Accessibility com.y.centre", ^(NSString *out) {
        NSDictionary *o = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
        openURLString(@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
    });
}
- (void)toggleLoginItem {
    BOOL on = ![self launchesAtLogin];
    [self setLaunchAtLogin:on];
    showHUD(on ? @"Centre will start at login" : @"Centre won't start at login", @"sunrise.fill");
}

#pragma mark Self-rebuild
- (NSString *)sourceDir { return [[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent]; }
// Newest modification time across Sources/*.m and *.h.
- (NSDate *)sourceDate {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self.sourceDir stringByAppendingPathComponent:@"Sources"];
    NSDate *newest = nil;
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![n.pathExtension isEqualToString:@"m"] && ![n.pathExtension isEqualToString:@"h"]) continue;
        NSDate *d = [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:n] error:nil] fileModificationDate];
        if (d && (!newest || [d compare:newest] == NSOrderedDescending)) newest = d;
    }
    return newest;
}
- (BOOL)sourceIsNewer {
    NSDate *s = [self.sourceDate copy]; if (!s) return NO;
    NSDate *b = [[[NSFileManager defaultManager] attributesOfItemAtPath:[NSBundle mainBundle].executablePath error:nil] fileModificationDate];
    return !b || [s compare:b] == NSOrderedDescending;   // a missing binary always counts as out of date
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
            [self saveClipHandoff];
            NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh";
            t.arguments = @[@"-c", [NSString stringWithFormat:@"sleep 1; open '%@'", [NSBundle mainBundle].bundlePath]];
            [t launch];
            [NSApp terminate:nil];
            return;
        }
        self.rebuilding = NO; self.failedSource = src;
        if (quiet) { showHUDFor(@"Centre's rebuild failed — details in build.log", @"exclamationmark.triangle.fill", 4); return; }
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *al = [NSAlert new]; al.messageText = @"Centre could not rebuild";
        al.informativeText = out.length > 3000 ? [out substringFromIndex:out.length - 3000] : out;
        [al runModal];
    });
}

#pragma mark Clipboard hand-off
// History is memory-only. Across a self-rebuild it is passed to the new process through a private (0600) file
// that the new process deletes on launch; a hand-off older than two minutes is discarded unread.
- (NSString *)handoffPath { return [supportDir() stringByAppendingPathComponent:@".clips-handoff"]; }
- (void)saveClipHandoff {
    if (!self.clips.count) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.clips options:0 error:nil];
    if (d) [[NSFileManager defaultManager] createFileAtPath:self.handoffPath contents:d attributes:@{NSFilePosixPermissions: @0600}];
}
- (void)loadClipHandoff {
    NSFileManager *fm = [NSFileManager defaultManager]; NSString *p = self.handoffPath;
    NSDictionary *at = [fm attributesOfItemAtPath:p error:nil]; if (!at) return;
    NSData *d = [NSData dataWithContentsOfFile:p];
    [fm removeItemAtPath:p error:nil];
    if (-[at.fileModificationDate timeIntervalSinceNow] > 120 || !d) return;
    NSArray *a = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![a isKindOfClass:[NSArray class]]) return;
    for (id x in a) if ([x isKindOfClass:[NSString class]] && self.clips.count < 100) [self.clips addObject:x];
}

#pragma mark Lifecycle
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (self.snapshotDir) { [self runSnapshots]; return; }
    if ([self sourceIsNewer]) { [self rebuild]; return; }
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.y.centre.show" object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { [self show]; }];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.iconCache = [NSMutableDictionary new]; self.clips = [NSMutableArray new]; self.items = @[];
    [self loadClipHandoff];
    self.pbCount = [NSPasteboard generalPasteboard].changeCount;
    [self loadUsage]; [self loadConfig];
    [self buildUI];
    [self startMediaObservers];
    [self registerHotKey];
    [self updateStatusItem];
    [self scanApps];
    [self startRecentFilesQuery];
    [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(pollClipboard) userInfo:nil repeats:YES];
    // Auto-rebuild: when anything in Sources/ changes, recompile and relaunch (only while the panel is hidden).
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
