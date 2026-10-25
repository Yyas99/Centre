// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"
#include <signal.h>
#import "Settings.h"
#import "Taskbar.h"
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
    if (![c isKindOfClass:[NSDictionary class]]) {
        // A typo (say, a trailing comma) must never cost you your commands and snippets: keep a copy of the file,
        // keep using the last good settings, and say so once.
        self.configMtime = mt;
        NSString *broken = [p stringByAppendingString:@".broken"];
        [fm removeItemAtPath:broken error:nil]; [fm copyItemAtPath:p toPath:broken error:nil];
        if (!self.snapshotDir) showHUDFor(@"config.json has a typo — Centre kept your last good settings (copy saved as config.json.broken)", @"exclamationmark.triangle.fill", 5);
        if (self.config) return;
        c = @{};
    }
    NSDictionary *old = self.config;
    NSString *oldHK = old[@"hotkey"];
    self.config = c; self.configMtime = mt;
    if (oldHK && ![oldHK isEqualToString:(c[@"hotkey"] ?: @"cmd+space")]) [self registerHotKey];
    if (old && ![old isEqualToDictionary:c] && !self.snapshotDir) {   // edited here or in a text editor: everything follows
        [self registerCommandHotKeys];
        [self updateStatusItem];
        [self.taskbar apply];
        if (self.shelf) [self updateShelfFloat];
    }
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
    NSDictionary *e = [self.usage[key] isKindOfClass:[NSDictionary class]] ? self.usage[key] : @{};
    NSInteger n = [e[@"count"] integerValue] + 1;
    // Timed suggestions: when in the day you use it (24 hourly counts), and which app you were in.
    NSMutableArray *h = [e[@"h"] isKindOfClass:[NSArray class]] && [e[@"h"] count] == 24 ? [e[@"h"] mutableCopy] : nil;
    if (!h) { h = [NSMutableArray new]; for (int k = 0; k < 24; k++) [h addObject:@0]; }
    NSInteger hr = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    h[hr] = @([h[hr] integerValue] + 1);
    NSMutableDictionary *apps = [e[@"apps"] isKindOfClass:[NSDictionary class]] ? [e[@"apps"] mutableCopy] : [NSMutableDictionary new];
    if (self.contextBundleID.length) {
        apps[self.contextBundleID] = @([apps[self.contextBundleID] integerValue] + 1);
        while (apps.count > 12) {                                  // keep the strongest dozen
            NSString *weakest = [apps keysSortedByValueUsingSelector:@selector(compare:)].firstObject; [apps removeObjectForKey:weakest];
        }
    }
    self.usage[key] = @{@"count": @(n), @"last": @([NSDate date].timeIntervalSince1970), @"h": h, @"apps": apps};
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
    id cfg = self.config[@"appFolders"];
    NSArray *folders = [cfg isKindOfClass:[NSArray class]] && [cfg count] ? cfg : @[@"/Applications", @"/System/Applications", @"/System/Applications/Utilities", @"~/Applications"];
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
    BOOL up = GetEventKind(evt) == kEventHotKeyReleased;
    if (which == 1) { dispatch_async(dispatch_get_main_queue(), ^{ if (up) [app hotKeyReleased]; else [app hotKeyPressed]; }); return noErr; }   // tap opens; hold peeks
    if (up) return noErr;
    else if (which >= 100) dispatch_async(dispatch_get_main_queue(), ^{ [app runHotKeyCommand:which - 100]; });   // per-command shortcuts
    return noErr;
}
- (void)registerHotKey {
    static BOOL installed = NO;
    if (!installed) {
        EventTypeSpec spec[2] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
        InstallApplicationEventHandler(&hotKeyHandler, 2, spec, (__bridge void *)self, NULL);
        installed = YES;
    }
    if (self.hotKeyRef) { UnregisterEventHotKey(self.hotKeyRef); self.hotKeyRef = NULL; }
    NSString *spec = [([self.config[@"hotkey"] isKindOfClass:[NSString class]] ? self.config[@"hotkey"] : @"cmd+space") lowercaseString];
    UInt32 mods = 0, key = 0;
    if (!parseHotkey(spec, &key, &mods)) { spec = @"cmd+space"; key = kVK_Space; mods = cmdKey; }   // never a bare key grabbed system-wide
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
        // Centre's mark, drawn for the menu bar: an open ring around a solid core, like the app icon.
        NSImage *si = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
            [[NSColor blackColor] set];
            NSBezierPath *ring = [NSBezierPath bezierPath];
            [ring appendBezierPathWithArcWithCenter:NSMakePoint(9, 9) radius:6.6 startAngle:42 endAngle:318];
            ring.lineWidth = 1.9; ring.lineCapStyle = NSLineCapStyleRound; [ring stroke];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(9 - 2.3, 9 - 2.3, 4.6, 4.6)] fill];
            return YES; }];
        si.template = YES; si.accessibilityDescription = @"Centre";
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
    if (![self isDevelopmentCopy])
        [m addItemWithTitle:self.update ? [NSString stringWithFormat:@"Install Centre %@", self.update[@"version"]] : @"Check for Updates…"
                     action:@selector(installUpdate) keyEquivalent:@""].target = self;
    if (!AXIsProcessTrusted()) [m addItemWithTitle:@"Allow Accessibility…" action:@selector(grantAX) keyEquivalent:@""].target = self;
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Quit Centre" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    self.status.menu = m;
}

#pragma mark Settings
- (void)openSettings {
    [self hide];
    if (!self.settings) self.settings = [[CSettings alloc] initWithApp:self];
    [self.settings show];
}
- (void)openSettingsPage:(NSString *)name {
    [self openSettings];
    [self.settings showPageNamed:name];
}
- (NSMutableDictionary *)mutableConfig { [self loadConfig]; return [self.config mutableCopy] ?: [NSMutableDictionary new]; }
- (void)writeConfig:(NSDictionary *)c {
    NSData *d = [NSJSONSerialization dataWithJSONObject:c options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!d) return;
    id oldFolders = self.config[@"appFolders"];
    [d writeToFile:self.configPath atomically:YES];
    self.configMtime = nil; [self loadConfig];                       // applies hotkeys, menu bar icon and taskbar
    if (![oldFolders isEqual:self.config[@"appFolders"]]) [self scanApps];
}
// macOS 13+: a real login item (SMAppService). Older systems: System Events.
- (BOOL)launchesAtLogin {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return [self.config[@"launchAtLogin"] boolValue];
}
- (void)setLaunchAtLogin:(BOOL)on {
    NSMutableDictionary *c = [self mutableConfig];                     // your choice, kept apart from what macOS currently reports
    if ([c[@"launchAtLogin"] boolValue] != on) { c[@"launchAtLogin"] = @(on); [self writeConfig:c]; }
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
// Asks macOS for Accessibility and opens its settings. Never resets an existing entry: every build is signed
// with the same certificate, so a switch you turned on once keeps applying.
- (void)grantAX {
    if (AXIsProcessTrusted()) return;
    NSDictionary *o = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
    openURLString(@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
}
// Uninstall: put the Dock back, leave Login Items, move the app to the Bin and quit. Settings are kept.
- (void)uninstall {
    NSAlert *a = [NSAlert new]; a.messageText = @"Uninstall Centre?";
    a.informativeText = @"Centre puts your Dock back as it was, removes itself from Login Items, moves itself to the Bin and quits. "
                        "Your settings stay in ~/Library/Application Support/Centre in case you reinstall.";
    [a addButtonWithTitle:@"Uninstall"]; [a addButtonWithTitle:@"Cancel"];
    a.buttons.firstObject.hasDestructiveAction = YES;
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [self trace:@"uninstalling"];
    [self.taskbar restoreDockNow];
    if (@available(macOS 13.0, *)) [SMAppService.mainAppService unregisterAndReturnError:nil];
    NSMutableDictionary *c = [self mutableConfig]; c[@"launchAtLogin"] = @NO; [c removeObjectForKey:@"loginItemPath"]; [self writeConfig:c];
    [[NSWorkspace sharedWorkspace] recycleURLs:@[[NSBundle mainBundle].bundleURL] completionHandler:^(NSDictionary *moved, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    }];
}
- (void)toggleLoginItem {
    BOOL on = ![self launchesAtLogin];
    [self setLaunchAtLogin:on];
    showHUD(on ? @"Centre will start at login" : @"Centre won't start at login", @"sunrise.fill");
}

#pragma mark Self-rebuild
- (NSString *)sourceDir { return [[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent]; }
// The development copy lives beside its source and rebuilds itself; an installed copy (/Applications) never does.
- (BOOL)isDevelopmentCopy {
    static BOOL dev; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *d = self.sourceDir; NSFileManager *fm = [NSFileManager defaultManager];
        dev = [fm fileExistsAtPath:[d stringByAppendingPathComponent:@"Sources"]] && [fm fileExistsAtPath:[d stringByAppendingPathComponent:@"centre"]];
    });
    return dev;
}
// Newest modification time across Sources/*.m and *.h.
- (NSDate *)sourceDate {
    if (![self isDevelopmentCopy]) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self.sourceDir stringByAppendingPathComponent:@"Sources"];
    NSDate *newest = nil;
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![n.pathExtension isEqualToString:@"m"] && ![n.pathExtension isEqualToString:@"h"]) continue;
        NSDate *d = [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:n] error:nil] fileModificationDate];
        if ([d timeIntervalSinceNow] > 5) { NSLog(@"Centre: %@ is dated in the future; ignoring it for rebuilds", n); continue; }
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
// A build installed after this process started (by the agent, or by Terminal). It must have settled: the build
// script signs the binary just after installing it, and holds its lock until then.
- (BOOL)installedBuildIsNewer {
    static NSDate *launched; static dispatch_once_t once;
    if (![self isDevelopmentCopy]) return NO;                 // the installed copy is replaced only by an install, after it quits
    NSString *bin = [NSBundle mainBundle].executablePath, *lock = [self.sourceDir stringByAppendingPathComponent:@".agent/build.lock"];
    NSDate *now = [[[NSFileManager defaultManager] attributesOfItemAtPath:bin error:nil] fileModificationDate];
    dispatch_once(&once, ^{ launched = now; });
    if (!now || !launched || [now compare:launched] != NSOrderedDescending) return NO;
    return -[now timeIntervalSinceNow] > 3 && ![[NSFileManager defaultManager] fileExistsAtPath:lock];
}
// Hand over to the fresh binary: a helper waits until this process has really exited, then opens the new build
// (opening earlier would just wake the dying copy, or the new one would defer to it and quit).
- (void)relaunch {
    [self trace:@"relaunching into the new build"];
    self.relaunchPending = NO;
    [self saveClipHandoff];
    NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh";
    // If the new copy still doesn't show up a few seconds later (it lost a race at launch), open it once more.
    NSString *app = shellQuote([NSBundle mainBundle].bundlePath), *bin = shellQuote([NSBundle mainBundle].executablePath.lastPathComponent);
    t.arguments = @[@"-c", [NSString stringWithFormat:@"while kill -0 %d 2>/dev/null; do sleep 0.1; done; sleep 0.3; open %@; "
                            "for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -qx %@ && exit 0; sleep 0.5; done; open %@", getpid(), app, bin, app]];
    [t launch];
    [NSApp terminate:nil];
}
// quiet = triggered by the file watcher: a failed build is logged to build.log and retried on the next save, no alert.
- (void)rebuildQuietly:(BOOL)quiet {
    NSString *dir = self.sourceDir;
    if (self.rebuilding || ![self isDevelopmentCopy]) return;
    self.rebuilding = YES;
    NSDate *src = [self sourceDate];
    [self trace:@"rebuilding"];
    runShell([NSString stringWithFormat:@"cd %@ && chmod +x centre && CENTRE_NO_LAUNCH=1 ./centre 2>&1", shellQuote(dir)], ^(NSString *out) {
        NSString *lastLine = [[out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"].lastObject;
        [self trace:[@"rebuild finished: " stringByAppendingString:lastLine ?: @""]];
        if (([out containsString:@"Built "] && ![out containsString:@"error:"]) || [self installedBuildIsNewer]) {   // or the agent built it first
            if (self.panel.visible || self.settings.window.visible) { self.relaunchPending = YES; return; }   // finish when you're done
            [self relaunch];
            return;
        }
        self.rebuilding = NO; self.failedSource = src;
        if (!self.panel) [self startNormally];                    // launch-time build failed: run the build we have
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
// Lifecycle log (~/Library/Logs/Centre/trace.log): launch, rebuild, relaunch, quit. "./centre trace" prints it.
- (void)trace:(NSString *)what {
    if (self.snapshotDir) return;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Centre"], *p = [dir stringByAppendingPathComponent:@"trace.log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  pid %d  %@\n", [f stringFromDate:[NSDate date]], getpid(), what];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
    if ([h seekToEndOfFile] > 200000) { [h truncateFileAtOffset:0]; }
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (self.snapshotDir) { [self runSnapshots]; return; }
    [self trace:[NSString stringWithFormat:@"launched %@ (build %@%@)", [NSBundle mainBundle].bundlePath,
                 [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?", [self sourceIsNewer] ? @", sources newer" : @""]];
    if ([self sourceIsNewer]) { [self rebuild]; return; }          // a failed build falls back to -startNormally
    [self startNormally];
}
// Everything a running Centre needs. Also the fallback when a rebuild at launch fails, so you're never left
// with a Centre that has no panel, no shortcut and no file watcher.
- (void)startNormally {
    if (self.panel) return;
    [self installedBuildIsNewer];                 // remember which build this process is
    [self trace:@"running"];
    [self startUpdateChecks];
    // A plain "kill" (an install or update quitting Centre) still quits properly, so the Dock is put back.
    signal(SIGTERM, SIG_IGN);
    static dispatch_source_t termSource;
    termSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(termSource, ^{ [NSApp terminate:nil]; });
    dispatch_resume(termSource);
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.y.centre.show" object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { [self show]; }];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];   // obsidian glass everywhere: panel, Settings, taskbar, menus
    self.iconCache = [NSMutableDictionary new]; self.clips = [NSMutableArray new]; self.items = @[];
    [self loadClipHandoff];
    self.pbCount = [NSPasteboard generalPasteboard].changeCount;
    [self loadUsage]; [self loadConfig];
    // A self-rebuild replaces and re-signs the app, and macOS can drop it from Login Items. Your choice is kept in
    // config, so every start puts it back quietly (older configs: adopt what macOS has now).
    if (@available(macOS 13.0, *)) {
        if (!self.config[@"launchAtLogin"]) { if ([self launchesAtLogin]) { NSMutableDictionary *c = [self mutableConfig]; c[@"launchAtLogin"] = @YES; [self writeConfig:c]; } }
        else if ([self.config[@"launchAtLogin"] boolValue]) {
            // The login item must start the copy you use. A development build stays out of it once Centre is
            // installed; the installed copy re-registers itself the first time it runs from a new place.
            BOOL installedExists = [[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/Centre.app"];
            NSString *here = [NSBundle mainBundle].bundlePath;
            if (![self isDevelopmentCopy] && ![self.config[@"loginItemPath"] isEqual:here]) {
                [SMAppService.mainAppService unregisterAndReturnError:nil];
                if ([SMAppService.mainAppService registerAndReturnError:nil]) {
                    NSMutableDictionary *c = [self mutableConfig]; c[@"loginItemPath"] = here; [self writeConfig:c];
                }
            } else if (![self launchesAtLogin] && !([self isDevelopmentCopy] && installedExists)) [SMAppService.mainAppService registerAndReturnError:nil];
        }
    }
    [self buildUI];
    [self startMediaObservers];
    [self registerHotKey];
    [self registerCommandHotKeys];
    [self updateStatusItem];
    [self scanApps];
    self.taskbar = [[CTaskbar alloc] initWithApp:self];
    [self.taskbar apply];
    [self startRecentFilesQuery];
    [self loadShelf]; [self updateShelfFloat]; [self startShelfWatch]; [self startPreviewWatch];
    [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(pollClipboard) userInfo:nil repeats:YES];
    // Auto-rebuild: when anything in Sources/ changes, recompile and relaunch (only while the panel is hidden).
    [NSTimer scheduledTimerWithTimeInterval:4 repeats:YES block:^(NSTimer *t) {
        if (self.relaunchPending && !self.panel.visible && !self.settings.window.visible) { [self relaunch]; return; }
        if (!self.rebuilding && !self.relaunchPending && [self installedBuildIsNewer]) { self.relaunchPending = YES; return; }   // the agent built it
        if (self.rebuilding || self.panel.visible || self.settings.window.visible || ![self sourceIsNewer]) return;
        NSDate *src = [self sourceDate];
        if (self.failedSource && src && [src isEqualToDate:self.failedSource]) return;   // same broken source: wait for the next save
        [self rebuildQuietly:YES];
    }];
    // Manual launch → show. A relaunch right after a rebuild stays hidden until the hotkey.
    NSDate *built = [[[NSFileManager defaultManager] attributesOfItemAtPath:[NSBundle mainBundle].executablePath error:nil] fileModificationDate];
    NSAppleEventDescriptor *ev = [NSAppleEventManager sharedAppleEventManager].currentAppleEvent;
    BOOL atLogin = [ev paramDescriptorForKeyword:keyAEPropData].enumCodeValue == keyAELaunchedAsLogInItem;
    // Centre never opens its panel by itself: only your shortcut does. (Login items started by macOS 13+ carry no
    // "launched at login" marker, so the old check opened the panel after every restart.) Opening it by hand from
    // Finder, minutes after startup, just says where it is.
    BOOL manual = !atLogin && [NSProcessInfo processInfo].systemUptime > 180 && (!built || -[built timeIntervalSinceNow] > 90);
    if (manual) showHUD([NSString stringWithFormat:@"Centre is ready · %@", prettyHotkey([self.config[@"hotkey"] isKindOfClass:[NSString class]] ? self.config[@"hotkey"] : @"cmd+space")], @"command");
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)a hasVisibleWindows:(BOOL)f { [self show]; return NO; }
- (void)applicationWillTerminate:(NSNotification *)n {
    [self trace:self.rebuilding ? @"quitting for the new build" : @"quitting"];
    if (self.hotKeyRef) UnregisterEventHotKey(self.hotKeyRef);
    [self unregisterCommandHotKeys];
    [self.settings flushEdits];
    if (!self.rebuilding && !self.snapshotDir) [self.taskbar restoreDockNow];
}
@end
