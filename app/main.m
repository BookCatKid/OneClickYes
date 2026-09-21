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
static NSString *flagPath(NSString *name) {
    return [supportDir() stringByAppendingPathComponent:name];
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
@property (nonatomic) NSTextField *globalStatus;
@property (nonatomic) NSTextField *message;
@property (nonatomic) NSSegmentedControl *seg;
@property (nonatomic) NSView *gkPane, *tccPane;
@property (nonatomic) NSTextField *gkStatus, *tccStatus;
@property (nonatomic) NSTextField *gkResult, *tccResult;
@property (nonatomic) NSButton *installBtn, *uninstallBtn, *primaryCb;
@property (nonatomic) NSButton *enableGk, *enableTcc;
@property (nonatomic) BOOL gkPending, tccPending;
@property (nonatomic) NSDate *gkStart, *tccStart;
@property (nonatomic) NSString *gkMarker, *tccMarker;
@end

@implementation GKDelegate

// One status row: tinted SF Symbol + text. attrs may override font/color
// for the text part (e.g. smaller secondary "Last:" lines).
static NSAttributedString *statusLine(NSString *icon, NSColor *color,
                                      NSString *text, NSDictionary *attrs) {
    NSImage *img = [NSImage imageWithSystemSymbolName:icon
                               accessibilityDescription:nil];
    img = [img imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    NSTextAttachment *a = [NSTextAttachment new];
    a.image = img;
    NSMutableAttributedString *s =
        [[NSAttributedString attributedStringWithAttachment:a] mutableCopy];
    [s appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"  %@", text]
            attributes:attrs]];
    return s;
}

static NSMutableAttributedString *joinLines(NSArray<NSAttributedString *> *ls) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = 6;
    BOOL first = YES;
    for (NSAttributedString *l in ls) {
        if (!first)
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [out appendAttributedString:l];
        first = NO;
    }
    [out addAttribute:NSParagraphStyleAttributeName value:p
                range:NSMakeRange(0, out.length)];
    return out;
}

static NSDictionary *subTextAttrs(void) {
    return @{NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
             NSFontAttributeName: [NSFont systemFontOfSize:11]};
}

// Keep "Last:" entries to a single line so the status block height is stable.
static NSString *oneLine(NSString *s) {
    if (s.length > 72) s = [[s substringToIndex:69] stringByAppendingString:@"…"];
    return s;
}

// Explicitly non-interactive label — macOS 27 text fields are selectable
// by default, which lets a click put them in an editing-looking state and
// strip the attributed-string icons.
static NSTextField *label(NSString *s) {
    NSTextField *t = [NSTextField wrappingLabelWithString:s];
    t.editable = NO;
    t.selectable = NO;
    return t;
}

// Vertically center a label's text within a region. The frame gets the
// cell's fitted height (accurate now that joinLines drops the trailing
// newline) minus the cell's internal bottom inset, so the top-aligned
// text block itself lands centered — and stays a few pts taller than
// the glyphs so nothing clips.
static void centerLabel(NSTextField *t, CGFloat x, CGFloat w,
                        CGFloat y, CGFloat h) {
    CGFloat fh = [t.cell cellSizeForBounds:NSMakeRect(0, 0, w, 200)].height;
    t.frame = NSMakeRect(x, y + (h - fh) / 2 - 2, w, fh);
}

static NSBox *card(NSRect f) {
    NSBox *b = [[NSBox alloc] initWithFrame:f];
    b.boxType = NSBoxCustom;
    b.cornerRadius = 10;
    b.borderWidth = 0;
    b.fillColor = [NSColor colorWithWhite:0.5 alpha:0.12];
    return b;
}

static NSArray<NSString *> *logLines(void) {
    NSString *s = [NSString stringWithContentsOfFile:logPath()
                    encoding:NSUTF8StringEncoding error:nil];
    return [s componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];
}

static NSUInteger countMatching(NSArray<NSString *> *lines, NSString *needle) {
    NSUInteger n = 0;
    for (NSString *l in lines) if ([l containsString:needle]) n++;
    return n;
}

- (void)refresh {
    BOOL sip = sipDisabled();
    BOOL env = envActive();
    BOOL plistInstalled = [[NSFileManager defaultManager] fileExistsAtPath:agentPlistPath()];

    NSColor *green = [NSColor systemGreenColor];
    NSColor *red = [NSColor systemRedColor];
    NSColor *yellow = [NSColor systemOrangeColor];
    NSColor *gray = [NSColor secondaryLabelColor];

    self.globalStatus.attributedStringValue = joinLines(@[
        statusLine(sip ? @"checkmark.shield.fill" : @"xmark.octagon.fill",
                   sip ? green : red,
                   sip ? @"SIP disabled (required)" : @"SIP ENABLED — injection cannot work", nil),
        statusLine(plistInstalled ? @"checkmark.circle.fill" : @"minus.circle",
                   plistInstalled ? green : gray,
                   [NSString stringWithFormat:@"LaunchAgent (auto-apply at login): %@",
                    plistInstalled ? @"installed" : @"not installed"], nil),
        statusLine(env ? @"checkmark.circle.fill" : @"exclamationmark.triangle.fill",
                   env ? green : yellow,
                   [NSString stringWithFormat:@"Injection environment: %@",
                    env ? @"set" : @"not set"], nil),
    ]);
    centerLabel(self.globalStatus, 14, 472, 0, 88);

    NSArray<NSString *> *lines = logLines();

    // --- Gatekeeper pane stats ---
    pid_t agent = procPID(@"CoreServicesUIAgent");
    NSUInteger added = countMatching(lines, @"added Open Anyway button");
    NSString *gkLast = nil;
    for (NSString *l in lines.reverseObjectEnumerator)
        if ([l containsString:@"alert="] || [l containsString:@"Open Anyway"]) { gkLast = l; break; }
    NSMutableArray *gk = [NSMutableArray array];
    BOOL gkLoaded = procLoaded(agent);
    BOOL gkOff = [[NSFileManager defaultManager]
        fileExistsAtPath:flagPath(@"disabled.gk")];
    [gk addObject:statusLine(
        gkOff ? @"minus.circle" :
            (gkLoaded ? @"checkmark.circle.fill" :
             (agent ? @"exclamationmark.circle.fill" : @"clock")),
        gkOff ? gray : (gkLoaded ? green : (agent ? yellow : gray)),
        gkOff ? @"CoreServicesUIAgent: hook disabled" :
        [NSString stringWithFormat:@"CoreServicesUIAgent: %@",
         gkLoaded ? @"running — hook active" :
         (agent ? @"running — hook NOT loaded yet" : @"loads on next Gatekeeper dialog")], nil)];
    [gk addObject:statusLine(@"chart.bar.fill", gray,
        [NSString stringWithFormat:@"“Open Anyway” added to %lu dialog%@",
         (unsigned long)added, added == 1 ? @"" : @"s"], nil)];
    if (gkLast)
        [gk addObject:statusLine(@"clock", gray,
            [NSString stringWithFormat:@"Last: %@", oneLine(gkLast)], subTextAttrs())];
    self.gkStatus.attributedStringValue = joinLines(gk);
    centerLabel(self.gkStatus, 14, 472, 106, 66);

    // --- Permissions pane stats ---
    pid_t warn = procPID(kWarnSvc);
    NSUInteger tccAdded = countMatching(lines, @"added Allow button");
    NSUInteger granted = countMatching(lines, @"granted verified");
    NSString *tccLast = nil;
    for (NSString *l in lines.reverseObjectEnumerator)
        if ([l containsString:@"allow:"] || [l containsString:@"Allow button"]) { tccLast = l; break; }
    NSMutableArray *tc = [NSMutableArray array];
    BOOL tccLoaded = procLoaded(warn);
    BOOL tccOff = [[NSFileManager defaultManager]
        fileExistsAtPath:flagPath(@"disabled.tcc")];
    [tc addObject:statusLine(
        tccOff ? @"minus.circle" : (tccLoaded ? @"checkmark.circle.fill" : @"clock"),
        tccOff ? gray : (tccLoaded ? green : gray),
        tccOff ? @"universalAccessAuthWarn: hook disabled" :
        [NSString stringWithFormat:@"universalAccessAuthWarn: %@",
         tccLoaded ? @"running — hook active" : @"loads on next permission dialog"], nil)];
    [tc addObject:statusLine(@"chart.bar.fill", gray,
        [NSString stringWithFormat:@"“Allow” added to %lu dialog%@ — %lu grant%@ verified",
         (unsigned long)tccAdded, tccAdded == 1 ? @"" : @"s",
         (unsigned long)granted, granted == 1 ? @"" : @"s"], nil)];
    if (tccLast)
        [tc addObject:statusLine(@"clock", gray,
            [NSString stringWithFormat:@"Last: %@", oneLine(tccLast)], subTextAttrs())];
    self.tccStatus.attributedStringValue = joinLines(tc);
    centerLabel(self.tccStatus, 14, 472, 112, 60);

    // A test app proves success by writing its marker file from its own code.
    [self pollPending:&_gkPending marker:self.gkMarker start:self.gkStart
               result:self.gkResult
              success:@"\u2713 Test app launched — the Open Anyway button works"];
    [self pollPending:&_tccPending marker:self.tccMarker start:self.tccStart
               result:self.tccResult
              success:@"\u2713 App granted Accessibility — the Allow button works"];

    self.installBtn.enabled = sip && !env;
    self.uninstallBtn.enabled = plistInstalled || env;
}

- (void)pollPending:(BOOL *)pending marker:(NSString *)marker start:(NSDate *)start
             result:(NSTextField *)result success:(NSString *)success {
    if (!*pending) return;
    if (marker && [[NSFileManager defaultManager] fileExistsAtPath:marker]) {
        *pending = NO;
        result.stringValue = success;
        result.textColor = [NSColor systemGreenColor];
    } else if (start && [[NSDate date] timeIntervalSinceDate:start] > 130) {
        *pending = NO;
        result.stringValue = @"Test timed out — the app was not approved. Try again.";
        result.textColor = [NSColor secondaryLabelColor];
    }
}

- (void)modeChanged:(NSSegmentedControl *)seg {
    BOOL gk = seg.selectedSegment == 0;
    self.gkPane.hidden = !gk;
    self.tccPane.hidden = gk;
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
        self.message.stringValue = @"Failed to copy dylib from app bundle.";
        return;
    }
    run(@"/usr/bin/codesign", @[@"-f", @"-s", @"-", tmp], nil);
    if (rename(tmp.fileSystemRepresentation,
               dylibPath().fileSystemRepresentation) != 0) {
        self.message.stringValue = @"Failed to install dylib.";
        return;
    }

    writeAgentPlist();
    run(@"/bin/launchctl",
        @[@"bootstrap", [NSString stringWithFormat:@"gui/%@", uidStr()],
          agentPlistPath()], nil);

    run(@"/bin/launchctl", @[@"setenv", @"DYLD_INSERT_LIBRARIES", dylibPath()], nil);
    kickstartAgent();
    self.message.stringValue = @"Installed. Hooks load when each dialog process spawns.";
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
    self.message.stringValue = @"Uninstalled. Nothing was left running or modified.";
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

// Per-mode enable: presence of disabled.<mode> makes the dylib skip that
// hook. Applies when the dialog process next spawns.
- (void)toggleEnable:(NSButton *)cb {
    NSString *f = flagPath(cb == self.enableGk ? @"disabled.gk" : @"disabled.tcc");
    NSFileManager *fm = [NSFileManager defaultManager];
    if (cb.state == NSControlStateValueOn) {
        [fm removeItemAtPath:f error:nil];
    } else {
        [fm createDirectoryAtPath:supportDir()
            withIntermediateDirectories:YES attributes:nil error:nil];
        [@"" writeToFile:f atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    }
    kickstartAgent();   // respawn the uiagent so the flag takes effect now
    self.message.stringValue = cb.state == NSControlStateValueOn
        ? @"Hook enabled — applies when the dialog process next spawns."
        : @"Hook disabled — applies when the dialog process next spawns.";
    [self refresh];
}

// Copy a bundled test app to a fresh random name in the support dir so each
// test has a unique quarantine/TCC identity, then open it.
- (NSString *)stageTestApp:(NSString *)bundleName {
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
        self.message.stringValue = @"Test app missing from bundle.";
        return nil;
    }
    return dst;
}

- (void)testDialog:(id)sender {
    NSString *dst = [self stageTestApp:@"OCYTest.app"];
    if (!dst) return;
    NSString *base = [[dst lastPathComponent] stringByDeletingPathExtension];
    self.gkMarker = [NSString stringWithFormat:@"/tmp/ocytest_LAUNCHED_%@", base];
    [[NSFileManager defaultManager] removeItemAtPath:self.gkMarker error:nil];
    self.gkPending = YES;
    self.gkStart = [NSDate date];
    self.gkResult.stringValue = @"Waiting for the test app to launch — click “Open Anyway” in the dialog";
    self.gkResult.textColor = [NSColor secondaryLabelColor];
    // Unsigned + quarantined -> the "could not verify" dialog.
    run(@"/usr/bin/xattr",
        @[@"-w", @"com.apple.quarantine",
          [NSString stringWithFormat:@"0083;%llx;OCYTest;%@",
           (unsigned long long)time(NULL), [[NSUUID UUID] UUIDString]],
          dst], nil);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dst]];
    self.message.stringValue = @"Test app launched — look for the modified Gatekeeper dialog.";
}

- (void)testPermission:(id)sender {
    NSString *dst = [self stageTestApp:@"OCYProbe.app"];
    if (!dst) return;
    NSString *base = [[dst lastPathComponent] stringByDeletingPathExtension];
    self.tccMarker = [NSString stringWithFormat:@"/tmp/ocyprobe_GRANTED_%@", base];
    [[NSFileManager defaultManager] removeItemAtPath:self.tccMarker error:nil];
    self.tccPending = YES;
    self.tccStart = [NSDate date];
    self.tccResult.stringValue = @"Waiting for the permission dialog — click “Allow”";
    self.tccResult.textColor = [NSColor secondaryLabelColor];
    // Fresh bundle id per copy so it always prompts, then re-sign adhoc.
    NSString *plist = [dst stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSMutableDictionary *info = [NSMutableDictionary
        dictionaryWithContentsOfFile:plist];
    info[@"CFBundleIdentifier"] =
        [NSString stringWithFormat:@"local.oneclickyes.probe.%u", arc4random()];
    info[@"CFBundleName"] = base;
    [info writeToFile:plist atomically:YES];
    run(@"/usr/bin/codesign", @[@"-f", @"-s", @"-", dst], nil);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dst]];
    self.message.stringValue = @"Probe launched — look for the permission dialog with Allow.";
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    migrateLegacyInstall();
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 540, 500)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = @"OneClickYes";
    NSView *v = w.contentView;

    NSTextField *title = [NSTextField labelWithString:@"One-click approvals for macOS prompts"];
    title.font = [NSFont boldSystemFontOfSize:16];
    title.frame = NSMakeRect(20, 456, 500, 24);
    [v addSubview:title];

    NSTextField *info = label(
        @"Both buttons use Apple’s own approval paths — per-app, one explicit "
        @"click. Nothing stays running: the dylib is injected by launchd when "
        @"each dialog process spawns, and ignores every other process on the "
        @"system.");
    info.font = [NSFont systemFontOfSize:12];
    info.textColor = [NSColor secondaryLabelColor];
    info.frame = NSMakeRect(20, 400, 500, 52);
    [v addSubview:info];

    NSBox *globalCard = card(NSMakeRect(20, 304, 500, 88));
    self.globalStatus = label(@"");
    self.globalStatus.frame = NSMakeRect(14, 10, 472, 68);
    [globalCard addSubview:self.globalStatus];
    [v addSubview:globalCard];

    self.seg = [NSSegmentedControl segmentedControlWithLabels:
        @[@"Gatekeeper “Open Anyway”", @"Permission “Allow”"]
                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                      target:self
                                                      action:@selector(modeChanged:)];
    self.seg.frame = NSMakeRect(20, 262, 340, 26);
    self.seg.selectedSegment = 0;
    [v addSubview:self.seg];

    // ---- Gatekeeper pane ----
    self.gkPane = card(NSMakeRect(20, 70, 500, 186));
    self.gkStatus = label(@"");
    self.gkStatus.frame = NSMakeRect(14, 108, 472, 64);
    [self.gkPane addSubview:self.gkStatus];

    self.enableGk = [NSButton checkboxWithTitle:@"Enable “Open Anyway” button"
                                         target:self action:@selector(toggleEnable:)];
    self.enableGk.frame = NSMakeRect(14, 78, 472, 22);
    self.enableGk.state = ![[NSFileManager defaultManager]
        fileExistsAtPath:flagPath(@"disabled.gk")];
    [self.gkPane addSubview:self.enableGk];

    self.primaryCb = [NSButton checkboxWithTitle:
        @"Make “Open Anyway” the default button (accent color, Return key)"
                                          target:self action:@selector(togglePrimary:)];
    self.primaryCb.frame = NSMakeRect(14, 54, 472, 22);
    self.primaryCb.state = [[NSFileManager defaultManager]
        fileExistsAtPath:primaryFlagPath()] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.gkPane addSubview:self.primaryCb];

    NSButton *testGK = [NSButton buttonWithTitle:@"Test Gatekeeper"
                                        target:self action:@selector(testDialog:)];
    testGK.frame = NSMakeRect(14, 16, 130, 28);
    testGK.bezelStyle = NSBezelStyleRounded;
    testGK.image = [NSImage imageWithSystemSymbolName:@"play.circle"
                               accessibilityDescription:nil];
    testGK.imagePosition = NSImageLeft;
    [self.gkPane addSubview:testGK];

    self.gkResult = label(@"");
    self.gkResult.font = [NSFont systemFontOfSize:11];
    self.gkResult.frame = NSMakeRect(152, 20, 334, 20);
    [self.gkPane addSubview:self.gkResult];
    [v addSubview:self.gkPane];

    // ---- Permissions pane ----
    self.tccPane = card(NSMakeRect(20, 70, 500, 186));
    self.tccStatus = label(@"");
    self.tccStatus.frame = NSMakeRect(14, 112, 472, 60);
    [self.tccPane addSubview:self.tccStatus];

    NSTextField *tccNote = label(
        @"Covers Accessibility, Input Monitoring, and Screen Recording warnings "
        @"(plus PostEvent / Remote Desktop). Dialogs that already have a native "
        @"Allow button are left alone.");
    tccNote.font = [NSFont systemFontOfSize:11];
    tccNote.textColor = [NSColor secondaryLabelColor];
    tccNote.frame = NSMakeRect(14, 82, 472, 30);
    [self.tccPane addSubview:tccNote];

    self.enableTcc = [NSButton checkboxWithTitle:@"Enable “Allow” button"
                                          target:self action:@selector(toggleEnable:)];
    self.enableTcc.frame = NSMakeRect(14, 56, 472, 22);
    self.enableTcc.state = ![[NSFileManager defaultManager]
        fileExistsAtPath:flagPath(@"disabled.tcc")];
    [self.tccPane addSubview:self.enableTcc];

    NSButton *testTCC = [NSButton buttonWithTitle:@"Test Permission"
                                         target:self action:@selector(testPermission:)];
    testTCC.frame = NSMakeRect(14, 16, 130, 28);
    testTCC.bezelStyle = NSBezelStyleRounded;
    testTCC.image = [NSImage imageWithSystemSymbolName:@"play.circle"
                                accessibilityDescription:nil];
    testTCC.imagePosition = NSImageLeft;
    [self.tccPane addSubview:testTCC];

    self.tccResult = label(@"");
    self.tccResult.font = [NSFont systemFontOfSize:11];
    self.tccResult.frame = NSMakeRect(152, 20, 334, 20);
    [self.tccPane addSubview:self.tccResult];
    self.tccPane.hidden = YES;
    [v addSubview:self.tccPane];

    // ---- bottom bar ----
    self.message = label(@"");
    self.message.font = [NSFont systemFontOfSize:11];
    self.message.textColor = [NSColor secondaryLabelColor];
    self.message.frame = NSMakeRect(20, 44, 500, 18);
    [v addSubview:self.message];

    self.installBtn = [NSButton buttonWithTitle:@"Install & Enable"
                                       target:self action:@selector(install:)];
    self.installBtn.frame = NSMakeRect(20, 12, 140, 32);
    self.installBtn.bezelStyle = NSBezelStyleRounded;
    self.installBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.down.to.line"
                                        accessibilityDescription:nil];
    self.installBtn.imagePosition = NSImageLeft;
    [v addSubview:self.installBtn];

    self.uninstallBtn = [NSButton buttonWithTitle:@"Uninstall"
                                         target:self action:@selector(uninstall:)];
    self.uninstallBtn.frame = NSMakeRect(170, 12, 110, 32);
    self.uninstallBtn.bezelStyle = NSBezelStyleRounded;
    self.uninstallBtn.image = [NSImage imageWithSystemSymbolName:@"trash"
                                          accessibilityDescription:nil];
    self.uninstallBtn.imagePosition = NSImageLeft;
    [v addSubview:self.uninstallBtn];

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
