// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).

#import "Centre.h"
#import "Views.h"

@class CSettings;

@interface CApp : NSObject <NSApplicationDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) CPanel *panel;
@property (nonatomic, strong) NSVisualEffectView *fx;
@property (nonatomic, strong) CField *field;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSView *separator, *footer, *footerLine;
@property (nonatomic, strong) NSImageView *searchIcon;
@property (nonatomic, strong) NSTextField *escPill, *footerLeft, *footerRight, *gridTitle;
@property (nonatomic, strong) CKeyHints *hints;
@property (nonatomic, strong) NSImageView *footerIcon;
@property (nonatomic, strong) CMediaView *media;
@property (nonatomic, strong) NSTimer *mediaTimer;
@property (nonatomic) BOOL hasNow, isPlaying;
@property (nonatomic, copy) NSString *nowTitle, *nowArtist, *nowApp;
@property (nonatomic, strong) NSImage *nowArt, *nowAppIcon;
@property (nonatomic, strong) NSDate *nowStamp;
@property (nonatomic) double nowDuration, nowElapsed, nowRate;
@property (nonatomic) BOOL ytmBusy;
@property (nonatomic, copy) NSString *ytmArtURL;
@property (nonatomic, strong) CGridView *grid;
@property (nonatomic) BOOL gridMode;
@property (nonatomic, strong) CChip *chip;
@property (nonatomic, strong) CQuickStrip *quick;
@property (nonatomic, strong) CHomeList *homeList;
@property (nonatomic) NSInteger homeApps, homeQuick;        // items = [apps…, quick actions…, list rows…] on the home screen
@property (nonatomic, strong) NSArray *homeEntries;         // list headers + rows
@property (nonatomic, strong) NSArray<NSDictionary *> *recentFiles;   // @{path, date}, newest first
@property (nonatomic, strong) NSMetadataQuery *recentQuery;
@property (nonatomic, strong) id recentObserver;
@property (nonatomic, copy) NSString *modeLabel;   // active prefix mode, shown as a chip in the search row
@property (nonatomic) BOOL cmdHeld;                // ⌘ down: rows show their ⌘1…⌘9 shortcuts
@property (nonatomic, strong) CItem *armedItem;    // irreversible command waiting for a second ↩
@property (nonatomic, copy) NSString *armedSubtitle;
@property (nonatomic, strong) NSDate *armedAt;
@property (nonatomic, strong) NSStatusItem *status;
@property (nonatomic, strong) NSArray<CItem *> *items;
@property (nonatomic) NSInteger selected;
@property (nonatomic, strong) NSArray<CItem *> *apps;          // scanned apps
@property (nonatomic, strong) NSMutableDictionary *usage;      // path -> @{count,last}
@property (nonatomic, strong) NSMutableDictionary *iconCache;
@property (nonatomic, strong) NSMutableArray<NSString *> *clips;
@property (nonatomic) NSInteger pbCount;
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) NSDate *configMtime;
@property (nonatomic, strong) NSRunningApplication *previousApp;
@property (nonatomic, strong) NSMetadataQuery *fileQuery;
@property (nonatomic, strong) id fileQueryObserver;
@property (nonatomic, strong) NSTimer *fileDebounce;
@property (nonatomic, strong) NSArray<NSString *> *dockCache;
@property (nonatomic) NSTimeInterval dockCacheAt;
@property (nonatomic, copy) NSString *currentQuery;
@property (nonatomic) EventHotKeyRef hotKeyRef;
@property (nonatomic) NSTimeInterval lastScan;
@property (nonatomic) BOOL rebuilding;
@property (nonatomic, copy) NSString *snapshotDir;
@property (nonatomic) BOOL readmeMode;                       // --readme <dir>: curated screenshots with neutral sample data
@property (nonatomic, strong) NSArray<CItem *> *readmeApps;   // --snapshot <dir>: render the UI offscreen to PNGs and exit
@property (nonatomic, strong) NSDate *failedSource;
@property (nonatomic, strong) CSettings *settings;
@property (nonatomic) BOOL hotkeyFailed;                               // another app owns the shortcut
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *timers;   // @{end, label, total, timer}
@property (nonatomic) IOPMAssertionID awakeAssertion;                  // non-zero while Keep Awake is on
- (NSString *)configPath;
- (void)loadConfig;
- (NSString *)usagePath;
- (void)loadUsage;
- (void)recordUse:(NSString *)key;
- (double)usageBoost:(NSString *)key;
- (void)scanApps;
- (NSArray<NSString *> *)dockAppPaths;
- (NSImage *)iconFor:(CItem *)it;
- (void)controlTextDidChange:(NSNotification *)n;
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel;
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t;
- (BOOL)selectionShouldChangeInTableView:(NSTableView *)t;
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row;
- (void)pollClipboard;
- (void)registerHotKey;
- (void)unregisterHotKey;
- (void)updateStatusItem;
- (void)updateStatusMenu;
- (void)openConfigFile;
- (void)openSettings;
- (void)writeConfig:(NSDictionary *)c;
- (void)setLaunchAtLogin:(BOOL)on;
- (void)resetUsage;
- (void)grantAX;
- (void)toggleLoginItem;
- (BOOL)launchesAtLogin;
- (NSString *)sourceDir;
- (BOOL)sourceIsNewer;
- (NSDate *)sourceDate;
- (void)rebuild;
- (void)rebuildQuietly:(BOOL)quiet;
- (NSString *)handoffPath;
- (void)saveClipHandoff;
- (void)loadClipHandoff;
- (void)applicationDidFinishLaunching:(NSNotification *)n;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)a hasVisibleWindows:(BOOL)f;
- (void)applicationWillTerminate:(NSNotification *)n;
@end

@interface CApp (Search)
- (NSArray<CItem *> *)systemCommands;
- (NSArray<CItem *> *)appItemsFor:(NSString *)q;
- (CItem *)appItem:(CItem *)a score:(double)score;
- (CItem *)calcItem:(NSString *)q;
- (NSArray<CItem *> *)passwordItems:(NSString *)rest;
- (NSArray<CItem *> *)linkItemsFor:(NSString *)q;
- (NSArray<CItem *> *)runningAppItems:(NSString *)q force:(BOOL)force;
- (NSArray<CItem *> *)clipItems:(NSString *)q;
- (CItem *)webItem:(NSString *)q;
- (CItem *)urlItem:(NSString *)q;
- (void)stopFileSearch;
- (void)startFileSearch:(NSString *)q onlyFiles:(BOOL)only;
- (void)mergeFiles:(NSArray<CItem *> *)files onlyFiles:(BOOL)only;
- (void)refresh;
@end

@interface CApp (Home)
- (NSArray<CItem *> *)mostUsedApps;
- (NSArray<CItem *> *)quickActions;
- (NSArray<CItem *> *)recentCommands:(NSInteger)limit exclude:(NSSet *)skip;
- (void)startRecentFilesQuery;
- (void)buildHome;
- (void)syncHomeSelection;
- (void)homeSelect:(NSInteger)i;
- (void)homeMoveHorizontal:(NSInteger)d;
- (void)homeMoveVertical:(NSInteger)d;
@end

@interface CApp (UI)
- (void)buildUI;
- (void)layoutForRows:(NSInteger)rows;
- (void)hoverSelect:(NSInteger)i;
- (void)reloadTable;
- (void)positionPanel;
- (void)show;
- (void)hide;
- (void)toggle;
- (void)windowDidResignKey:(NSNotification *)n;
- (void)armItem:(CItem *)i;
- (void)disarm;
- (void)syncHomeSelectionIfNeeded;
- (void)runSelected:(BOOL)alt;
- (void)rowClicked:(id)s;
- (void)moveSelection:(NSInteger)d;
@end

@interface CApp (Media)
- (BOOL)ytmMode;
- (NSString *)ytmBrowser;
- (NSString *)ytmScript:(NSString *)js;
- (NSString *)ytmProblem:(NSString *)o;
- (void)refreshYTM;
- (void)ytmStart;
- (void)ytmPlayRecent;
- (void)ytmStartURL:(NSString *)startURL kick:(NSString *)kickJS label:(NSString *)label;
- (void)ytmWaitForPlayback:(NSInteger)attempt window:(NSString *)winId previous:(NSInteger)prev tab:(NSInteger)tab kick:(NSString *)kickJS;
- (void)ytmCommand:(int)cmd;
- (void)startMediaObservers;
- (void)refreshNowPlaying;
- (void)updateMediaView;
- (double)currentElapsed;
- (void)mediaSeek:(double)fraction;
- (void)mediaCommand:(int)cmd;
@end

@interface CApp (Tools)
- (NSArray<CItem *> *)defineItems:(NSString *)word;
- (NSArray<CItem *> *)timerItems:(NSString *)rest;
- (NSArray<CItem *> *)activeTimerItems;
- (void)startTimer:(NSTimeInterval)secs label:(NSString *)label;
- (NSArray<CItem *> *)volumeItems:(NSString *)rest;
- (void)toggleKeepAwake;
@end

@interface CApp (Snapshots)
- (void)snapshotView:(NSView *)v name:(NSString *)name radius:(CGFloat)radius;
- (void)readmeShots;
- (void)snapshotAll;
- (void)runSnapshots;
@end
