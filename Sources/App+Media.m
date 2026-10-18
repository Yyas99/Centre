// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"
#import <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRSetElapsedFn)(double);
static MRGetInfoFn MRGetInfo; static MRSendFn MRSend; static MRRegisterFn MRRegister; static MRGetPIDFn MRGetPID; static MRIsPlayingFn MRIsPlaying;
static MRSetElapsedFn MRSetElapsed;
static void loadMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) return;
        MRGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRSend = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
        MRRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRGetPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        MRIsPlaying = (MRIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRSetElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    });
}
// Fallback: synthesize the hardware media keys (needs Accessibility).
static void postMediaKey(int key) {   // NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18
    for (int down = 1; down >= 0; down--) {
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:(down ? 0xa00 : 0xb00)
                                       timestamp:0 windowNumber:0 context:nil subtype:8 data1:((key << 16) | ((down ? 0xa : 0xb) << 8)) data2:-1];
        CGEventPost(kCGHIDEventTap, e.CGEvent);
    }
}

@implementation CApp (Media)

#pragma mark YouTube Music (targets the YTM tab in a Chromium browser via AppleScript + page JavaScript)
static NSString *const kYTMStatusJS = @"(()=>{const b=document.querySelector('ytmusic-player-bar');const v=document.querySelector('video');if(!b||!v||!v.src)return 'EMPTY';const q=s=>{const e=b.querySelector(s);return e?e.textContent.trim():''};const i=b.querySelector('img.image');return JSON.stringify({t:q('.title'),a:q('.byline').split('•')[0].trim(),art:i?i.src:'',p:!v.paused,c:v.currentTime||0,d:v.duration||0})})()";
static NSString *const kYTMToggleJS = @"(()=>{const v=document.querySelector('video');const b=document.querySelector('#play-pause-button');if(!v||!v.src||!b)return 'EMPTY';b.click();return 'OK'})()";
static NSString *const kYTMNextJS = @"(()=>{const b=document.querySelector('ytmusic-player-bar .next-button');if(!b)return 'EMPTY';b.click();return 'OK'})()";
static NSString *const kYTMPrevJS = @"(()=>{const b=document.querySelector('ytmusic-player-bar .previous-button');if(!b)return 'EMPTY';b.click();return 'OK'})()";
static NSString *const kYTMEnsurePlayJS = @"(()=>{const v=document.querySelector('video');const b=document.querySelector('#play-pause-button');if(v&&v.src&&v.paused&&b)b.click();return 'OK'})()";
static NSString *const kYTMStartURL = @"https://music.youtube.com/watch?list=LM";
static NSString *const kYTMRecentURL = @"https://music.youtube.com/history";
// On the history page: once a track is loaded make sure it plays; before that, press play on the most recent song.
static NSString *const kYTMRecentKickJS = @"(()=>{const v=document.querySelector('video');if(v&&v.src){if(v.paused){const p=document.querySelector('#play-pause-button');if(p)p.click()}return 'OK'}const b=document.querySelector('ytmusic-responsive-list-item-renderer ytmusic-play-button-renderer');if(b){b.click();return 'CLICKED'}return 'WAIT'})()";

- (BOOL)ytmMode { return [self.config[@"mediaYTM"] boolValue]; }
// The browser that hosts YouTube Music: the one set in Settings if it's still installed, otherwise the Mac's default browser.
- (NSString *)ytmBrowser {
    NSString *b = self.config[@"ytmBrowser"];
    if ([b isKindOfClass:[NSString class]] && b.length && [[NSWorkspace sharedWorkspace] fullPathForApplication:b]) return b;
    return defaultBrowserName();
}

- (NSString *)ytmScript:(NSString *)js {
    NSString *app = [self ytmBrowser];
    return [NSString stringWithFormat:
        @"if application \"%@\" is not running then return \"NOTRUNNING\"\n"
         "tell application \"%@\"\n"
         "repeat with w in windows\n repeat with t in tabs of w\n  if URL of t contains \"music.youtube.com\" then return (execute t javascript \"%@\")\n end repeat\nend repeat\n"
         "return \"NOTAB\"\nend tell", app, app, js];
}

- (NSString *)ytmProblem:(NSString *)o {
    if ([o containsString:@"JavaScript"]) return [NSString stringWithFormat:@"In %@: View › Developer › Allow JavaScript from Apple Events", [self ytmBrowser]];
    if ([o containsString:@"-1743"] || [o containsString:@"Not authorized"]) return @"Allow Centre in System Settings › Privacy & Security › Automation";
    if ([o containsString:@"-1728"] || [o containsString:@"execute"]) return [NSString stringWithFormat:@"%@ doesn't support scripting", [self ytmBrowser]];
    return nil;
}

- (void)refreshYTM {
    if (self.ytmBusy) return;
    self.ytmBusy = YES;
    __weak CApp *ws = self;
    runOsa([self ytmScript:kYTMStatusJS], ^(NSString *o) {
        ws.ytmBusy = NO;
        BOOL had = ws.hasNow;
        ws.hasNow = YES;
        ws.nowApp = @"YouTube Music";
        if (!ws.nowAppIcon) {
            NSString *p = [[NSWorkspace sharedWorkspace] fullPathForApplication:[ws ytmBrowser]];
            if (p) ws.nowAppIcon = [[NSWorkspace sharedWorkspace] iconForFile:p];
        }
        NSDictionary *d = [o hasPrefix:@"{"] ? [NSJSONSerialization JSONObjectWithData:[o dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([d isKindOfClass:[NSDictionary class]]) {
            ws.nowTitle = [d[@"t"] description] ?: @"";
            ws.nowArtist = [d[@"a"] description] ?: @"";
            ws.isPlaying = [d[@"p"] boolValue];
            ws.nowElapsed = [d[@"c"] doubleValue]; ws.nowDuration = [d[@"d"] doubleValue];
            ws.nowStamp = [NSDate date]; ws.nowRate = ws.isPlaying ? 1 : 0;
            NSString *art = [d[@"art"] description] ?: @"";
            if (art.length && ![art isEqualToString:ws.ytmArtURL]) {
                ws.ytmArtURL = art;
                NSString *big = [[NSRegularExpression regularExpressionWithPattern:@"=w\\d+-h\\d+" options:0 error:nil]
                                 stringByReplacingMatchesInString:art options:0 range:NSMakeRange(0, art.length) withTemplate:@"=w240-h240"];
                NSURL *u = [NSURL URLWithString:big];
                if (u) [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                    NSImage *img = data ? [[NSImage alloc] initWithData:data] : nil;
                    if (img) dispatch_async(dispatch_get_main_queue(), ^{ if ([art isEqualToString:ws.ytmArtURL]) { ws.nowArt = img; [ws updateMediaView]; } });
                }] resume];
            }
        } else {
            NSString *problem = [ws ytmProblem:o];
            ws.nowTitle = @"YouTube Music";
            ws.nowArtist = problem ?: @"Press play to start your Liked Music";
            ws.isPlaying = NO; ws.nowDuration = 0; ws.nowArt = nil; ws.ytmArtURL = nil;
        }
        [ws updateMediaView];
        if (had != ws.hasNow && ws.panel.visible && ws.field.stringValue.length == 0) [ws reloadTable];
    });
}

- (void)ytmStart { [self ytmStartURL:kYTMStartURL kick:kYTMEnsurePlayJS label:@"Starting your Liked Music…"]; }
- (void)ytmPlayRecent { [self ytmStartURL:kYTMRecentURL kick:kYTMRecentKickJS label:@"Starting your recently played music…"]; }

- (void)ytmStartURL:(NSString *)startURL kick:(NSString *)kickJS label:(NSString *)label {
    // Chromium defers media in tabs that have never been shown, so the tab is brought forward inside its
    // window (the browser itself stays in the background) until playback starts, then the previous tab returns.
    NSString *app = [self ytmBrowser];
    NSString *script = [NSString stringWithFormat:
        @"tell application \"%@\"\n"
         "set found to false\nset winId to 0\nset prevIdx to 0\nset tabIdx to 0\n"
         "repeat with w in windows\n set i to 0\n repeat with t in tabs of w\n  set i to i + 1\n"
         "  if URL of t contains \"music.youtube.com\" then\n   set URL of t to \"%@\"\n   set winId to id of w\n   set prevIdx to active tab index of w\n   set tabIdx to i\n   set found to true\n   exit repeat\n  end if\n end repeat\n if found then exit repeat\nend repeat\n"
         "if not found then\n if (count of windows) = 0 then make new window\n set w to window 1\n set winId to id of w\n set prevIdx to active tab index of w\n"
         " make new tab at end of tabs of w with properties {URL:\"%@\"}\n set tabIdx to count of tabs of w\nend if\n"
         "set active tab index of (window id winId) to tabIdx\n"
         "return (winId as text) & \"|\" & (prevIdx as text) & \"|\" & (tabIdx as text)\nend tell", app, startURL, startURL];
    __weak CApp *ws = self;
    self.nowTitle = @"YouTube Music"; self.nowArtist = label; [self updateMediaView];
    runOsa(script, ^(NSString *o) {
        NSString *problem = [ws ytmProblem:o];
        if (problem) { ws.nowArtist = problem; [ws updateMediaView]; return; }
        NSArray *parts = [o componentsSeparatedByString:@"|"];
        if (parts.count != 3) { [ws refreshYTM]; return; }
        [ws ytmWaitForPlayback:0 window:parts[0] previous:[parts[1] integerValue] tab:[parts[2] integerValue] kick:kickJS];
    });
}

- (void)ytmWaitForPlayback:(NSInteger)attempt window:(NSString *)winId previous:(NSInteger)prev tab:(NSInteger)tab kick:(NSString *)kickJS {
    __weak CApp *ws = self;
    NSString *app = [self ytmBrowser];
    runOsa([self ytmScript:kYTMStatusJS], ^(NSString *o) {
        NSDictionary *d = [o hasPrefix:@"{"] ? [NSJSONSerialization JSONObjectWithData:[o dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        BOOL playing = [d isKindOfClass:[NSDictionary class]] && [d[@"p"] boolValue];
        if (playing) {
            if (prev > 0 && prev != tab)
                runOsa([NSString stringWithFormat:@"tell application \"%@\" to set active tab index of (window id %@) to %ld", app, winId, (long)prev], nil);
            [ws refreshYTM];
            return;
        }
        if (attempt >= 20) {   // ~20 s: leave the tab showing so the user can press play there
            ws.nowArtist = [NSString stringWithFormat:@"Couldn't start automatically — press play in %@", app];
            [ws updateMediaView];
            return;
        }
        if (attempt >= 2 && attempt % 3 == 2) runOsa([ws ytmScript:kickJS], nil);   // page loaded but waiting for a play gesture
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws ytmWaitForPlayback:attempt + 1 window:winId previous:prev tab:tab kick:kickJS];
        });
    });
}

- (void)ytmCommand:(int)cmd {
    NSString *js = cmd == 4 ? kYTMNextJS : cmd == 5 ? kYTMPrevJS : kYTMToggleJS;
    __weak CApp *ws = self;
    if (cmd == 2 && self.nowDuration > 0) { self.nowElapsed = [self currentElapsed]; self.nowStamp = [NSDate date]; self.isPlaying = !self.isPlaying; self.nowRate = self.isPlaying ? 1 : 0; [self updateMediaView]; }
    runOsa([self ytmScript:js], ^(NSString *o) {
        if ([o isEqualToString:@"NOTRUNNING"] || [o isEqualToString:@"NOTAB"] || ([o isEqualToString:@"EMPTY"] && cmd == 2)) { [ws ytmStart]; return; }
        NSString *problem = [ws ytmProblem:o];
        if (problem) { ws.nowArtist = problem; [ws updateMediaView]; return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshYTM]; });
    });
}

#pragma mark Now Playing
- (void)startMediaObservers {
    loadMediaRemote();
    if (MRRegister) MRRegister(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"])
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshNowPlaying) name:n object:nil];
}
- (void)refreshNowPlaying {
    if ([self ytmMode]) { if (self.panel.visible) [self refreshYTM]; return; }
    loadMediaRemote();
    if (!MRGetInfo) return;
    __weak CApp *ws = self;
    MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *d = (__bridge NSDictionary *)info;
        NSString *title = [d[@"kMRMediaRemoteNowPlayingInfoTitle"] isKindOfClass:[NSString class]] ? d[@"kMRMediaRemoteNowPlayingInfoTitle"] : @"";
        BOOL had = ws.hasNow;
        BOOL sameTrack = [title isEqualToString:ws.nowTitle ?: @""];
        ws.hasNow = title.length > 0;
        ws.nowTitle = title;
        ws.nowArtist = [d[@"kMRMediaRemoteNowPlayingInfoArtist"] isKindOfClass:[NSString class]] ? d[@"kMRMediaRemoteNowPlayingInfoArtist"] : @"";
        NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        NSImage *img = [art isKindOfClass:[NSData class]] ? [[NSImage alloc] initWithData:art] : nil;
        // Browsers briefly publish info without artwork on play/pause — keep the last artwork for the same track.
        if (img || !sameTrack) ws.nowArt = img;
        ws.nowDuration = [d[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        ws.nowElapsed = [d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        ws.nowStamp = [d[@"kMRMediaRemoteNowPlayingInfoTimestamp"] isKindOfClass:[NSDate class]] ? d[@"kMRMediaRemoteNowPlayingInfoTimestamp"] : [NSDate date];
        ws.nowRate = [d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
        ws.isPlaying = ws.nowRate > 0;
        if (MRGetPID) MRGetPID(dispatch_get_main_queue(), ^(int pid) {
            NSRunningApplication *ra = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
            ws.nowApp = ra.localizedName ?: @""; ws.nowAppIcon = ra.icon; [ws updateMediaView]; });
        if (MRIsPlaying) MRIsPlaying(dispatch_get_main_queue(), ^(Boolean p) { ws.isPlaying = p; [ws updateMediaView]; });
        [ws updateMediaView];
        if (had != ws.hasNow && ws.panel.visible && ws.field.stringValue.length == 0) [ws reloadTable];
    });
}
- (void)updateMediaView {
    CMediaView *m = self.media; if (!m) return;
    m.titleL.stringValue = self.nowTitle ?: @"";
    NSString *sub = self.nowArtist ?: @"";
    if (self.nowApp.length) sub = sub.length ? [NSString stringWithFormat:@"%@  ·  %@", sub, self.nowApp] : self.nowApp;
    m.subL.stringValue = sub;
    m.art.image = self.nowArt ?: (self.nowAppIcon ?: [NSApp applicationIconImage]);
    [m setPlaying:self.isPlaying];
    [m setElapsed:[self currentElapsed] duration:self.nowDuration];
    [m setNeedsDisplay:YES];
}
- (double)currentElapsed {
    double el = self.nowElapsed;
    if (self.isPlaying && self.nowStamp) el += -[self.nowStamp timeIntervalSinceNow] * (self.nowRate > 0 ? self.nowRate : 1);
    return self.nowDuration > 0 ? MIN(MAX(el, 0), self.nowDuration) : MAX(el, 0);
}
// Jump to a point in the track (click or drag on the progress bar).
- (void)mediaSeek:(double)fraction {
    if (self.nowDuration <= 0) return;
    double t = MAX(0, MIN(self.nowDuration - 0.5, fraction * self.nowDuration));
    self.nowElapsed = t; self.nowStamp = [NSDate date]; [self updateMediaView];
    __weak CApp *ws = self;
    if ([self ytmMode]) {
        runOsa([self ytmScript:[NSString stringWithFormat:@"(()=>{const v=document.querySelector('video');if(!v)return 'EMPTY';v.currentTime=%.2f;return 'OK'})()", t]], ^(NSString *o) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshYTM]; }); });
        return;
    }
    loadMediaRemote();
    if (MRSetElapsed) MRSetElapsed(t);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshNowPlaying]; });
}
- (void)mediaCommand:(int)cmd {   // 2 toggle, 4 next, 5 previous
    if ([self ytmMode]) { [self ytmCommand:cmd]; return; }
    loadMediaRemote();
    BOOL sent = MRSend ? MRSend(cmd, NULL) : NO;
    if (!sent) postMediaKey(cmd == 4 ? 17 : cmd == 5 ? 18 : 16);
    if (cmd == 2) { self.nowElapsed = [self currentElapsed]; self.nowStamp = [NSDate date]; self.isPlaying = !self.isPlaying; [self updateMediaView]; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refreshNowPlaying]; });
}
@end
