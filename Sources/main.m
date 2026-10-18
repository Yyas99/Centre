// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Build check: the build script runs every new binary with --selftest before installing it.
        if (argc > 1 && !strcmp(argv[1], "--selftest")) return runSelfTests();
        // Single instance: if another Centre is already running, tell it to show and exit.
        NSString *snapDir = nil;
        BOOL readme = NO;
        for (int i = 1; i + 1 < argc; i++) {
            if (!strcmp(argv[i], "--snapshot")) snapDir = [NSString stringWithUTF8String:argv[i + 1]];
            if (!strcmp(argv[i], "--readme")) { snapDir = [NSString stringWithUTF8String:argv[i + 1]]; readme = YES; }
        }
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"com.y.centre";
        pid_t me = [NSProcessInfo processInfo].processIdentifier;
        if (!snapDir) for (NSRunningApplication *r in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid]) {
            if (r.processIdentifier != me && !r.terminated) {
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.y.centre.show" object:nil userInfo:nil deliverImmediately:YES];
                return 0;
            }
        }
        NSApplication *app = [NSApplication sharedApplication];
        CApp *d = [CApp new];
        d.snapshotDir = snapDir; d.readmeMode = readme;
        app.delegate = d;
        // Minimal main menu so Cmd+C/V/X/A work inside the search field.
        NSMenu *bar = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new]; [bar addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Centre"]; appItem.submenu = appMenu;
        [appMenu addItemWithTitle:@"Settings…" action:@selector(openSettings) keyEquivalent:@","].target = d;
        [appMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
        [appMenu addItemWithTitle:@"Quit Centre" action:@selector(terminate:) keyEquivalent:@"q"];
        NSMenuItem *editItem = [NSMenuItem new]; [bar addItem:editItem];
        NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"]; editItem.submenu = edit;
        [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        app.mainMenu = bar;
        [app run];
    }
    return 0;
}

