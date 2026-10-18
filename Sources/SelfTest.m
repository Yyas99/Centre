// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Pure-logic checks run on every build (./centre runs `Centre --selftest`); a failing build is never installed.
#import "Centre.h"

static int failures, checks;
static void check(BOOL ok, NSString *what) {
    checks++;
    if (!ok) { failures++; printf("  FAIL  %s\n", what.UTF8String); }
}

int runSelfTests(void) {
    failures = 0; checks = 0;

    // fuzzy matching: prefixes beat scattered matches; misses are negative
    check(fuzzyScore(@"saf", @"Safari") > fuzzyScore(@"saf", @"System Information"), @"prefix ranks above scattered match");
    check(fuzzyScore(@"xyz", @"Safari") < 0, @"non-match is negative");
    check(fuzzyScore(@"ss", @"System Settings") > 0, @"word-start initials match");

    // passwords: requested length, every character class present
    NSString *pw = genPassword(24, YES);
    check(pw.length == 24, @"password length");
    check([pw rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound, @"password has a digit");
    check([pw rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"!@#$%^&*-_=+?"]].location != NSNotFound, @"password has a symbol");
    check([genPassword(16, NO) rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"!@#$%^&*-_=+?"]].location == NSNotFound, @"symbol-free password");
    check(genPIN(6).length == 6, @"PIN length");

    // formatting
    check([fmtTime(3725) isEqualToString:@"1:02:05"], @"fmtTime hours");
    check([fmtTime(71) isEqualToString:@"1:11"], @"fmtTime minutes");
    check([prettyHotkey(@"cmd+space") isEqualToString:@"⌘ Space"], @"prettyHotkey");
    check([urlEncode(@"a b&c") isEqualToString:@"a%20b%26c"], @"urlEncode");

    // calculator
    double v = 0;
    check(evaluateMath(@"12*7+3", &v) && fabs(v - 87) < 1e-9, @"math: 12*7+3");
    check(evaluateMath(@"15% of 200", &v) && fabs(v - 30) < 1e-9, @"math: 15% of 200");
    check(evaluateMath(@"2^10", &v) && fabs(v - 1024) < 1e-9, @"math: 2^10");
    check(!evaluateMath(@"hello", &v), @"math: words are not maths");
    check(!evaluateMath(@"2024", &v), @"math: a bare number is not a calculation");

    // unit conversions
    check(convertUnits(@"5 km to mi", &v) && fabs(v - 3.10685596) < 1e-6, @"units: km → mi");
    check(convertUnits(@"100 f to c", &v) && fabs(v - 37.7777778) < 1e-6, @"units: °F → °C");
    check(convertUnits(@"0 c in k", &v) && fabs(v - 273.15) < 1e-9, @"units: °C → K");
    check(convertUnits(@"2 gb in mb", &v) && fabs(v - 2000) < 1e-9, @"units: GB → MB");
    check(convertUnits(@"90 min to h", &v) && fabs(v - 1.5) < 1e-9, @"units: min → h");
    check(convertUnits(@"5 kg to mi", &v) == nil, @"units: mass ↛ length");
    check(convertUnits(@"Safari", &v) == nil, @"units: plain text is not a conversion");

    // timer durations
    check(parseDuration(@"10m") == 600, @"duration: 10m");
    check(parseDuration(@"1h30m") == 5400, @"duration: 1h30m");
    check(parseDuration(@"90s") == 90, @"duration: 90s");
    check(parseDuration(@"1:30") == 90, @"duration: 1:30");
    check(parseDuration(@"25") == 1500, @"duration: bare number = minutes");
    check(parseDuration(@"45min") == 2700, @"duration: 45min");
    check(parseDuration(@"tea") == 0, @"duration: not a duration");

    // path completion, against a throwaway tree standing in for the home folder
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"centre-selftest-%d", getpid()]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[home stringByAppendingPathComponent:@"Documents/Projects"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[home stringByAppendingPathComponent:@"Downloads"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"x" writeToFile:[home stringByAppendingPathComponent:@"Documents/report.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSString *(^firstPath)(NSString *) = ^NSString *(NSString *q) { return [pathCompletions(q, home, 8)[@"items"] firstObject][@"path"]; };
    NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
    check([firstPath(@"/documents") isEqualToString:docs], @"paths: /documents finds the home Documents folder");
    check([firstPath(@"~/doc") isEqualToString:docs], @"paths: ~/doc completes to Documents");
    check([firstPath(@"~/documents/rep") isEqualToString:[docs stringByAppendingPathComponent:@"report.txt"]], @"paths: any-case folder, file prefix");
    check([firstPath(@"~/Documents/") isEqualToString:[docs stringByAppendingPathComponent:@"Projects"]], @"paths: folders list before files");
    check([firstPath(@"/doc/proj") isEqualToString:[docs stringByAppendingPathComponent:@"Projects"]], @"paths: prefix folder steps");
    check([pathCompletions(@"~/Documents/", home, 8)[@"dir"] isEqualToString:docs], @"paths: listed folder is reported");
    check([firstPath(@"/applications") isEqualToString:@"/Applications"], @"paths: real root folders still win");
    check([pathCompletions(@"documents", home, 8)[@"items"] count] == 0, @"paths: plain words are not paths");
    [fm removeItemAtPath:home error:nil];

    // text transforms
    check([transformText(@"Title Case", @"hello wORLD it's") isEqualToString:@"Hello World It's"], @"transform: title case");
    check([transformText(@"Sentence case", @"HELLO there. how ARE you") isEqualToString:@"Hello there. How are you"], @"transform: sentence case");
    check([transformText(@"camelCase", @"Hello big world") isEqualToString:@"helloBigWorld"], @"transform: camelCase");
    check([transformText(@"snake_case", @"helloBigWorld") isEqualToString:@"hello_big_world"], @"transform: snake_case from camel");
    check([transformText(@"kebab-case", @"Hello Big_World") isEqualToString:@"hello-big-world"], @"transform: kebab-case");
    check([transformText(@"Unique Lines", @"a\nb\na\n") isEqualToString:@"a\nb"], @"transform: unique lines");
    check([transformText(@"JSON Minify", @"{ \"a\" : [1, 2] }") isEqualToString:@"{\"a\":[1,2]}"], @"transform: JSON minify");
    check(transformText(@"JSON Pretty", @"{not json") == nil, @"transform: invalid JSON is refused");
    check([transformText(@"Base64 Decode", transformText(@"Base64 Encode", @"Centre ✓")) isEqualToString:@"Centre ✓"], @"transform: base64 round trip");
    check([transformText(@"Straight Quotes", @"“hi” it’s") isEqualToString:@"\"hi\" it's"], @"transform: straight quotes");
    check([cleanURL(@"https://x.com/a?utm_source=t&id=7&fbclid=9") isEqualToString:@"https://x.com/a?id=7"], @"clean URL keeps real parameters");
    check([textStats(@"two words") hasPrefix:@"2 words"], @"text stats");

    // snippets, flows, quoting, hotkeys
    NSDate *fixed = [NSDate dateWithTimeIntervalSince1970:1792300000];   // Sun 18 Oct 2026, 05:06 UTC
    check([expandSnippet(@"[{clipboard}]", @"clip", fixed) isEqualToString:@"[clip]"], @"snippet: clipboard placeholder");
    check([expandSnippet(@"{iso}", nil, fixed) hasPrefix:@"2026-10-"], @"snippet: iso date");
    check([flowSteps(@"# focus\nKeep Awake\n\n  wait 1  \n") isEqualToArray:@[@"Keep Awake", @"wait 1"]], @"flow: steps skip comments and blanks");
    check([shellQuote(@"it's") isEqualToString:@"'it'\\''s'"], @"shell quoting");
    check([appleScriptQuote(@"say \"hi\"") isEqualToString:@"\"say \\\"hi\\\"\""], @"AppleScript quoting");
    UInt32 hkey = 0, hmods = 0;
    check(parseHotkey(@"ctrl+alt+l", &hkey, &hmods) && hkey == kVK_ANSI_L && hmods == (controlKey | optionKey), @"hotkey: ctrl+alt+l");
    check(!parseHotkey(@"l", NULL, NULL), @"hotkey: a bare key is refused");

    // time zones (fixed instant, Melbourne as home)
    NSTimeZone *mel = [NSTimeZone timeZoneWithName:@"Australia/Melbourne"];
    check([timeQuery(@"3pm melbourne in london", fixed, mel)[@"value"] isEqualToString:@"5:00 am"], @"time: 3pm Melbourne in London");
    check([timeQuery(@"9:30am riyadh to sydney", fixed, mel)[@"value"] isEqualToString:@"5:30 pm"], @"time: Riyadh to Sydney");
    check(timeQuery(@"time in tokyo", fixed, mel) != nil && timeQuery(@"oslo time", fixed, mel) != nil, @"time: now in a city");
    check(timeQuery(@"5 km in mi", fixed, mel) == nil && timeQuery(@"time in narnia", fixed, mel) == nil, @"time: non-times are ignored");

    // emoji and ports
    NSArray *emo = emojiTable(); BOOL grin = NO;
    for (NSArray *e in emo) if ([e[1] isEqualToString:@"grinning face"]) grin = YES;
    check(emo.count > 800 && grin, @"emoji: table built with names");
    NSArray *ls = parseLsof(@"p812\ncnode\nf23\np99\ncPython\n");
    check(ls.count == 2 && [ls[0][@"name"] isEqualToString:@"node"] && [ls[1][@"pid"] intValue] == 99, @"ports: lsof parsing");

    printf("Self-test: %d/%d passed\n", checks - failures, checks);
    return failures;
}
