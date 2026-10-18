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

    printf("Self-test: %d/%d passed\n", checks - failures, checks);
    return failures;
}
