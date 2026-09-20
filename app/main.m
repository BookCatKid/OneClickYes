// GKOpenAnyway — installer/controller for the CoreServicesUIAgent injection.
// No root required: everything runs in the user's gui launchd domain.
#import <Cocoa/Cocoa.h>

static NSString *const kLabel    = @"local.gkopenanyway";
static NSString *const kAgentSvc = @"com.apple.coreservices.uiagent";

static NSString *supportDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/GKOpenAnyway"];
}
static NSString *dylibPath(void) {
    return [supportDir() stringByAppendingPathComponent:@"GKOpenAnyway.dylib"];
}
static NSString *agentPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/LaunchAgents/local.gkopenanyway.plist"];
}
static NSString *logPath(void) { return @"/tmp/gkopenanyway.log"; }
static NSString *primaryFlagPath(void) {
    return [supportDir() stringByAppendingPathComponent:@"primary"];
}

static NSString *run(NSString *launch, NSArray<NSString *> *args, int *status) {
    NSTask *t = [NSTask new];
    t.launchPath = launch;
    t.arguments = args ?: @[];
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardOutput = out; t.standardError = err;
    @try { [t launch]; } @catch (...) { if (status) *status = -1; return @""; }
    [t waitUntilExit];
    if (status) *status = (int)t.terminationStatus;
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

static NSString *uidStr(void) {
    return [NSString stringWithFormat:@"%u", getuid()];
}

static BOOL sipDisabled(void) {
    NSString *s = run(@"/usr/bin/csrutil", @[@"status"], nil);
    return [s containsString:@"disabled"] && ![s containsString:@"enabled"];
}

static NSString *dyldEnv(void) {
    NSString *s = run(@"/bin/launchctl", @[@"getenv", @"DYLD_INSERT_LIBRARIES"], nil);
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL envActive(void) { return [dyldEnv() isEqualToString:dylibPath()]; }

static pid_t agentPID(void) {
    NSString *s = run(@"/usr/bin/pgrep", @[@"-x", @"CoreServicesUIAgent"], nil);
    return (pid_t)s.intValue;
}

static BOOL agentLoaded(void) {
    pid_t pid = agentPID();
    if (!pid) return NO;
    NSString *s = run(@"/bin/ps", @[@"eww", @"-p", [@(pid) stringValue]], nil);
    return [s containsString:dylibPath()];
}

static void kickstartAgent(void) {
    run(@"/bin/launchctl",
        @[@"kickstart", @"-k",
          [NSString stringWithFormat:@"gui/%@/%@", uidStr(), kAgentSvc]], nil);
}

static void writeAgentPlist(void) {
    NSString *cmd = [NSString stringWithFormat:
        @"launchctl setenv DYLD_INSERT_LIBRARIES '%@'; "
        @"launchctl kickstart -k gui/`id -u`/%@", dylibPath(), kAgentSvc];
    NSString *plist = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\"><dict>\n"
        @"<key>Label</key><string>%@</string>\n"
        @"<key>ProgramArguments</key><array>\n"
        @"  <string>/bin/sh</string>\n"
        @"  <string>-c</string>\n"
        @"  <string>%@</string>\n"
        @"</array>\n"
        @"<key>RunAtLoad</key><true/>\n"
        @"</dict></plist>\n", kLabel, cmd];
    [plist writeToFile:agentPlistPath() atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
}

@interface GKDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSTextField *status;
@property (nonatomic) NSTextField *detail;
@property (nonatomic) NSTextField *testResult;
@property (nonatomic) NSButton *installBtn, *uninstallBtn, *primaryCb;
@property (nonatomic) BOOL testPending;
@property (nonatomic) NSDate *testStart;
@property (nonatomic) NSString *testMarker;
@end

@implementation GKDelegate

- (void)refresh {
    BOOL sip = sipDisabled();
    BOOL env = envActive();
    BOOL loaded = agentLoaded();
    BOOL plistInstalled = [[NSFileManager defaultManager] fileExistsAtPath:agentPlistPath()];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"SIP: %@\n", sip ? @"disabled (required)" : @"ENABLED — injection cannot work"];
    [s appendFormat:@"LaunchAgent (auto-apply at login): %@\n",
     plistInstalled ? @"installed" : @"not installed"];
    [s appendFormat:@"Injection environment: %@\n", env ? @"set" : @"not set"];
    [s appendFormat:@"CoreServicesUIAgent: %@\n",
     loaded ? @"running — hook active" :
     (agentPID() ? @"running — hook NOT loaded yet" : @"not running (loads on next Gatekeeper dialog)")];
    self.status.stringValue = s;

    NSDate *mtime = [[[NSFileManager defaultManager]
        attributesOfItemAtPath:logPath() error:nil] fileModificationDate];
    self.detail.stringValue = mtime
        ? [NSString stringWithFormat:@"Last hook activity: %@", mtime]
        : @"No hook activity logged yet.";

    // A test app proves success by writing its marker file from its own main().
    if (self.testPending) {
        if (self.testMarker &&
            [[NSFileManager defaultManager] fileExistsAtPath:self.testMarker]) {
            self.testPending = NO;
            self.testResult.stringValue = @"\u2713 Test app launched — the Open Anyway button works";
            self.testResult.textColor = [NSColor systemGreenColor];
        } else if (self.testStart && [[NSDate date] timeIntervalSinceDate:self.testStart] > 120) {
            self.testPending = NO;
            self.testResult.stringValue = @"Test timed out — the app was not approved. Try again.";
            self.testResult.textColor = [NSColor secondaryLabelColor];
        }
    }

    self.installBtn.enabled = sip && !env;
    self.uninstallBtn.enabled = plistInstalled || env;
}

- (void)install:(id)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:supportDir() withIntermediateDirectories:YES
                   attributes:nil error:nil];
    NSString *src = [[[NSBundle mainBundle] resourcePath]
        stringByAppendingPathComponent:@"GKOpenAnyway.dylib"];
    NSString *tmp = [supportDir()
        stringByAppendingPathComponent:@".GKOpenAnyway.dylib.tmp"];
    [fm removeItemAtPath:tmp error:nil];
    if (![fm copyItemAtPath:src toPath:tmp error:nil]) {
        self.detail.stringValue = @"Failed to copy dylib from app bundle.";
        return;
    }
    run(@"/usr/bin/codesign", @[@"-f", @"-s", @"-", tmp], nil);
    if (rename(tmp.fileSystemRepresentation,
               dylibPath().fileSystemRepresentation) != 0) {
        self.detail.stringValue = @"Failed to install dylib.";
        return;
    }

    writeAgentPlist();
    run(@"/bin/launchctl",
        @[@"bootstrap", [NSString stringWithFormat:@"gui/%@", uidStr()],
          agentPlistPath()], nil);

    run(@"/bin/launchctl", @[@"setenv", @"DYLD_INSERT_LIBRARIES", dylibPath()], nil);
    kickstartAgent();
    self.detail.stringValue = @"Installed. The hook loads the next time CoreServicesUIAgent spawns.";
    [self refresh];
}

- (void)uninstall:(id)sender {
    run(@"/bin/launchctl",
        @[@"bootout",
          [NSString stringWithFormat:@"gui/%@/%@", uidStr(), kLabel]], nil);
    [[NSFileManager defaultManager] removeItemAtPath:agentPlistPath() error:nil];
    run(@"/bin/launchctl", @[@"unsetenv", @"DYLD_INSERT_LIBRARIES"], nil);
    kickstartAgent();  // respawn agent without the dylib
    [[NSFileManager defaultManager] removeItemAtPath:supportDir() error:nil];
    self.detail.stringValue = @"Uninstalled. Nothing was left running or modified.";
    [self refresh];
}

- (void)togglePrimary:(NSButton *)cb {
    if (cb.state == NSControlStateValueOn) {
        [[NSFileManager defaultManager] createDirectoryAtPath:supportDir()
            withIntermediateDirectories:YES attributes:nil error:nil];
        [@"" writeToFile:primaryFlagPath() atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:primaryFlagPath() error:nil];
    }
}

- (void)testDialog:(id)sender {
    // Build a fresh unsigned quarantined app in the support dir and open it.
    NSString *src = [[[NSBundle mainBundle] resourcePath]
        stringByAppendingPathComponent:@"GKTest.app"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [fm contentsOfDirectoryAtPath:supportDir() error:nil])
        if ([f hasPrefix:@"GKTest-"])
            [fm removeItemAtPath:[supportDir() stringByAppendingPathComponent:f] error:nil];
    NSString *name = [NSString stringWithFormat:@"GKTest-%u.app", arc4random()];
    NSString *dst = [supportDir() stringByAppendingPathComponent:name];
    [fm removeItemAtPath:dst error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil]) {
        self.detail.stringValue = @"Test app missing from bundle.";
        return;
    }
    run(@"/usr/bin/xattr",
        @[@"-w", @"com.apple.quarantine",
          [NSString stringWithFormat:@"0083;%llx;GKTest;%@",
           (unsigned long long)time(NULL), [[NSUUID UUID] UUIDString]],
          dst], nil);
    NSString *base = [name stringByDeletingPathExtension];
    self.testMarker = [NSString stringWithFormat:@"/tmp/gktest_LAUNCHED_%@", base];
    [[NSFileManager defaultManager] removeItemAtPath:self.testMarker error:nil];
    self.testPending = YES;
    self.testStart = [NSDate date];
    self.testResult.stringValue = @"Waiting for the test app to launch — click “Open Anyway” in the dialog";
    self.testResult.textColor = [NSColor secondaryLabelColor];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dst]];
    self.detail.stringValue = @"Test app launched — look for the modified Gatekeeper dialog.";
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 400)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = @"GKOpenAnyway";
    NSView *v = w.contentView;

    NSTextField *title = [NSTextField labelWithString:@"Gatekeeper “Open Anyway” button"];
    title.font = [NSFont boldSystemFontOfSize:16];
    title.frame = NSMakeRect(20, 356, 480, 24);
    [v addSubview:title];

    NSTextField *info = [NSTextField wrappingLabelWithString:
        @"Adds an “Open Anyway” button to the “…could not verify…” Gatekeeper dialog. "
        @"The button uses Apple’s own approval path (Touch ID/password, per-app only). "
        @"Nothing stays running: the dylib is injected by launchd when the dialog "
        @"process spawns, and it ignores every other process on the system."];
    info.frame = NSMakeRect(20, 268, 480, 80);
    [v addSubview:info];

    self.status = [NSTextField wrappingLabelWithString:@""];
    self.status.frame = NSMakeRect(20, 158, 480, 100);
    [v addSubview:self.status];

    self.detail = [NSTextField wrappingLabelWithString:@""];
    self.detail.font = [NSFont systemFontOfSize:11];
    self.detail.textColor = [NSColor secondaryLabelColor];
    self.detail.frame = NSMakeRect(20, 124, 480, 30);
    [v addSubview:self.detail];

    self.installBtn = [NSButton buttonWithTitle:@"Install & Enable"
                                       target:self action:@selector(install:)];
    self.installBtn.frame = NSMakeRect(20, 78, 140, 32);
    self.installBtn.bezelStyle = NSBezelStyleRounded;
    [v addSubview:self.installBtn];

    self.uninstallBtn = [NSButton buttonWithTitle:@"Uninstall"
                                         target:self action:@selector(uninstall:)];
    self.uninstallBtn.frame = NSMakeRect(170, 78, 120, 32);
    self.uninstallBtn.bezelStyle = NSBezelStyleRounded;
    [v addSubview:self.uninstallBtn];

    NSButton *test = [NSButton buttonWithTitle:@"Test the dialog"
                                      target:self action:@selector(testDialog:)];
    test.frame = NSMakeRect(300, 78, 130, 32);
    test.bezelStyle = NSBezelStyleRounded;
    [v addSubview:test];

    self.testResult = [NSTextField wrappingLabelWithString:@""];
    self.testResult.frame = NSMakeRect(20, 54, 480, 20);
    [v addSubview:self.testResult];

    self.primaryCb = [NSButton checkboxWithTitle:
        @"Make “Open Anyway” the default button (accent color, Return key)"
                                          target:self action:@selector(togglePrimary:)];
    self.primaryCb.frame = NSMakeRect(20, 30, 480, 22);
    self.primaryCb.state = [[NSFileManager defaultManager]
        fileExistsAtPath:primaryFlagPath()] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.primaryCb];

    [w center];
    [w makeKeyAndOrderFront:nil];
    [self refresh];
    [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
                                   selector:@selector(refresh) userInfo:nil repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

static GKDelegate *gDelegate;
int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        gDelegate = [GKDelegate new];
        app.delegate = gDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
