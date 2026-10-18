// Centre — a lightweight native launcher for macOS. Builds with Command Line Tools only (./centre).
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <CoreServices/CoreServices.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

#pragma mark - Model

typedef void (^CAction)(void);

@interface CItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *kind;      // right-hand label
@property (nonatomic, copy) NSString *path;      // for icon lookup / frecency key
@property (nonatomic, copy) NSString *symbol;    // SF symbol name for non-file items
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic) double score;
@property (nonatomic, copy) CAction action;      // Enter
@property (nonatomic, copy) CAction altAction;   // Cmd+Enter
@property (nonatomic, copy) NSString *altHint;
@property (nonatomic, copy) NSString *detail;    // right-hand text that replaces kind (e.g. "2h ago")
@property (nonatomic, copy) NSString *key;       // usage key, so the item can show up under Recent Commands
@property (nonatomic, copy) NSString *confirm;   // set for irreversible commands: first ↩ arms, second ↩ runs
@property (nonatomic, copy) NSString *keywords;  // other words people type for this command ("empty" for Clear Clipboard)
@property (nonatomic, copy) NSString *verb;      // footer label for ↩ when the kind's default doesn't fit ("Cancel Timer")
@end

CItem *mk(NSString *title, NSString *sub, NSString *kind, NSString *symbol, CAction action);

#pragma mark - Layout constants

static const CGFloat kRadius = 16;                                   // panel corner radius
static const CGFloat kW = 720, kSearchH = 62, kRowH = 44, kGridH = 124, kFooterH = 40;
static const CGFloat kCellW = 84, kCellH = 84, kGridX = 24, kQuickH = 46, kHomeRowH = 34, kHomeHeadH = 26;
static const CGFloat kMediaH = 92;
static const NSInteger kMaxRows = 9;

#pragma mark - Helpers (Util.m)

NSString *supportDir(void);
void runShell(NSString *cmd, void (^done)(NSString *out));       // Centre's own commands: /bin/sh, predictable
void runUserShell(NSString *cmd, void (^done)(NSString *out));   // commands you type after ">": your login shell, PATH and aliases
void runOsa(NSString *script, void (^done)(NSString *out));
void osa(NSString *script);
NSString *pwPick(NSString *pool);
NSString *genPassword(NSUInteger len, BOOL symbols);
double pwBits(NSUInteger len, BOOL symbols);
NSString *genPassphrase(NSUInteger nWords);
NSUInteger pwWordCount(void);
NSString *genPIN(NSUInteger len);
void copySecret(NSString *s);
void copyText(NSString *s);
void openURLString(NSString *s);
NSString *urlEncode(NSString *s);
double fuzzyScore(NSString *query, NSString *target);
NSImage *symbolImage(NSString *name);
NSImage *prerenderIcon(NSImage *src);
NSDictionary<NSString *, NSNumber *> *hotkeyKeyMap(void);
NSString *prettyHotkey(NSString *spec);
void moveFrontWindow(NSRunningApplication *app, NSString *mode);
void simulatePaste(void);
NSImage *symSize(NSString *name, CGFloat pt);
NSString *fmtTime(double sec);
NSString *shortAgo(NSTimeInterval t);
NSString *defaultBrowserName(void);
NSString *formatNumber(double v);
BOOL evaluateMath(NSString *q, double *out);
NSString *convertUnits(NSString *q, double *out);
NSTimeInterval parseDuration(NSString *s);

#pragma mark - Theme and HUD (Theme.m)

NSColor *cAccent(void);
BOOL cIsDark(NSView *v);
NSColor *cSelFill(NSView *v);
NSColor *cSelEdge(NSView *v);
NSColor *rgb(CGFloat r, CGFloat g, CGFloat b);
NSArray<NSColor *> *tileColors(NSString *kind);
NSImage *tileImage(NSString *symbol, NSString *kind);
NSPanel *prepareHUD(NSString *text, NSString *symbol);
void showHUD(NSString *text, NSString *symbol);
void showHUDFor(NSString *text, NSString *symbol, NSTimeInterval seconds);

#pragma mark - Self-test (SelfTest.m)

int runSelfTests(void);   // returns the number of failed checks (0 = pass)
