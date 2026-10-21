// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Pure text and time logic behind transforms, snippets, time zones, flows and hotkeys. No UI; self-tested.
#import "Centre.h"

#pragma mark Text transforms

NSArray<NSString *> *transformNames(void) {
    return @[@"UPPERCASE", @"lowercase", @"Title Case", @"Sentence case", @"camelCase", @"snake_case", @"kebab-case",
             @"Trim Whitespace", @"Join Lines", @"Sort Lines", @"Unique Lines", @"Reverse Lines",
             @"JSON Pretty", @"JSON Minify", @"URL Encode", @"URL Decode", @"Base64 Encode", @"Base64 Decode",
             @"Straight Quotes", @"Clean URL"];
}

static NSArray<NSString *> *wordsOf(NSString *s) {
    // "helloWorld foo-bar_baz" → hello, World, foo, bar, baz (splits camel humps too)
    NSString *spaced = [[NSRegularExpression regularExpressionWithPattern:@"([a-z0-9])([A-Z])" options:0 error:nil]
                        stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"$1 $2"];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *w in [spaced componentsSeparatedByCharactersInSet:[NSCharacterSet alphanumericCharacterSet].invertedSet])
        if (w.length) [out addObject:w];
    return out;
}

static NSString *capFirst(NSString *w) {
    if (!w.length) return w;
    return [[[w substringToIndex:1] uppercaseString] stringByAppendingString:[[w substringFromIndex:1] lowercaseString]];
}

static NSArray<NSString *> *linesOf(NSString *s) {
    NSString *t = [s hasSuffix:@"\n"] ? [s substringToIndex:s.length - 1] : s;
    return [t componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

// Removes tracking parameters (utm_*, fbclid, gclid, si…) and keeps everything else as it was.
NSString *cleanURL(NSString *s) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!c.scheme.length || !c.host.length) return nil;
    NSSet *junk = [NSSet setWithArray:@[@"fbclid", @"gclid", @"dclid", @"msclkid", @"mc_cid", @"mc_eid", @"igshid", @"si", @"ref_src", @"ref_url", @"_hsenc", @"_hsmi", @"yclid", @"twclid"]];
    NSMutableArray *keep = [NSMutableArray new];
    for (NSURLQueryItem *q in c.queryItems) if (![q.name.lowercaseString hasPrefix:@"utm_"] && ![junk containsObject:q.name.lowercaseString]) [keep addObject:q];
    c.queryItems = keep.count ? keep : nil;
    return c.string;
}

// nil when the transform doesn't apply (invalid JSON, not Base64…), so the UI can say so instead of pasting garbage.
NSString *transformText(NSString *name, NSString *s) {
    if (!s) return nil;
    if ([name isEqualToString:@"UPPERCASE"]) return s.uppercaseString;
    if ([name isEqualToString:@"lowercase"]) return s.lowercaseString;
    if ([name isEqualToString:@"Title Case"]) {
        NSMutableString *o = [NSMutableString new]; BOOL start = YES;
        for (NSUInteger i = 0; i < s.length; i++) {
            NSString *ch = [s substringWithRange:NSMakeRange(i, 1)];
            BOOL space = [ch rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound;
            [o appendString:space ? ch : (start ? ch.uppercaseString : ch.lowercaseString)];
            start = space;
        }
        return o;
    }
    if ([name isEqualToString:@"Sentence case"]) {
        NSMutableString *o = [NSMutableString new]; BOOL start = YES;
        NSString *low = s.lowercaseString;
        for (NSUInteger i = 0; i < low.length; i++) {
            NSString *ch = [low substringWithRange:NSMakeRange(i, 1)];
            BOOL letter = [ch rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
            if (start && letter) { [o appendString:ch.uppercaseString]; start = NO; }
            else { [o appendString:ch]; if ([@".!?\n" containsString:ch]) start = YES; }
        }
        return o;
    }
    if ([name isEqualToString:@"camelCase"]) {
        NSArray *w = wordsOf(s); if (!w.count) return nil;
        NSMutableString *o = [[w[0] lowercaseString] mutableCopy];
        for (NSUInteger i = 1; i < w.count; i++) [o appendString:capFirst(w[i])];
        return o;
    }
    if ([name isEqualToString:@"snake_case"] || [name isEqualToString:@"kebab-case"]) {
        NSArray *w = wordsOf(s); if (!w.count) return nil;
        NSMutableArray *low = [NSMutableArray new]; for (NSString *x in w) [low addObject:x.lowercaseString];
        return [low componentsJoinedByString:[name hasPrefix:@"snake"] ? @"_" : @"-"];
    }
    if ([name isEqualToString:@"Trim Whitespace"]) {
        NSMutableArray *o = [NSMutableArray new];
        NSRegularExpression *multi = [NSRegularExpression regularExpressionWithPattern:@"[ \\t]{2,}" options:0 error:nil];
        for (NSString *l in linesOf(s)) {
            NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            [o addObject:[multi stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "]];
        }
        return [[o componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([name isEqualToString:@"Join Lines"]) {
        NSMutableArray *o = [NSMutableArray new];
        for (NSString *l in linesOf(s)) { NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; if (t.length) [o addObject:t]; }
        return [o componentsJoinedByString:@" "];
    }
    if ([name isEqualToString:@"Sort Lines"]) return [[linesOf(s) sortedArrayUsingSelector:@selector(localizedStandardCompare:)] componentsJoinedByString:@"\n"];
    if ([name isEqualToString:@"Unique Lines"]) return [[NSOrderedSet orderedSetWithArray:linesOf(s)].array componentsJoinedByString:@"\n"];
    if ([name isEqualToString:@"Reverse Lines"]) return [[linesOf(s) reverseObjectEnumerator].allObjects componentsJoinedByString:@"\n"];
    if ([name isEqualToString:@"JSON Pretty"] || [name isEqualToString:@"JSON Minify"]) {
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil] : nil;
        if (!o) return nil;
        NSJSONWritingOptions opt = NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes;
        if ([name isEqualToString:@"JSON Pretty"]) opt |= NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys;
        NSData *out = [NSJSONSerialization dataWithJSONObject:o options:opt error:nil];
        return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : nil;
    }
    if ([name isEqualToString:@"URL Encode"]) return urlEncode(s);
    if ([name isEqualToString:@"URL Decode"]) return [[s stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
    if ([name isEqualToString:@"Base64 Encode"]) return [[s dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    if ([name isEqualToString:@"Base64 Decode"]) {
        NSString *t = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
        while (t.length % 4) t = [t stringByAppendingString:@"="];
        NSData *d = [[NSData alloc] initWithBase64EncodedString:t options:0];
        return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    }
    if ([name isEqualToString:@"Straight Quotes"]) {
        NSMutableString *o = [s mutableCopy];
        for (NSArray *p in @[@[@"“", @"\""], @[@"”", @"\""], @[@"„", @"\""], @[@"‘", @"'"], @[@"’", @"'"], @[@"‚", @"'"]])
            [o replaceOccurrencesOfString:p[0] withString:p[1] options:0 range:NSMakeRange(0, o.length)];
        return o;
    }
    if ([name isEqualToString:@"Clean URL"]) return cleanURL(s);
    return nil;
}

// "12 words · 64 characters · 2 lines"
NSString *textStats(NSString *s) {
    __block NSUInteger words = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                       usingBlock:^(NSString *w, NSRange r, NSRange er, BOOL *stop) { words++; }];
    NSUInteger lines = s.length ? linesOf(s).count : 0;
    return [NSString stringWithFormat:@"%lu word%@ · %lu character%@ · %lu line%@", (unsigned long)words, words == 1 ? @"" : @"s",
            (unsigned long)s.length, s.length == 1 ? @"" : @"s", (unsigned long)lines, lines == 1 ? @"" : @"s"];
}

#pragma mark Snippets, flows, quoting

// {date} {iso} {time} {datetime} {weekday} {clipboard} {uuid}
NSString *expandSnippet(NSString *text, NSString *clipboard, NSDate *now) {
    if (!text) return @"";
    NSDateFormatter *(^fmt)(NSString *) = ^NSDateFormatter *(NSString *f) {
        NSDateFormatter *d = [NSDateFormatter new]; d.locale = [NSLocale localeWithLocaleIdentifier:@"en_AU"]; d.dateFormat = f; return d; };
    NSMutableString *o = [text mutableCopy];
    NSDictionary *map = @{ @"{date}": [fmt(@"d MMMM yyyy") stringFromDate:now], @"{iso}": [fmt(@"yyyy-MM-dd") stringFromDate:now],
                           @"{time}": [[fmt(@"h:mm a") stringFromDate:now] lowercaseString],
                           @"{datetime}": [NSString stringWithFormat:@"%@ %@", [fmt(@"d MMM yyyy") stringFromDate:now], [[fmt(@"h:mm a") stringFromDate:now] lowercaseString]],
                           @"{weekday}": [fmt(@"EEEE") stringFromDate:now], @"{uuid}": [NSUUID UUID].UUIDString.lowercaseString };
    for (NSString *k in map) [o replaceOccurrencesOfString:k withString:map[k] options:NSCaseInsensitiveSearch range:NSMakeRange(0, o.length)];
    // Last, so a clipboard that happens to contain "{date}" is pasted as written
    [o replaceOccurrencesOfString:@"{clipboard}" withString:clipboard ?: @"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, o.length)];
    return o;
}

// One step per line; blank lines and # comments are skipped.
NSArray<NSString *> *flowSteps(NSString *script) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *l in [script ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length && ![t hasPrefix:@"#"]) [out addObject:t];
    }
    return out;
}

NSString *shellQuote(NSString *s) { return [NSString stringWithFormat:@"'%@'", [s ?: @"" stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }
NSString *appleScriptQuote(NSString *s) {
    NSString *t = [[s ?: @"" stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", t];
}

#pragma mark Hotkeys

// "ctrl+alt+l" → kVK_ANSI_L with controlKey|optionKey. NO when there's no key or no modifier.
BOOL parseHotkey(NSString *spec, UInt32 *keyOut, UInt32 *modsOut) {
    UInt32 mods = 0; NSNumber *key = nil;
    NSDictionary *keys = hotkeyKeyMap();
    for (NSString *part in [spec.lowercaseString componentsSeparatedByString:@"+"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t isEqualToString:@"cmd"] || [t isEqualToString:@"command"]) mods |= cmdKey;
        else if ([t isEqualToString:@"alt"] || [t isEqualToString:@"option"] || [t isEqualToString:@"opt"]) mods |= optionKey;
        else if ([t isEqualToString:@"ctrl"] || [t isEqualToString:@"control"]) mods |= controlKey;
        else if ([t isEqualToString:@"shift"]) mods |= shiftKey;
        else if (keys[t]) key = keys[t];
    }
    if (!key || !mods) return NO;
    if (keyOut) *keyOut = key.unsignedIntValue;
    if (modsOut) *modsOut = mods;
    return YES;
}

#pragma mark Time zones

// "tokyo", "new york", "nyc", "pst", "riyadh" → a time zone. nil when the word isn't a place.
NSTimeZone *zoneForPlace(NSString *place) {
    NSString *p = [[place stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    if (p.length < 2) return nil;
    static NSDictionary *alias; static dispatch_once_t once;
    dispatch_once(&once, ^{
        alias = @{ @"nyc": @"America/New_York", @"ny": @"America/New_York", @"new york": @"America/New_York", @"sf": @"America/Los_Angeles",
                   @"san francisco": @"America/Los_Angeles", @"la": @"America/Los_Angeles", @"seattle": @"America/Los_Angeles",
                   @"boston": @"America/New_York", @"washington": @"America/New_York", @"miami": @"America/New_York", @"texas": @"America/Chicago",
                   @"austin": @"America/Chicago", @"london": @"Europe/London", @"uk": @"Europe/London", @"england": @"Europe/London",
                   @"paris": @"Europe/Paris", @"france": @"Europe/Paris", @"berlin": @"Europe/Berlin", @"germany": @"Europe/Berlin",
                   @"oslo": @"Europe/Oslo", @"norway": @"Europe/Oslo", @"riyadh": @"Asia/Riyadh", @"saudi": @"Asia/Riyadh", @"saudi arabia": @"Asia/Riyadh",
                   @"jeddah": @"Asia/Riyadh", @"mecca": @"Asia/Riyadh", @"makkah": @"Asia/Riyadh", @"dubai": @"Asia/Dubai", @"uae": @"Asia/Dubai",
                   @"india": @"Asia/Kolkata", @"delhi": @"Asia/Kolkata", @"mumbai": @"Asia/Kolkata", @"bangalore": @"Asia/Kolkata",
                   @"beijing": @"Asia/Shanghai", @"china": @"Asia/Shanghai", @"japan": @"Asia/Tokyo", @"korea": @"Asia/Seoul",
                   @"melbourne": @"Australia/Melbourne", @"sydney": @"Australia/Sydney", @"brisbane": @"Australia/Brisbane",
                   @"perth": @"Australia/Perth", @"adelaide": @"Australia/Adelaide", @"canberra": @"Australia/Sydney", @"hobart": @"Australia/Hobart",
                   @"nz": @"Pacific/Auckland", @"auckland": @"Pacific/Auckland", @"utc": @"UTC", @"gmt": @"GMT", @"cairo": @"Africa/Cairo", @"egypt": @"Africa/Cairo" };
    });
    if (alias[p]) return [NSTimeZone timeZoneWithName:alias[p]];
    NSString *u = [p stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    for (NSString *n in [NSTimeZone knownTimeZoneNames])
        if ([[n.lastPathComponent lowercaseString] isEqualToString:u]) return [NSTimeZone timeZoneWithName:n];
    if (p.length >= 3 && p.length <= 5 && [p rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet].invertedSet].location == NSNotFound) {
        NSString *abbr = [NSTimeZone abbreviationDictionary][p.uppercaseString];
        if (abbr) return [NSTimeZone timeZoneWithName:abbr];
    }
    return nil;
}

static NSString *placeName(NSString *typed) {
    NSString *t = [typed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length <= 3) return t.uppercaseString;
    return [transformText(@"Title Case", t) stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

static NSString *clockText(NSDate *d, NSTimeZone *tz, BOOL day) {
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.timeZone = tz;
    f.dateFormat = day ? @"h:mm a, EEE" : @"h:mm a";
    NSString *s = [f stringFromDate:d];
    return [[s stringByReplacingOccurrencesOfString:@"AM" withString:@"am"] stringByReplacingOccurrencesOfString:@"PM" withString:@"pm"];
}

static NSString *dayKey(NSDate *d, NSTimeZone *tz) {
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.timeZone = tz; f.dateFormat = @"yyyyMMdd";
    return [f stringFromDate:d];
}

static NSString *offsetPhrase(NSTimeZone *a, NSTimeZone *b, NSDate *at) {   // b relative to a
    double h = ([b secondsFromGMTForDate:at] - [a secondsFromGMTForDate:at]) / 3600.0;
    if (fabs(h) < 0.01) return @"same time as you";
    NSString *n = fmod(fabs(h), 1) == 0 ? [NSString stringWithFormat:@"%.0f", fabs(h)] : [NSString stringWithFormat:@"%.1f", fabs(h)];
    return [NSString stringWithFormat:@"%@ hour%@ %@ you", n, fabs(h) == 1 ? @"" : @"s", h > 0 ? @"ahead of" : @"behind"];
}

// "time in tokyo" · "tokyo time" · "3pm melbourne in london" · "9:30 am to new york" (from your zone).
// Returns @{title, subtitle, value} or nil.
NSDictionary *timeQuery(NSString *q, NSDate *now, NSTimeZone *local) {
    NSString *s = [[q lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    s = [s stringByReplacingOccurrencesOfString:@"what time is it in " withString:@"time in "];
    s = [s stringByReplacingOccurrencesOfString:@"?" withString:@""];
    NSRegularExpression *re1 = [NSRegularExpression regularExpressionWithPattern:@"^(?:time|now|clock)\\s+(?:in\\s+)?(.+)$" options:0 error:nil];
    NSRegularExpression *re2 = [NSRegularExpression regularExpressionWithPattern:@"^(.+?)\\s+time$" options:0 error:nil];
    NSRegularExpression *re3 = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\s+(?:(.+?)\\s+)?(?:in|to)\\s+(.+)$" options:0 error:nil];
    NSTextCheckingResult *m;
    NSString *(^grp)(NSTextCheckingResult *, NSUInteger) = ^NSString *(NSTextCheckingResult *r, NSUInteger i) {
        return [r rangeAtIndex:i].location == NSNotFound ? nil : [s substringWithRange:[r rangeAtIndex:i]]; };
    if ((m = [re3 firstMatchInString:s options:0 range:NSMakeRange(0, s.length)])) {
        NSString *hh = grp(m, 1), *mm = grp(m, 2), *ap = grp(m, 3), *from = grp(m, 4), *to = grp(m, 5);
        if (!mm && !ap) return nil;                                   // "5 km in mi" is a conversion, not a time
        NSInteger h = hh.integerValue, mi = mm.integerValue;
        if (ap) { if (h < 1 || h > 12) return nil; h = h % 12 + ([ap isEqualToString:@"pm"] ? 12 : 0); }
        if (h > 23 || mi > 59) return nil;
        NSTimeZone *fz = from ? zoneForPlace(from) : local, *tz = zoneForPlace(to);
        if (!fz || !tz) return nil;
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]; cal.timeZone = fz;
        NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
        c.hour = h; c.minute = mi;
        NSDate *at = [cal dateFromComponents:c];
        BOOL dayDiffers = ![dayKey(at, fz) isEqualToString:dayKey(at, tz)];
        NSString *value = clockText(at, tz, NO);
        return @{@"title": [NSString stringWithFormat:@"%@ %@ = %@ %@", clockText(at, fz, NO), from ? placeName(from) : @"here", clockText(at, tz, dayDiffers), placeName(to)],
                 @"subtitle": [NSString stringWithFormat:@"%@ is %@", placeName(to), offsetPhrase(local, tz, at)],
                 @"value": value};
    }
    NSString *place = nil;
    if ((m = [re1 firstMatchInString:s options:0 range:NSMakeRange(0, s.length)])) place = grp(m, 1);
    else if ((m = [re2 firstMatchInString:s options:0 range:NSMakeRange(0, s.length)])) place = grp(m, 1);
    NSTimeZone *tz = place ? zoneForPlace(place) : nil;
    if (!tz) return nil;
    BOOL otherDay = ![dayKey(now, tz) isEqualToString:dayKey(now, local)];
    return @{@"title": [NSString stringWithFormat:@"%@ in %@", clockText(now, tz, otherDay), placeName(place)],
             @"subtitle": [NSString stringWithFormat:@"%@ · %@", tz.name, offsetPhrase(local, tz, now)],
             @"value": clockText(now, tz, NO)};
}

#pragma mark Emoji

// Every single-codepoint emoji Apple Color Emoji can draw, with its Unicode name ("grinning face"). Built once.
NSArray<NSArray<NSString *> *> *emojiTable(void) {
    static NSArray *table; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *out = [NSMutableArray new];
        CTFontRef font = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 16, NULL);
        UInt32 ranges[][2] = { {0x1F300, 0x1F5FF}, {0x1F600, 0x1F64F}, {0x1F680, 0x1F6FF}, {0x1F900, 0x1F9FF}, {0x1FA70, 0x1FAFF},
                               {0x2600, 0x26FF}, {0x2700, 0x27BF}, {0x2B00, 0x2BFF}, {0x2190, 0x21FF}, {0x2300, 0x23FF} };
        for (size_t r = 0; r < sizeof(ranges) / sizeof(ranges[0]); r++) {
            for (UInt32 cp = ranges[r][0]; cp <= ranges[r][1]; cp++) {
                UniChar u[2]; CGGlyph g[2] = {0, 0};
                CFIndex n = CFStringGetSurrogatePairForLongCharacter(cp, u) ? 2 : 1;
                if (n == 1) u[0] = (UniChar)cp;
                if (!font || !CTFontGetGlyphsForCharacters(font, u, g, n) || !g[0]) continue;
                NSString *ch = [[NSString alloc] initWithCharacters:u length:(NSUInteger)n];
                NSMutableString *name = [ch mutableCopy];
                if (!CFStringTransform((__bridge CFMutableStringRef)name, NULL, kCFStringTransformToUnicodeName, false)) continue;
                NSString *nm = [[[name stringByReplacingOccurrencesOfString:@"\\N{" withString:@""] stringByReplacingOccurrencesOfString:@"}" withString:@""] lowercaseString];
                if (cp < 0x1F000) ch = [ch stringByAppendingString:@"️"];   // ask for the colour glyph, not the text symbol
                [out addObject:@[ch, nm]];
            }
        }
        if (font) CFRelease(font);
        table = out;
    });
    return table;
}

#pragma mark Ports

// Parses `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fpc` output into @[{pid, name}].
NSArray<NSDictionary *> *parseLsof(NSString *out) {
    NSMutableArray *r = [NSMutableArray new]; NSMutableDictionary *cur = nil;
    for (NSString *l in [out componentsSeparatedByString:@"\n"]) {
        if ([l hasPrefix:@"p"]) { cur = [@{@"pid": @([[l substringFromIndex:1] intValue])} mutableCopy]; [r addObject:cur]; }
        else if ([l hasPrefix:@"c"] && cur && !cur[@"name"]) cur[@"name"] = [l substringFromIndex:1];
    }
    return [r filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pid > 0"]];
}

// Top edge to bottom edge of the display (only a full-screen window can cover the menu bar's strip and the Dock's),
// inside it, and at least a third of its width, so each side of a split view counts.
BOOL windowFillsDisplay(CGRect w, CGRect d) {
    if (CGRectIsEmpty(d) || CGRectIsEmpty(w)) return NO;
    return fabs(CGRectGetMinY(w) - CGRectGetMinY(d)) <= 1 && fabs(CGRectGetMaxY(w) - CGRectGetMaxY(d)) <= 1 &&
           CGRectGetMinX(w) >= CGRectGetMinX(d) - 1 && CGRectGetMaxX(w) <= CGRectGetMaxX(d) + 1 && w.size.width >= d.size.width / 3;
}
