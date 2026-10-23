// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
// Updates: Centre checks GitHub Releases for a newer version, downloads its zip, and only installs it if the new
// app is signed by the same certificate as this one (so an update can't come from anyone else, and macOS keeps
// every permission). The swap happens after Centre quits; the old copy is kept until the new one is in place.
#import "App.h"
#import <Security/Security.h>

static NSString *const kUpdateRepo = @"Yyas99/Centre";
NSString *const CentreUpdateChanged = @"CentreUpdateChanged";

// 1.2.10 > 1.2.9; missing parts count as 0 ("1.0" == "1.0.0"); a leading "v" is ignored.
static NSComparisonResult compareVersions(NSString *a, NSString *b) {
    NSArray *x = [[a stringByTrimmingCharactersInSet:[NSCharacterSet letterCharacterSet]] componentsSeparatedByString:@"."];
    NSArray *y = [[b stringByTrimmingCharactersInSet:[NSCharacterSet letterCharacterSet]] componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        NSInteger p = i < x.count ? [x[i] integerValue] : 0, q = i < y.count ? [y[i] integerValue] : 0;
        if (p != q) return p < q ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}
static NSString *currentVersion(void) { return [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"0"; }

@implementation CApp (Update)

- (void)setUpdateStateAndNotify:(NSString *)s {
    self.updateState = s ?: @"";
    if (self.status) [self updateStatusMenu];
    [[NSNotificationCenter defaultCenter] postNotificationName:CentreUpdateChanged object:nil];
}

- (void)startUpdateChecks {
    if ([self isDevelopmentCopy] || self.snapshotDir) return;            // the development copy updates from its source
    __weak CApp *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![ws.config[@"autoUpdateCheck"] isEqual:@NO]) [ws checkForUpdates:NO];
    });
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:6 * 3600 repeats:YES block:^(NSTimer *tm) {
        if (![ws.config[@"autoUpdateCheck"] isEqual:@NO]) [ws checkForUpdates:NO];
    }];
    t.tolerance = 600;
}

- (void)checkForUpdates:(BOOL)byUser {
    if ([self isDevelopmentCopy]) { if (byUser) showHUD(@"This is the development copy — it updates from its source", @"hammer.fill"); return; }
    if ([self.updateState isEqualToString:@"checking"] || [self.updateState isEqualToString:@"downloading"] || [self.updateState isEqualToString:@"installing"]) return;
    [self setUpdateStateAndNotify:@"checking"];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kUpdateRepo]]];
    [rq setValue:[@"Centre/" stringByAppendingString:currentVersion()] forHTTPHeaderField:@"User-Agent"];
    [rq setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    rq.timeoutInterval = 15; rq.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak CApp *ws = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            CApp *me = ws; if (!me) return;
            me.updateCheckedAt = [NSDate date];
            if (err || ![json isKindOfClass:[NSDictionary class]] || (code != 200 && code != 404)) {
                [me setUpdateStateAndNotify:code == 403 ? @"GitHub is busy — try again later" : @"Couldn't reach GitHub"];
                if (byUser) showHUD(@"Couldn't check for updates — are you online?", @"wifi.exclamationmark");
                return;
            }
            NSString *tag = [json[@"tag_name"] isKindOfClass:[NSString class]] ? json[@"tag_name"] : nil;
            NSString *zip = nil;
            for (NSDictionary *a in ([json[@"assets"] isKindOfClass:[NSArray class]] ? json[@"assets"] : @[]))
                if ([a isKindOfClass:[NSDictionary class]] && [[a[@"name"] description] hasSuffix:@".zip"]) { zip = [a[@"browser_download_url"] description]; break; }
            if (code == 404 || !tag || !zip || compareVersions(tag, currentVersion()) != NSOrderedDescending) {
                me.update = nil; [me setUpdateStateAndNotify:@""];
                if (byUser) showHUD([NSString stringWithFormat:@"Centre %@ is the latest version", currentVersion()], @"checkmark.seal.fill");
                return;
            }
            NSString *ver = [tag stringByTrimmingCharactersInSet:[NSCharacterSet letterCharacterSet]];
            NSString *notes = [json[@"body"] isKindOfClass:[NSString class]] ? json[@"body"] : @"";
            me.update = @{@"version": ver, @"zip": zip, @"notes": notes, @"page": [json[@"html_url"] description] ?: @""};
            [me setUpdateStateAndNotify:@""];
            if (byUser) { [me installUpdate]; return; }                   // asked for it: just do it
            if (![me.config[@"updateNotified"] isEqual:ver]) {            // tell you once per version, never nag
                NSMutableDictionary *c = [me mutableConfig]; c[@"updateNotified"] = ver; [me writeConfig:c];
                showHUDFor([NSString stringWithFormat:@"Centre %@ is available — install it from Settings or the menu bar", ver], @"arrow.down.circle.fill", 5);
            }
        });
    }] resume];
}

- (NSString *)updateSummary {
    if ([self isDevelopmentCopy]) return @"Development copy: updates come from its source.";
    NSString *s = self.updateState;
    if ([s isEqualToString:@"checking"]) return @"Checking…";
    if ([s isEqualToString:@"downloading"]) return [NSString stringWithFormat:@"Downloading %@…", self.update[@"version"] ?: @"the update"];
    if ([s isEqualToString:@"installing"]) return @"Installing — Centre will reopen in a moment.";
    if (s.length) return s;
    if (self.update) {
        NSString *first = [[[self.update[@"notes"] componentsSeparatedByString:@"\n"] firstObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return [NSString stringWithFormat:@"Version %@ is available%@", self.update[@"version"], first.length ? [@": " stringByAppendingString:first] : @"."];
    }
    if (!self.updateCheckedAt) return [NSString stringWithFormat:@"You have %@.", currentVersion()];
    return [NSString stringWithFormat:@"%@ is the latest version.", currentVersion()];
}

// Same signer as this copy, intact seal, same bundle, the advertised version.
- (NSString *)problemWithUpdateAt:(NSURL *)app version:(NSString *)ver {
    SecCodeRef me = NULL; SecRequirementRef req = NULL; SecStaticCodeRef nc = NULL; NSString *problem = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &me) != errSecSuccess || SecCodeCopyDesignatedRequirement((SecStaticCodeRef)me, kSecCSDefaultFlags, &req) != errSecSuccess)
        problem = @"this copy of Centre isn't signed";
    else if (SecStaticCodeCreateWithPath((__bridge CFURLRef)app, kSecCSDefaultFlags, &nc) != errSecSuccess)
        problem = @"the download isn't an app";
    else if (SecStaticCodeCheckValidity(nc, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, req) != errSecSuccess)
        problem = @"it isn't signed by the same certificate";
    if (me) CFRelease(me);
    if (req) CFRelease(req);
    if (nc) CFRelease(nc);
    if (problem) return problem;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqual:[NSBundle mainBundle].bundleIdentifier]) return @"it's a different app";
    if (compareVersions(info[@"CFBundleShortVersionString"] ?: @"0", ver) != NSOrderedSame) return @"its version doesn't match the release";
    return nil;
}

- (void)failUpdate:(NSString *)why {
    [self trace:[@"update failed: " stringByAppendingString:why]];
    [self setUpdateStateAndNotify:[@"Update failed: " stringByAppendingString:why]];
    showHUDFor([@"Update failed — " stringByAppendingString:why], @"exclamationmark.triangle.fill", 4);
}

- (void)installUpdate {
    if (!self.update) { [self checkForUpdates:YES]; return; }
    if ([self.updateState isEqualToString:@"downloading"] || [self.updateState isEqualToString:@"installing"]) return;
    NSString *ver = self.update[@"version"]; NSURL *url = [NSURL URLWithString:self.update[@"zip"]];
    if (!url) { [self failUpdate:@"the release has no download"]; return; }
    [self setUpdateStateAndNotify:@"downloading"];
    [self trace:[@"downloading update " stringByAppendingString:ver]];
    __weak CApp *ws = self;
    [[[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"CentreUpdate-" stringByAppendingString:[NSUUID UUID].UUIDString]];
        NSString *zip = [dir stringByAppendingPathComponent:@"update.zip"], *why = nil;
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (err || !loc || code != 200 || ![fm moveItemAtPath:loc.path toPath:zip error:nil]) why = @"the download didn't finish";
        NSString *newApp = [dir stringByAppendingPathComponent:@"Centre.app"];
        if (!why) {
            NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/ditto" arguments:@[@"-x", @"-k", zip, dir]]; [t waitUntilExit];
            if (t.terminationStatus != 0 || ![fm fileExistsAtPath:newApp]) why = @"the download couldn't be opened";
        }
        if (!why) { NSTask *x = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/xattr" arguments:@[@"-cr", newApp]]; [x waitUntilExit]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            CApp *me = ws; if (!me) return;
            NSString *problem = why ?: [me problemWithUpdateAt:[NSURL fileURLWithPath:newApp] version:ver];
            if (problem) { [fm removeItemAtPath:dir error:nil]; [me failUpdate:problem]; return; }
            [me setUpdateStateAndNotify:@"installing"];
            [me trace:[@"installing update " stringByAppendingString:ver]];
            [me saveClipHandoff];
            // After Centre quits: move the old app aside, put the new one in its place (or put the old one back), reopen.
            NSString *dest = [NSBundle mainBundle].bundlePath;
            NSString *sh = [NSString stringWithFormat:
                @"while kill -0 %d 2>/dev/null; do sleep 0.1; done; sleep 0.3; D=%@; N=%@; "
                 "rm -rf \"$D.old\"; if mv \"$D\" \"$D.old\"; then if mv \"$N\" \"$D\"; then rm -rf \"$D.old\"; else mv \"$D.old\" \"$D\"; fi; fi; "
                 "rm -rf %@; open \"$D\"", getpid(), shellQuote(dest), shellQuote(newApp), shellQuote(dir)];
            NSTask *h = [NSTask new]; h.launchPath = @"/bin/sh"; h.arguments = @[@"-c", sh]; [h launch];
            [NSApp terminate:nil];
        });
    }] resume];
}
@end
