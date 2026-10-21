// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Built-in tools: dictionary look-up, timers, volume and Keep Awake.
#import "App.h"

// Turns a macOS dictionary entry into a part of speech and its senses, without pronunciation, usage notes,
// examples or the ORIGIN / DERIVATIVES sections — the full text is one ⌘↩ away.
static NSDictionary *parseDefinition(NSString *def) {
    NSString *body = def;
    NSArray *bars = [def componentsSeparatedByString:@"|"];
    if (bars.count >= 3) body = [[bars subarrayWithRange:NSMakeRange(2, bars.count - 2)] componentsJoinedByString:@"|"];
    for (NSString *cut in @[@" ORIGIN", @" DERIVATIVES", @" PHRASES", @" PHRASAL VERBS", @" USAGE"]) {
        NSRange r = [body rangeOfString:cut]; if (r.location != NSNotFound) body = [body substringToIndex:r.location];
    }
    body = [[NSRegularExpression regularExpressionWithPattern:@"\\s*\\[[^\\]]*\\]" options:0 error:nil] stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0, body.length) withTemplate:@""];
    body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *pos = @"";
    NSSet *kinds = [NSSet setWithArray:@[@"noun", @"verb", @"adjective", @"adverb", @"pronoun", @"preposition", @"conjunction",
                                         @"exclamation", @"interjection", @"abbreviation", @"prefix", @"suffix", @"determiner"]];
    NSString *first = [body componentsSeparatedByString:@" "].firstObject.lowercaseString;
    if ([kinds containsObject:first]) { pos = first; body = [[body substringFromIndex:first.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?:^|\\s)(\\d{1,2})\\s(?=\\S)" options:0 error:nil];
    NSArray *marks = [re matchesInString:body options:0 range:NSMakeRange(0, body.length)];
    NSMutableArray *senses = [NSMutableArray new];
    void (^add)(NSString *) = ^(NSString *x) {
        NSRange colon = [x rangeOfString:@": "];                       // drop the example sentence
        if (colon.location != NSNotFound && colon.location > 12) x = [x substringToIndex:colon.location];
        x = [x stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .;:"]];
        if (x.length) [senses addObject:x];
    };
    if (marks.count < 2) add(body);
    else for (NSUInteger i = 0; i < marks.count; i++) {
        NSUInteger start = NSMaxRange([marks[i] range]), end = i + 1 < marks.count ? [marks[i + 1] range].location : body.length;
        add([body substringWithRange:NSMakeRange(start, end - start)]);
    }
    return @{@"pos": pos, @"senses": senses};
}

// Greedy word wrap measured in the row's own font, so a long sense reads as a short paragraph across rows
// instead of one truncated line.
static NSArray<NSString *> *wrapLines(NSString *s, CGFloat maxWidth) {
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightRegular]};
    NSMutableArray *lines = [NSMutableArray new]; NSMutableString *cur = [NSMutableString new];
    for (NSString *w in [s componentsSeparatedByString:@" "]) {
        if (!w.length) continue;
        NSString *next = cur.length ? [NSString stringWithFormat:@"%@ %@", cur, w] : w;
        if (cur.length && [next sizeWithAttributes:a].width > maxWidth) { [lines addObject:[cur copy]]; [cur setString:w]; }
        else [cur setString:next];
    }
    if (cur.length) [lines addObject:cur];
    return lines;
}

@implementation CApp (Tools)

#pragma mark Dictionary (define <word>)

- (NSArray<CItem *> *)defineItems:(NSString *)word {
    NSString *w = [word stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!w.length) return @[mk(@"Type a word to look up", @"Uses the dictionaries built into macOS — works offline", @"Dictionary", @"character.book.closed", nil)];
    NSString *def = (__bridge_transfer NSString *)DCSCopyTextDefinition(NULL, (__bridge CFStringRef)w, CFRangeMake(0, (CFIndex)w.length));
    NSString *url = [@"dict://" stringByAppendingString:urlEncode(w)];
    if (!def.length) {
        CItem *none = mk([NSString stringWithFormat:@"No definition for “%@”", w], @"Check the spelling, or search the Dictionary app", @"Dictionary", @"character.book.closed", ^{ openURLString(url); });
        none.verb = @"Open in Dictionary";
        return @[none];
    }
    NSDictionary *parsed = parseDefinition(def);
    NSArray *senses = parsed[@"senses"];
    CAction open = ^{ openURLString(url); };
    CAction copyAll = ^{ copyText(def); showHUD(@"Definition copied", @"doc.on.doc.fill"); };
    NSMutableArray *rows = [NSMutableArray new];
    CItem *head = mk(w, [parsed[@"pos"] length] ? parsed[@"pos"] : nil, @"Dictionary", @"character.book.closed.fill", open);
    [rows addObject:head];
    static NSImage *blank; if (!blank) blank = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    for (NSUInteger i = 0; i < senses.count && rows.count < kMaxRows; i++) {
        NSString *text = senses.count > 1 ? [NSString stringWithFormat:@"%lu.  %@", (unsigned long)i + 1, senses[i]] : senses[i];
        NSArray *lines = wrapLines(text, 440);
        for (NSUInteger k = 0; k < lines.count && rows.count < kMaxRows; k++) {
            CItem *ln = mk(lines[k], nil, @"Dictionary", nil, open);
            ln.icon = blank;                                      // text lines sit under the headword without their own icon
            [rows addObject:ln];
        }
    }
    for (CItem *it in rows) { it.verb = @"Open in Dictionary"; it.altAction = copyAll; it.altHint = @"⌘↩ Copy definition"; it.detail = it == head ? nil : @""; }
    return rows;
}

#pragma mark Timers (timer 10m tea)

- (NSArray<CItem *> *)activeTimerItems {
    NSMutableArray *r = [NSMutableArray new];
    __weak CApp *ws = self;
    for (NSMutableDictionary *t in [self.timers copy]) {
        NSTimeInterval left = MAX(0, [t[@"end"] timeIntervalSinceNow]);
        NSString *label = [t[@"label"] length] ? t[@"label"] : @"Timer";
        NSDateFormatter *df = [NSDateFormatter new]; df.timeStyle = NSDateFormatterShortStyle; df.dateStyle = NSDateFormatterNoStyle;
        CItem *it = mk([NSString stringWithFormat:@"%@ — %@ left", label, fmtTime(left)], [@"Ends at " stringByAppendingString:[df stringFromDate:t[@"end"]]],
                       @"Timer", @"timer", ^{ [ws cancelTimer:t]; });
        it.detail = fmtTime([t[@"total"] doubleValue]);
        it.verb = @"Cancel Timer";
        [r addObject:it];
    }
    return r;
}

- (NSArray<CItem *> *)timerItems:(NSString *)rest {
    NSMutableArray *r = [NSMutableArray new];
    NSArray *parts = [rest componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSTimeInterval secs = rest.length ? parseDuration(parts.firstObject) : 0;
    NSString *label = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "] : @"";
    __weak CApp *ws = self;
    if (secs > 0) {
        NSString *title = [NSString stringWithFormat:@"Start a %@ timer%@", fmtTime(secs), label.length ? [@" — " stringByAppendingString:label] : @""];
        CItem *start = mk(title, @"Chimes and shows a banner when it's done", @"Timer", @"timer", ^{ [ws startTimer:secs label:label]; });
        start.verb = @"Start Timer";
        [r addObject:start];
    } else if (rest.length) {
        [r addObject:mk(@"Type a duration first", @"10m · 1h30m · 90s · 25 (minutes) — then an optional label", @"Timer", @"timer", nil)];
    }
    [r addObjectsFromArray:[self activeTimerItems]];
    if (!r.count) [r addObject:mk(@"Type a duration, like timer 10m tea", @"Timers keep running while Centre is closed", @"Timer", @"timer", nil)];
    return r;
}

- (void)startTimer:(NSTimeInterval)secs label:(NSString *)label {
    if (!self.timers) self.timers = [NSMutableArray new];
    NSMutableDictionary *t = [@{@"end": [NSDate dateWithTimeIntervalSinceNow:secs], @"label": label ?: @"", @"total": @(secs)} mutableCopy];
    __weak CApp *ws = self;
    NSTimer *nt = [NSTimer timerWithTimeInterval:secs repeats:NO block:^(NSTimer *x) { [ws timerFired:t]; }];
    [[NSRunLoop mainRunLoop] addTimer:nt forMode:NSRunLoopCommonModes];   // fires even while a menu is open
    t[@"timer"] = nt;
    [self.timers addObject:t];
    showHUD([NSString stringWithFormat:@"Timer set · %@%@", fmtTime(secs), label.length ? [@" · " stringByAppendingString:label] : @""], @"timer");
}

- (void)timerFired:(NSMutableDictionary *)t {
    [self.timers removeObject:t];
    NSString *label = [t[@"label"] length] ? t[@"label"] : @"Timer";
    showHUDFor([NSString stringWithFormat:@"%@ — time's up", label], @"alarm.fill", 8);
    for (int i = 0; i < 3; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[[NSSound soundNamed:@"Glass"] copy] play]; });
}

- (void)cancelTimer:(NSMutableDictionary *)t {
    [t[@"timer"] invalidate];
    [self.timers removeObject:t];
    showHUD(@"Timer cancelled", @"timer");
}

#pragma mark Volume (vol 40)

- (NSArray<CItem *> *)volumeItems:(NSString *)rest {
    NSString *digits = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" %"]];
    BOOL ok = digits.length && [digits rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound;
    if (!ok) return @[mk(@"Type a level from 0 to 100", @"vol 40 sets the volume to 40%", @"Media", @"speaker.wave.2", nil)];
    NSInteger v = MIN(MAX(digits.integerValue, 0), 100);
    CItem *it = mk([NSString stringWithFormat:@"Set volume to %ld%%", (long)v], nil, @"Media", v == 0 ? @"speaker.slash.fill" : @"speaker.wave.2.fill", ^{
        osa(v == 0 ? @"set volume output volume 0" : [NSString stringWithFormat:@"set volume output volume %ld without output muted", (long)v]);
        showHUD([NSString stringWithFormat:@"Volume %ld%%", (long)v], v == 0 ? @"speaker.slash.fill" : @"speaker.wave.2.fill");
    });
    it.verb = @"Set Volume";
    return @[it];
}

#pragma mark Keep Awake

- (void)toggleKeepAwake {
    if (self.awakeAssertion) {
        IOPMAssertionRelease(self.awakeAssertion); self.awakeAssertion = 0;
        showHUD(@"Keep Awake off", @"moon.zzz.fill");
        return;
    }
    IOPMAssertionID aid = 0;
    if (IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn, CFSTR("Centre: Keep Awake"), &aid) == kIOReturnSuccess) {
        self.awakeAssertion = aid;
        showHUD(@"Keep Awake on · your Mac won't sleep", @"sun.max.fill");
    } else showHUD(@"macOS refused to keep the Mac awake", @"exclamationmark.triangle.fill");
}

@end
