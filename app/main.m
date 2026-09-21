// OneClickYes — installer/controller for the dialog injection.
// Adds "Open Anyway" to Gatekeeper's blocked-app dialog and "Allow" to the
// TCC permission warnings (Accessibility, Input Monitoring, Screen
// Recording). No root required: everything runs in the user's gui launchd
// domain.
#import <Cocoa/Cocoa.h>

static NSString *const kLabel    = @"local.oneclickyes";
static NSString *const kAgentSvc = @"com.apple.coreservices.uiagent";
static NSString *const kWarnSvc  = @"universalAccessAuthWarn";

// Legacy (GKOpenAnyway) paths, for one-time migration.
static NSString *const kOldLabel = @"local.gkopenanyway";

static NSString *supportDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/OneClickYes"];
}
static NSString *oldSupportDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/GKOpenAnyway"];
}
static NSString *dylibPath(void) {
    return [supportDir() stringByAppendingPathComponent:@"OneClickYes.dylib"];
}
static NSString *oldDylibPath(void) {
    return [oldSupportDir() stringByAppendingPathComponent:@"GKOpenAnyway.dylib"];
}
static NSString *agentPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/LaunchAgents/local.oneclickyes.plist"];
}
static NSString *oldAgentPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/LaunchAgents/local.gkopenanyway.plist"];
}
static NSString *logPath(void) { return @"/tmp/oneclickyes.log"; }
static NSString *primaryFlagPath(void) {
    return [supportDir() stringByAppendingPathComponent:@"primary"];
}

static NSString *run(NSString *launch, NSArray<NSString *> *args, int *status) {
    NSTask *t = [NSTask new];
    t.launchPath = launch;
    t.arguments = args ?: @[];
    // Never propagate DYLD_INSERT_LIBRARIES to children: if the configured
    // path is ever missing the child aborts in dyld before it can run.
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    t.environment = env;
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

static pid_t procPID(NSString *name) {
    NSString *s = run(@"/usr/bin/pgrep", @[@"-x", name], nil);
    return (pid_t)s.intValue;
}

static BOOL procLoaded(pid_t pid) {
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

// One-time migration from a GKOpenAnyway install to OneClickYes paths.
static void migrateLegacyInstall(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL migrated = NO;
    if ([fm fileExistsAtPath:oldSupportDir()]) {
        if (![fm fileExistsAtPath:supportDir()])
            [fm moveItemAtPath:oldSupportDir() toPath:supportDir() error:nil];
        // After the dir move the payload sits at its old name in the new dir.
        NSString *moved = [supportDir() stringByAppendingPathComponent:
                           @"GKOpenAnyway.dylib"];
        if ([fm fileExistsAtPath:moved])
            [fm moveItemAtPath:moved toPath:dylibPath() error:nil];
        else if ([fm fileExistsAtPath:oldDylibPath()])
            [fm moveItemAtPath:oldDylibPath() toPath:dylibPath() error:nil];
        [fm removeItemAtPath:oldSupportDir() error:nil];
        migrated = YES;
    }
    if ([fm fileExistsAtPath:oldAgentPlistPath()]) {
        run(@"/bin/launchctl",
            @[@"bootout",
              [NSString stringWithFormat:@"gui/%@/%@", uidStr(), kOldLabel]], nil);
        [fm removeItemAtPath:oldAgentPlistPath() error:nil];
        migrated = YES;
    }
    if ([dyldEnv() isEqualToString:oldDylibPath()]) {
        run(@"/bin/launchctl", @[@"setenv", @"DYLD_INSERT_LIBRARIES",
                                 dylibPath()], nil);
        migrated = YES;
    }
    if (migrated &&
        [fm fileExistsAtPath:agentPlistPath()]) {
        // Re-register the agent under the new label.
        run(@"/bin/launchctl",
            @[@"bootstrap", [NSString stringWithFormat:@"gui/%@", uidStr()],
              agentPlistPath()], nil);
    }
}

@interface GKDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSTextField *status;
@property (nonatomic) NSTextField *detail;
@property (nonatomic) NSTextField *testResult;
@property (nonatomic) NSButton *installBtn, *uninstallBtn, *primaryCb;
@property (nonatomic) BOOL testPending;
@property (nonatomic) NSDate *testStart;
@property (nonatomic) NSString *testMarker;
@property (nonatomic) NSString *testSuccessText;
@end

@implementation GKDelegate

- (void)refresh {
    BOOL sip = sipDisabled();
    BOOL env = envActive();
    BOOL plistInstalled = [[NSFileManager defaultManager] fileExistsAtPath:agentPlistPath()];
    pid_t agent = procPID(@"CoreServicesUIAgent");
    pid_t warn = procPID(kWarnSvc);

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"SIP: %@\n", sip ? @"disabled (required)" : @"ENABLED — injection cannot work"];
    [s appendFormat:@"LaunchAgent (auto-apply at login): %@\n",
     plistInstalled ? @"installed" : @"not installed"];
    [s appendFormat:@"Injection environment: %@\n", env ? @"set" : @"not set"];
    [s appendFormat:@"CoreServicesUIAgent (Gatekeeper): %@\n",
     procLoaded(agent) ? @"running — hook active" :
     (agent ? @"running — hook NOT loaded yet" : @"loads on next Gatekeeper dialog")];
    [s appendFormat:@"universalAccessAuthWarn (permissions): %@\n",
     procLoaded(warn) ? @"running — hook active" : @"loads on next permission dialog"];
    self.status.stringValue = s;

    NSDate *mtime = [[[NSFileManager defaultManager]
        attributesOfItemAtPath:logPath() error:nil] fileModificationDate];
    self.detail.stringValue = mtime
        ? [NSString stringWithFormat:@"Last hook activity: %@", mtime]
        : @"No hook activity logged yet.";

    // A test app proves success by writing its marker file from its own code.
    if (self.testPending) {
        if (self.testMarker &&
            [[NSFileManager defaultManager] fileExistsAtPath:self.testMarker]) {
            self.testPending = NO;
            self.testResult.stringValue = self.testSuccessText;
            self.testResult.textColor = [NSColor systemGreenColor];
        } else if (self.testStart && [[NSDate date] timeIntervalSinceDate:self.testStart] > 130) {
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
        stringByAppendingPathComponent:@"OneClickYes.dylib"];
    NSString *tmp = [supportDir()
        stringByAppendingPathComponent:@".OneClickYes.dylib.tmp"];
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
    self.detail.stringValue = @"Installed. Hooks load when each dialog process spawns.";
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

// Copy a bundled test app to a fresh random name in the support dir so each
// test has a unique quarantine/TCC identity, then open it.
- (NSString *)stageTestApp:(NSString *)bundleName markerPrefix:(NSString *)prefix
                 pending:(NSString *)pendingText {
    NSString *src = [[[NSBundle mainBundle] resourcePath]
        stringByAppendingPathComponent:bundleName];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stem = [bundleName stringByDeletingPathExtension];
    for (NSString *f in [fm contentsOfDirectoryAtPath:supportDir() error:nil])
        if ([f hasPrefix:[stem stringByAppendingString:@"-"]])
            [fm removeItemAtPath:[supportDir() stringByAppendingPathComponent:f] error:nil];
    NSString *name = [NSString stringWithFormat:@"%@-%u.app", stem, arc4random()];
    NSString *dst = [supportDir() stringByAppendingPathComponent:name];
    [fm removeItemAtPath:dst error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:nil]) {
        self.detail.stringValue = @"Test app missing from bundle.";
        return nil;
    }
    NSString *base = [name stringByDeletingPathExtension];
    self.testMarker = [NSString stringWithFormat:@"/tmp/%@_%@", prefix, base];
    [fm removeItemAtPath:self.testMarker error:nil];
    self.testPending = YES;
    self.testStart = [NSDate date];
    self.testResult.stringValue = pendingText;
    self.testResult.textColor = [NSColor secondaryLabelColor];
    return dst;
}

- (void)testDialog:(id)sender {
    NSString *dst = [self stageTestApp:@"OCYTest.app" markerPrefix:@"ocytest_LAUNCHED"
        pending:@"Waiting for the test app to launch — click “Open Anyway” in the dialog"];
    if (!dst) return;
    self.testSuccessText = @"\u2713 Test app launched — the Open Anyway button works";
    // Unsigned + quarantined -> the "could not verify" dialog.
    run(@"/usr/bin/xattr",
        @[@"-w", @"com.apple.quarantine",
          [NSString stringWithFormat:@"0083;%llx;OCYTest;%@",
           (unsigned long long)time(NULL), [[NSUUID UUID] UUIDString]],
          dst], nil);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dst]];
    self.detail.stringValue = @"Test app launched — look for the modified Gatekeeper dialog.";
}

- (void)testPermission:(id)sender {
    NSString *dst = [self stageTestApp:@"OCYProbe.app" markerPrefix:@"ocyprobe_GRANTED"
        pending:@"Waiting for the permission dialog — click “Allow”"];
    if (!dst) return;
    self.testSuccessText = @"\u2713 App granted Accessibility — the Allow button works";
    // Fresh bundle id per copy so it always prompts, then re-sign adhoc.
    NSString *plist = [dst stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSMutableDictionary *info = [NSMutableDictionary
        dictionaryWithContentsOfFile:plist];
    NSString *base = [[dst lastPathComponent] stringByDeletingPathExtension];
    info[@"CFBundleIdentifier"] =
        [NSString stringWithFormat:@"local.oneclickyes.probe.%u", arc4random()];
    info[@"CFBundleName"] = base;
    [info writeToFile:plist atomically:YES];
    run(@"/usr/bin/codesign", @[@"-f", @"-s", @"-", dst], nil);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dst]];
    self.detail.stringValue = @"Probe launched — look for the permission dialog with Allow.";
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    migrateLegacyInstall();
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 540, 450)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = @"OneClickYes";
    NSView *v = w.contentView;

    NSTextField *title = [NSTextField labelWithString:@"One-click approvals for macOS prompts"];
    title.font = [NSFont boldSystemFontOfSize:16];
    title.frame = NSMakeRect(20, 406, 500, 24);
    [v addSubview:title];

    NSTextField *info = [NSTextField wrappingLabelWithString:
        @"Adds “Open Anyway” to the “…could not verify…” Gatekeeper dialog and "
        @"“Allow” to permission warnings (Accessibility, Input Monitoring, "
        @"Screen Recording). Both use Apple’s own approval paths — per-app, "
        @"one explicit click. Nothing stays running: the dylib is injected "
        @"by launchd when each dialog process spawns, and ignores every "
        @"other process on the system."];
    info.frame = NSMakeRect(20, 298, 500, 100);
    [v addSubview:info];

    self.status = [NSTextField wrappingLabelWithString:@""];
    self.status.frame = NSMakeRect(20, 172, 500, 120);
    [v addSubview:self.status];

    self.detail = [NSTextField wrappingLabelWithString:@""];
    self.detail.font = [NSFont systemFontOfSize:11];
    self.detail.textColor = [NSColor secondaryLabelColor];
    self.detail.frame = NSMakeRect(20, 138, 500, 30);
    [v addSubview:self.detail];

    self.installBtn = [NSButton buttonWithTitle:@"Install & Enable"
                                       target:self action:@selector(install:)];
    self.installBtn.frame = NSMakeRect(20, 92, 140, 32);
    self.installBtn.bezelStyle = NSBezelStyleRounded;
    [v addSubview:self.installBtn];

    self.uninstallBtn = [NSButton buttonWithTitle:@"Uninstall"
                                         target:self action:@selector(uninstall:)];
    self.uninstallBtn.frame = NSMakeRect(170, 92, 110, 32);
    self.uninstallBtn.bezelStyle = NSBezelStyleRounded;
    [v addSubview:self.uninstallBtn];

    NSButton *testGK = [NSButton buttonWithTitle:@"Test Gatekeeper"
                                        target:self action:@selector(testDialog:)];
    testGK.frame = NSMakeRect(285, 92, 115, 32);
    testGK.bezelStyle = NSBezelStyleRounded;
    [v addSubview:testGK];

    NSButton *testTCC = [NSButton buttonWithTitle:@"Test Permission"
                                         target:self action:@selector(testPermission:)];
    testTCC.frame = NSMakeRect(405, 92, 115, 32);
    testTCC.bezelStyle = NSBezelStyleRounded;
    [v addSubview:testTCC];

    self.testResult = [NSTextField wrappingLabelWithString:@""];
    self.testResult.frame = NSMakeRect(20, 68, 500, 20);
    [v addSubview:self.testResult];

    self.primaryCb = [NSButton checkboxWithTitle:
        @"Make “Open Anyway” the default button (accent color, Return key)"
                                          target:self action:@selector(togglePrimary:)];
    self.primaryCb.frame = NSMakeRect(20, 30, 500, 22);
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
