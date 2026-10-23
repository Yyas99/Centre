// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import "App.h"
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/wait.h>
extern char **environ;

// --agent <dir>: the build agent. launchd starts it whenever a job lands in <dir>/.agent/inbox; it runs each job
// through ./centre (build, restart, test, shots, snap, status, log, crash, stop), writes <id>.log and <id>.exit to
// .agent/out, and exits once the inbox is empty. Being the Centre binary, it works under Centre's own permissions.
static int runAgent(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *inbox = [dir stringByAppendingPathComponent:@".agent/inbox"], *outDir = [dir stringByAppendingPathComponent:@".agent/out"];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSSet *allowed = [NSSet setWithArray:@[@"build", @"restart", @"stop", @"test", @"shots", @"snap", @"status", @"log", @"crash", @"trace", @"install", @"release"]];
    setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin", 1);
    setenv("CENTRE_AGENT", "1", 1);
    for (int round = 0; round < 100; round++) {
        NSArray *all = [fm contentsOfDirectoryAtPath:inbox error:nil] ?: @[];
        NSArray *jobs = [[all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.job'"]] sortedArrayUsingSelector:@selector(compare:)];
        if (!jobs.count) {   // launchd keeps relaunching while the inbox has anything in it, so leave it empty
            for (NSString *f in all) [fm removeItemAtPath:[inbox stringByAppendingPathComponent:f] error:nil];
            return 0;
        }
        for (NSString *name in jobs) {
            NSString *path = [inbox stringByAppendingPathComponent:name], *jid = name.stringByDeletingPathExtension;
            NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
            NSString *cmd = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [fm removeItemAtPath:path error:nil];
            NSString *log = [outDir stringByAppendingPathComponent:[jid stringByAppendingString:@".log"]];
            int fd = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644), code = 2;
            if (fd < 0) continue;
            if (![allowed containsObject:cmd]) dprintf(fd, "Unknown command: %s\n", cmd.UTF8String);
            else {
                posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
                posix_spawn_file_actions_adddup2(&fa, fd, 1); posix_spawn_file_actions_adddup2(&fa, fd, 2);
                char *argv[] = {"/bin/bash", "-c", "cd \"$1\" && exec /bin/bash ./centre \"$2\"", "agent",
                                (char *)dir.fileSystemRepresentation, (char *)cmd.UTF8String, NULL};
                pid_t pid = 0;
                if (posix_spawn(&pid, "/bin/bash", &fa, NULL, argv, environ) == 0) {
                    int st = 0, waited = 0;
                    while (waitpid(pid, &st, WNOHANG) == 0) {
                        if (++waited > 6000) { kill(pid, SIGKILL); waitpid(pid, &st, 0); dprintf(fd, "\nAgent: timed out after 10 minutes\n"); break; }
                        usleep(100000);
                    }
                    code = waited > 6000 ? 124 : WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
                } else dprintf(fd, "Agent: could not start bash\n");
                posix_spawn_file_actions_destroy(&fa);
            }
            close(fd);
            [[NSString stringWithFormat:@"%d\n", code] writeToFile:[outDir stringByAppendingPathComponent:[jid stringByAppendingString:@".exit"]]
                                                       atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Build check: the build script runs every new binary with --selftest before installing it.
        if (argc > 1 && !strcmp(argv[1], "--selftest")) return runSelfTests();
        if (argc > 2 && !strcmp(argv[1], "--agent")) {
            // Development copy only, and only for its own folder: an installed Centre never runs build jobs,
            // and no other folder's script can borrow Centre's permissions this way.
            NSString *dir = [NSString stringWithUTF8String:argv[2]].stringByStandardizingPath;
            NSString *home = [[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent].stringByStandardizingPath;
            BOOL dev = [[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"Sources"]];
            if (!dev || ![dir isEqualToString:home]) { fprintf(stderr, "Centre: --agent only runs from its development folder\n"); return 1; }
            return runAgent(dir);
        }
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
            // LaunchServices can still list a copy that has just exited (right after a self-rebuild);
            // only defer to one that is really alive, or both would be gone.
            // A screenshot run (--snapshot/--readme) is never "the" Centre: it runs hidden with no Dock presence.
            if (r.activationPolicy == NSApplicationActivationPolicyProhibited) continue;
            if (r.processIdentifier != me && !r.terminated && kill(r.processIdentifier, 0) == 0) {
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.y.centre.show" object:nil userInfo:nil deliverImmediately:YES];
                NSString *tp = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".agent/trace.log"];
                FILE *tf = fopen(tp.fileSystemRepresentation, "a");
                if (tf) { fprintf(tf, "pid %d  deferred to the running Centre (pid %d)\n", me, r.processIdentifier); fclose(tf); }
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
        [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
        NSMenuItem *redo = [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
        redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        [edit addItem:[NSMenuItem separatorItem]];
        [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        app.mainMenu = bar;
        [app run];
    }
    return 0;
}

