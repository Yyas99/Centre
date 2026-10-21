// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Everything you can run by key: built-in commands, your own commands and flows, snippets, apps and folders.
// Pins, per-command hotkeys and flows all resolve through itemForKey:, so they share one definition of "a command".
#import "App.h"

static NSString *oneLine(NSString *s, NSUInteger max) {
    NSString *t = [[[s ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length <= max) return t;
    NSUInteger end = [t rangeOfComposedCharacterSequenceAtIndex:max].location;   // never split an emoji or accented letter
    return [[t substringToIndex:end] stringByAppendingString:@"…"];
}

@implementation CApp (Library)

#pragma mark Config collections

- (NSArray<NSDictionary *> *)configList:(NSString *)key {
    NSMutableArray *r = [NSMutableArray new];
    id list = self.config[key];
    for (NSDictionary *d in ([list isKindOfClass:[NSArray class]] ? list : @[]))
        if ([d isKindOfClass:[NSDictionary class]] && [d[@"id"] isKindOfClass:[NSString class]]) [r addObject:d];
    return r;
}
// config.json can be hand-edited: keep only string values for the fields Centre reads, so a stray number or null can't crash it.
static NSDictionary *stringFields(NSDictionary *d, NSArray<NSString *> *keys) {
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithObject:d[@"id"] forKey:@"id"];
    for (NSString *k in keys) if ([d[k] isKindOfClass:[NSString class]]) r[k] = d[k];
    return r;
}
- (NSArray<NSDictionary *> *)customCommands {
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *c in [self configList:@"commands"]) {
        NSDictionary *s = stringFields(c, @[@"name", @"type", @"script", @"output", @"icon", @"keywords"]);
        if ([s[@"name"] length]) [r addObject:s];
    }
    return r;
}
- (NSArray<NSDictionary *> *)snippets {
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *d in [self configList:@"snippets"]) {
        NSDictionary *s = stringFields(d, @[@"name", @"keyword", @"text"]);
        if (s[@"text"] && ([s[@"name"] length] || [s[@"keyword"] length])) [r addObject:s];
    }
    return r;
}

#pragma mark Delivering text

// Puts text where you were typing: paste into the previous app (with Accessibility), otherwise copy.
// Pasted text is marked transient so it stays out of clipboard history, and your clipboard is put back afterwards.
- (void)deliverText:(NSString *)s paste:(BOOL)paste {
    if (!s.length) { showHUD(@"Nothing to paste", @"exclamationmark.circle.fill"); return; }
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    BOOL canPaste = paste && AXIsProcessTrusted() && self.previousApp && !self.previousApp.terminated;
    // Save every type on the clipboard (images, files, rich text), not just its plain text, to put back afterwards.
    NSMutableArray<NSPasteboardItem *> *saved = [NSMutableArray new];
    if (canPaste) for (NSPasteboardItem *it in pb.pasteboardItems) {
        NSPasteboardItem *c = [NSPasteboardItem new];
        for (NSString *t in it.types) { NSData *d = [it dataForType:t]; if (d) [c setData:d forType:t]; }
        [saved addObject:c];
    }
    BOOL secret = [pb.types containsObject:@"org.nspasteboard.ConcealedType"];
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
    if (canPaste) [pb setString:@"" forType:@"org.nspasteboard.TransientType"];
    if (!canPaste) { showHUD(paste ? @"Copied · paste with ⌘V" : @"Copied", @"doc.on.clipboard.fill"); return; }
    NSInteger mine = pb.changeCount;
    [self.previousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        simulatePaste();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSPasteboard *p = [NSPasteboard generalPasteboard];
            if (p.changeCount != mine || !saved.count) return;     // you copied something new meanwhile: leave it
            [p clearContents]; [p writeObjects:saved];
            if (secret) {                                           // a generated password still clears itself
                NSInteger cc = p.changeCount;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if ([NSPasteboard generalPasteboard].changeCount == cc) [[NSPasteboard generalPasteboard] clearContents]; });
            }
        });
    });
}

#pragma mark Your commands

- (NSString *)iconForCommand:(NSDictionary *)c {
    NSString *type = c[@"type"] ?: @"shell";
    NSString *fallback = [type isEqualToString:@"flow"] ? @"arrow.triangle.branch" : [type isEqualToString:@"applescript"] ? @"applescript" : @"terminal";
    NSString *icon = [c[@"icon"] isKindOfClass:[NSString class]] ? [c[@"icon"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
    if (icon.length && [NSImage imageWithSystemSymbolName:icon accessibilityDescription:nil]) return icon;
    return [NSImage imageWithSystemSymbolName:fallback accessibilityDescription:nil] ? fallback : @"terminal";
}

- (CItem *)customItem:(NSDictionary *)c arg:(NSString *)arg {
    NSString *type = c[@"type"] ?: @"shell", *name = c[@"name"], *script = [c[@"script"] isKindOfClass:[NSString class]] ? c[@"script"] : @"";
    BOOL flow = [type isEqualToString:@"flow"];
    BOOL takesArg = !flow && [script containsString:@"{query}"];
    __weak CApp *ws = self;
    NSString *title = arg.length ? [NSString stringWithFormat:@"%@  ›  %@", name, arg] : name;
    NSString *sub;
    if (flow) { NSUInteger n = flowSteps(script).count; sub = [NSString stringWithFormat:@"Flow · %lu step%@", (unsigned long)n, n == 1 ? @"" : @"s"]; }
    else if (takesArg && !arg.length) sub = @"Type a space, then the input";
    else sub = [@"Your command · " stringByAppendingString:oneLine(script, 60)];
    CItem *i = mk(title, sub, flow ? @"Flow" : @"Script", [self iconForCommand:c], nil);
    i.key = [@"custom:" stringByAppendingString:c[@"id"]];
    i.keywords = [c[@"keywords"] isKindOfClass:[NSString class]] ? c[@"keywords"] : nil;
    if (takesArg && !arg.length) {
        i.action = ^{ [ws askInputFor:name]; };
        i.keepsPanel = YES; i.verb = @"Add Input";
        i.completion = [name stringByAppendingString:@" "];
    } else {
        NSString *a = arg ?: @"";
        i.action = ^{ [ws runCustom:c arg:a]; };
        i.verb = flow ? @"Run Flow" : @"Run";
    }
    return i;
}

// Typing "translate hello" for a command named "Translate" that uses {query}.
- (NSArray<CItem *> *)customItemsFor:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    NSString *lower = q.lowercaseString;
    for (NSDictionary *c in [self customCommands]) {
        NSString *name = c[@"name"];
        NSString *script = [c[@"script"] isKindOfClass:[NSString class]] ? c[@"script"] : @"";
        if ([script containsString:@"{query}"] && [lower hasPrefix:[name.lowercaseString stringByAppendingString:@" "]] && q.length > name.length + 1) {
            CItem *i = [self customItem:c arg:[[q substringFromIndex:name.length + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            i.score = 2000; [r addObject:i]; continue;
        }
        double s = fuzzyScore(q, name);
        NSString *kw = [c[@"keywords"] isKindOfClass:[NSString class]] ? c[@"keywords"] : nil;
        if (kw.length) { double ks = fuzzyScore(q, kw); if (ks >= 0) s = MAX(s, ks - 2); }
        if (s < 0) continue;
        CItem *i = [self customItem:c arg:nil];
        i.score = s - 4 + [self usageBoost:i.key];
        [r addObject:i];
    }
    return r;
}

// Re-opens the panel with "Name " typed, so the next thing you type becomes the command's input.
- (void)askInputFor:(NSString *)name {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.panel.visible) [self show];
        self.field.stringValue = [name stringByAppendingString:@" "];
        NSText *ed = self.field.currentEditor; if (ed) ed.selectedRange = NSMakeRange(self.field.stringValue.length, 0);
        [self refresh];
    });
}

- (void)runCustom:(NSDictionary *)c arg:(NSString *)arg {
    NSString *type = c[@"type"] ?: @"shell", *name = c[@"name"] ?: @"Command";
    NSString *script = [c[@"script"] isKindOfClass:[NSString class]] ? c[@"script"] : @"";
    NSString *output = [c[@"output"] isKindOfClass:[NSString class]] ? c[@"output"] : @"hud";
    if ([type isEqualToString:@"flow"]) { [self runFlow:script name:name]; return; }
    if (![script stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
        showHUD([name stringByAppendingString:@" has no script yet — edit it in Settings › Commands"], @"exclamationmark.circle.fill"); return;
    }
    BOOL as = [type isEqualToString:@"applescript"];
    NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] ?: @"";
    // Shell: the values go in as variables, and the placeholders become quoted references to them. An expanded
    // variable is never parsed again as code, so text like $(…) in your clipboard can't run, whatever quotes surround it.
    NSString *code = [script stringByReplacingOccurrencesOfString:@"{query}" withString:as ? appleScriptQuote(arg) : @"\"${CENTRE_QUERY}\""];
    code = [code stringByReplacingOccurrencesOfString:@"{clipboard}" withString:as ? appleScriptQuote(clip) : @"\"${CENTRE_CLIP}\""];
    if (!as) code = [NSString stringWithFormat:@"CENTRE_QUERY=%@; CENTRE_CLIP=%@; %@", shellQuote(arg), shellQuote(clip), code];
    if (!as && [output isEqualToString:@"terminal"]) {
        osa([NSString stringWithFormat:@"tell application \"Terminal\"\nactivate\ndo script %@\nend tell", appleScriptQuote(code)]);
        return;
    }
    __weak CApp *ws = self;
    void (^done)(NSString *) = ^(NSString *o) { [ws handleOutput:o mode:output name:name]; };
    if (as) runOsa(code, done); else runUserShell(code, done);
}

- (void)handleOutput:(NSString *)o mode:(NSString *)mode name:(NSString *)name {
    NSString *t = [o ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([mode isEqualToString:@"silent"]) return;
    if ([mode isEqualToString:@"paste"]) { [self deliverText:t paste:YES]; return; }
    if ([mode isEqualToString:@"copy"]) {
        if (t.length) { copyText(t); showHUD([@"Copied · " stringByAppendingString:oneLine(t, 48)], @"doc.on.clipboard.fill"); }
        else showHUD([name stringByAppendingString:@" · no output to copy"], @"exclamationmark.circle.fill");
        return;
    }
    NSString *first = oneLine([t componentsSeparatedByString:@"\n"].firstObject ?: @"", 64);
    showHUDFor(first.length ? first : [name stringByAppendingString:@" · done"], @"checkmark.circle.fill", first.length > 32 ? 3.2 : 1.6);
}

#pragma mark Flows

// One step per line. Built-in or your own command names, plus: wait 2 · open Notes · quit Slack · paste text · url https://… · shell cmd
- (void)runFlow:(NSString *)script name:(NSString *)name {
    NSArray *steps = flowSteps(script);
    if (!steps.count) { showHUD([name stringByAppendingString:@" has no steps yet"], @"exclamationmark.circle.fill"); return; }
    showHUD([NSString stringWithFormat:@"%@ · %lu step%@", name, (unsigned long)steps.count, steps.count == 1 ? @"" : @"s"], @"arrow.triangle.branch");
    [self runFlowSteps:steps index:0];
}

- (void)runFlowSteps:(NSArray<NSString *> *)steps index:(NSUInteger)i {
    if (i >= steps.count) return;
    NSString *s = steps[i], *low = s.lowercaseString;
    NSString *(^rest)(NSUInteger) = ^NSString *(NSUInteger n) { return [[s substringFromIndex:n] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; };
    NSTimeInterval next = 0.4;
    if ([low hasPrefix:@"wait "]) next = MIN(MAX(rest(5).doubleValue, 0), 600);
    else if ([low hasPrefix:@"open "]) [self openTarget:rest(5)];
    else if ([low hasPrefix:@"quit "]) {
        NSString *n = rest(5).lowercaseString;
        for (NSRunningApplication *r in [NSWorkspace sharedWorkspace].runningApplications)
            if ([r.localizedName.lowercaseString isEqualToString:n]) [r terminate];
    }
    else if ([low hasPrefix:@"paste "] || [low hasPrefix:@"type "]) {
        [self deliverText:expandSnippet(rest([low hasPrefix:@"paste "] ? 6 : 5), [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString], [NSDate date]) paste:YES];
        next = 1.2;
    }
    else if ([low hasPrefix:@"url "]) openURLString(rest(4));
    else if ([low hasPrefix:@"shell "]) runUserShell(rest(6), nil);
    else {
        CItem *it = [self catalogItemNamed:s];
        if (it.action) it.action();
        else showHUD([@"Flow step not found: " stringByAppendingString:s], @"exclamationmark.triangle.fill");
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(next * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runFlowSteps:steps index:i + 1]; });
}

// "Safari", "~/Documents", "https://…": an app by name, a path, or a link.
- (void)openTarget:(NSString *)t {
    if ([t hasPrefix:@"http://"] || [t hasPrefix:@"https://"]) { openURLString(t); return; }
    if ([t hasPrefix:@"/"] || [t hasPrefix:@"~"]) { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:t.stringByExpandingTildeInPath]]; return; }
    NSString *low = t.lowercaseString; CItem *hit = nil;
    for (CItem *a in self.apps) if ([a.title.lowercaseString isEqualToString:low]) { hit = a; break; }
    if (!hit) for (CItem *a in self.apps) if ([a.title.lowercaseString hasPrefix:low]) { hit = a; break; }
    if ([hit.path hasPrefix:@"/"]) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:hit.path]];
    else if (hit.path) openURLString(hit.path);
    else runShell([NSString stringWithFormat:@"open -a %@", shellQuote(t)], nil);
}

// A flow step names a command the way you'd type it: its title, its pinned label, or your command's name.
// Flows can't call other flows, so a flow can never loop forever.
- (CItem *)catalogItemNamed:(NSString *)n {
    NSString *low = n.lowercaseString;
    for (CItem *c in [self systemCommands])
        if ([c.title.lowercaseString isEqualToString:low] || [[self shortLabel:c].lowercaseString isEqualToString:low]) return c;
    for (NSDictionary *c in [self customCommands])
        if (![c[@"type"] isEqual:@"flow"] && [[c[@"name"] lowercaseString] isEqualToString:low]) return [self customItem:c arg:@""];
    for (NSDictionary *sn in [self snippets])
        if ([[sn[@"name"] lowercaseString] isEqualToString:low] || [[sn[@"keyword"] lowercaseString] isEqualToString:low]) return [self snippetItem:sn];
    return nil;
}

#pragma mark Snippets

- (CItem *)snippetItem:(NSDictionary *)sn {
    NSString *name = [sn[@"name"] length] ? sn[@"name"] : sn[@"keyword"];
    NSString *kw = [sn[@"keyword"] isKindOfClass:[NSString class]] ? sn[@"keyword"] : @"";
    NSString *text = sn[@"text"];
    __weak CApp *ws = self;
    NSString *(^expanded)(void) = ^NSString *{ return expandSnippet(text, [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString], [NSDate date]); };
    CItem *i = mk(name, oneLine(text, 70), @"Snippet", @"text.quote", ^{ [ws deliverText:expanded() paste:YES]; });
    i.altAction = ^{ copyText(expanded()); showHUD(@"Snippet copied", @"doc.on.clipboard.fill"); };
    i.altHint = @"⌘↩ Copy";
    i.key = [@"snip:" stringByAppendingString:sn[@"id"]];
    i.detail = kw.length ? kw : nil;
    i.verb = @"Paste Snippet";
    return i;
}

- (NSArray<CItem *> *)snippetItems:(NSString *)q {
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *sn in [self snippets]) {
        CItem *i = [self snippetItem:sn];
        NSString *kw = [sn[@"keyword"] isKindOfClass:[NSString class]] ? sn[@"keyword"] : @"";
        double s = 0;
        if (q.length) {
            if (kw.length && [kw.lowercaseString isEqualToString:q.lowercaseString]) s = 1500;      // exact keyword: top of the list
            else s = MAX(fuzzyScore(q, i.title), kw.length ? fuzzyScore(q, kw) : -1);
            if (s < 0) continue;
        }
        i.score = s - 3 + [self usageBoost:i.key];
        [r addObject:i];
    }
    [r sortUsingComparator:^NSComparisonResult(CItem *a, CItem *b) { return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : [a.title compare:b.title]; }];
    return r;
}

#pragma mark Keys: one name for anything runnable

- (CItem *)itemForKey:(NSString *)key {
    if (!key.length) return nil;
    if ([key hasPrefix:@"cmd:"]) { for (CItem *c in [self systemCommands]) if ([c.key isEqualToString:key]) return c; return nil; }
    if ([key hasPrefix:@"custom:"]) {
        NSString *cid = [key substringFromIndex:7];
        for (NSDictionary *c in [self customCommands]) if ([c[@"id"] isEqualToString:cid]) return [self customItem:c arg:nil];
        return nil;
    }
    if ([key hasPrefix:@"snip:"]) {
        NSString *sid = [key substringFromIndex:5];
        for (NSDictionary *s in [self snippets]) if ([s[@"id"] isEqualToString:sid]) return [self snippetItem:s];
        return nil;
    }
    if ([key hasPrefix:@"tx:"]) return [transformNames() containsObject:[key substringFromIndex:3]] ? [self transformItem:[key substringFromIndex:3]] : nil;
    for (CItem *a in self.apps) if ([a.path isEqualToString:key]) return [self appItem:a score:0];
    if ([key hasPrefix:@"/"]) {
        BOOL dir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:key isDirectory:&dir]) return nil;
        BOOL folder = dir && ![[NSWorkspace sharedWorkspace] isFilePackageAtPath:key];
        if (!folder && [key.pathExtension isEqualToString:@"app"]) {
            CItem *a = [CItem new]; a.title = [[NSFileManager defaultManager] displayNameAtPath:key].stringByDeletingPathExtension; a.path = key; a.kind = @"Application";
            return [self appItem:a score:0];
        }
        CItem *f = [self fileItem:key folder:folder score:0];
        if ([key isEqualToString:NSHomeDirectory()]) f.title = @"Home";
        return f;
    }
    for (CItem *l in [self linkItemsFor:@""]) if ([l.key isEqualToString:key]) return l;
    return nil;
}

- (NSString *)pinKeyFor:(CItem *)i {
    if (!i || [i.kind isEqualToString:@"Open Window"] || [i.kind isEqualToString:@"Context"] || [i.kind isEqualToString:@"Process"]) return nil;
    if (i.key.length) return i.key;
    if (i.path.length) return i.path;
    return nil;
}

#pragma mark Pins

- (NSArray<NSString *> *)defaultPins {
    return @[@"cmd:Lock Screen", @"cmd:Sleep", @"cmd:Toggle Dark Mode", @"cmd:Generate Password", @"cmd:Show Desktop", @"cmd:Mute / Unmute"];
}
- (NSArray<NSString *> *)pinnedKeys {
    id p = self.config[@"pinned"];
    if (![p isKindOfClass:[NSArray class]]) return [self defaultPins];
    NSMutableArray *r = [NSMutableArray new];
    for (id k in p) if ([k isKindOfClass:[NSString class]] && ![r containsObject:k]) [r addObject:k];
    return r;
}
- (NSString *)shortLabel:(CItem *)i {
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"Lock Screen": @"Lock", @"Toggle Dark Mode": @"Dark Mode", @"Generate Password": @"Password", @"Show Desktop": @"Desktop",
                 @"Mute / Unmute": @"Mute", @"Toggle Hidden Files": @"Hidden Files", @"Play / Pause": @"Play/Pause",
                 @"Skip to Next Track": @"Next Track", @"Back to Previous Track": @"Previous", @"Start Screen Saver": @"Screen Saver",
                 @"Eject All Disks": @"Eject", @"Clear Clipboard": @"Clear Clipboard", @"Centre: Toggle Start at Login": @"Login Item" };
    });
    NSString *t = i.title ?: @"";
    if (map[t]) return map[t];
    for (NSString *pre in @[@"Window: ", @"Centre: "]) if ([t hasPrefix:pre]) return [t substringFromIndex:pre.length];
    return t;
}
- (NSArray<CItem *> *)pinnedItems {
    NSMutableArray *r = [NSMutableArray new];
    for (NSString *k in [self pinnedKeys]) {
        CItem *i = [self itemForKey:k]; if (!i) continue;          // a deleted command or app simply drops out
        i.title = [self shortLabel:i];
        if (!i.key) i.key = k;
        [r addObject:i];
    }
    return r;
}
- (BOOL)isPinned:(CItem *)i { NSString *k = [self pinKeyFor:i]; return k && [[self pinnedKeys] containsObject:k]; }

- (void)setPinnedKeys:(NSArray<NSString *> *)keys {
    NSMutableDictionary *c = [self mutableConfig];
    c[@"pinned"] = keys ?: @[];
    [self writeConfig:c];
}

// ⇧⌘P in the panel. Feedback stays inside the panel: home redraws its pins, a result row says what happened.
- (void)togglePinSelected {
    if (self.selected < 0 || self.selected >= (NSInteger)self.items.count) return;
    CItem *i = self.items[self.selected];
    NSString *k = [self pinKeyFor:i];
    if (!k) { NSBeep(); return; }
    NSMutableArray *p = [[self pinnedKeys] mutableCopy];
    BOOL was = [p containsObject:k];
    if (was) [p removeObject:k]; else [p addObject:k];
    [self setPinnedKeys:p];
    if (self.gridMode) {
        NSInteger keep = self.selected;
        [self refresh];
        [self homeSelect:MIN(keep, (NSInteger)self.items.count - 1)];
    } else {
        i.subtitle = was ? @"Unpinned from Home" : @"Pinned to Home · ⇧⌘P again to unpin";
        [self.table reloadData]; [self layoutForRows:self.items.count];
    }
}

#pragma mark Per-command hotkeys

- (void)unregisterCommandHotKeys {
    for (NSValue *v in self.cmdHotKeyRefs) UnregisterEventHotKey((EventHotKeyRef)v.pointerValue);
    [self.cmdHotKeyRefs removeAllObjects]; [self.cmdHotKeyKeys removeAllObjects];
}
- (void)registerCommandHotKeys {
    if (!self.cmdHotKeyRefs) self.cmdHotKeyRefs = [NSMutableArray new];
    if (!self.cmdHotKeyKeys) self.cmdHotKeyKeys = [NSMutableArray new];
    [self unregisterCommandHotKeys];
    self.hotKeyFailures = [NSMutableSet new];
    NSDictionary *hk = [self.config[@"hotkeys"] isKindOfClass:[NSDictionary class]] ? self.config[@"hotkeys"] : @{};
    for (NSString *key in [hk.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *spec = hk[key]; UInt32 k = 0, m = 0;
        if (![spec isKindOfClass:[NSString class]] || !parseHotkey(spec, &k, &m)) continue;
        EventHotKeyID hid; hid.signature = 'CNTR'; hid.id = 100 + (UInt32)self.cmdHotKeyKeys.count;
        EventHotKeyRef ref = NULL;
        if (RegisterEventHotKey(k, m, hid, GetApplicationEventTarget(), 0, &ref) == noErr && ref) {
            [self.cmdHotKeyRefs addObject:[NSValue valueWithPointer:ref]]; [self.cmdHotKeyKeys addObject:key];
        } else [self.hotKeyFailures addObject:key];
    }
}

- (void)runHotKeyCommand:(NSUInteger)idx {
    if (idx >= self.cmdHotKeyKeys.count) return;
    NSString *key = self.cmdHotKeyKeys[idx];
    [self loadConfig];
    if (self.panel.visible) [self hide];
    self.previousApp = [NSWorkspace sharedWorkspace].frontmostApplication;    // window commands act on the app you're in
    CItem *i = [self itemForKey:key];
    if (!i.action) { showHUD(@"That shortcut's command no longer exists — remove it in Settings › Shortcuts", @"exclamationmark.triangle.fill"); return; }
    if (i.confirm.length && !([self.hotKeyArmedKey isEqualToString:key] && [self.hotKeyArmedAt timeIntervalSinceNow] > -3)) {
        self.hotKeyArmedKey = key; self.hotKeyArmedAt = [NSDate date];
        showHUDFor([i.confirm stringByReplacingOccurrencesOfString:@"↩" withString:@"the shortcut"], @"exclamationmark.circle.fill", 3);
        return;
    }
    self.hotKeyArmedKey = nil;
    if (![key hasPrefix:@"/"]) [self recordUse:key];            // apps and folders record their own use when they open
    i.action();
}

#pragma mark Catalog (Settings menus)

// @[@[group title, @[@[item title, key], …]], …] for the "Add…" menus in Settings.
- (NSArray *)catalogGroups {
    NSMutableArray *groups = [NSMutableArray new];
    NSMutableArray *cmds = [NSMutableArray new];
    for (CItem *c in [self systemCommands]) [cmds addObject:@[c.title, c.key]];
    [groups addObject:@[@"Commands", cmds]];
    NSMutableArray *mine = [NSMutableArray new];
    for (NSDictionary *c in [self customCommands]) [mine addObject:@[c[@"name"], [@"custom:" stringByAppendingString:c[@"id"]]]];
    if (mine.count) [groups addObject:@[@"Your Commands", mine]];
    NSMutableArray *snips = [NSMutableArray new];
    for (NSDictionary *s in [self snippets]) [snips addObject:@[[s[@"name"] length] ? s[@"name"] : s[@"keyword"], [@"snip:" stringByAppendingString:s[@"id"]]]];
    if (snips.count) [groups addObject:@[@"Snippets", snips]];
    NSMutableArray *tx = [NSMutableArray new];
    for (NSString *n in transformNames()) [tx addObject:@[[@"Transform: " stringByAppendingString:n], [@"tx:" stringByAppendingString:n]]];
    [groups addObject:@[@"Text Transforms", tx]];
    NSMutableArray *apps = [NSMutableArray new];
    for (CItem *a in [self.apps sortedArrayUsingComparator:^NSComparisonResult(CItem *x, CItem *y) { return [x.title localizedCaseInsensitiveCompare:y.title]; }])
        if (a.path.length) [apps addObject:@[a.title, a.path]];
    [groups addObject:@[@"Apps", apps]];
    NSMutableArray *folders = [NSMutableArray new];
    for (CItem *f in [self folderItemsFor:@""]) [folders addObject:@[f.title, f.path]];
    [groups addObject:@[@"Folders", folders]];
    NSMutableArray *links = [NSMutableArray new];
    for (CItem *l in [self linkItemsFor:@""]) if (l.key) [links addObject:@[l.title, l.key]];
    if (links.count) [groups addObject:@[@"Quick Links", links]];
    return groups;
}

- (NSString *)titleForKey:(NSString *)key {
    CItem *i = [self itemForKey:key];
    if (i) return i.title;
    return [key hasPrefix:@"/"] ? [key.lastPathComponent stringByAppendingString:@" (missing)"] : [key stringByAppendingString:@" (missing)"];
}

@end
