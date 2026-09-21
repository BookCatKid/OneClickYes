// OneClickYes.dylib — runtime patches (macOS 27, SIP off).
// 1) CoreServicesUIAgent: adds an "Open Anyway" button (tag 105 -> Apple's
//    override flow) to Gatekeeper NSAlerts that lack an approval button.
// 2) universalAccessAuthWarn: adds an "Allow" button to the Device Control
//    and Data Access warning, calling TCCAccessSetFor* with the warningInfo's
//    own subject — same TCC write as System Settings' toggle.
#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <unistd.h>
#import <stdio.h>

static void gklog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/oneclickyes.log", "a");
    if (f) { fprintf(f, "[%lld] %s\n", (long long)getpid(), s.UTF8String); fclose(f); }
    NSLog(@"OneClickYes: %@", s);
}

// Per-hook kill switches: a flag file in the support dir disables that
// hook. Checked at load AND inside each hook — the agents are
// long-lived, so a per-dialog check makes toggling apply to the very
// next dialog without waiting for a respawn.
static BOOL ocy_disabled(const char *flag) {
    const char *home = getenv("HOME");
    if (!home) return NO;
    char p[PATH_MAX];
    snprintf(p, sizeof p,
             "%s/Library/Application Support/OneClickYes/%s", home, flag);
    return access(p, F_OK) == 0;
}

static id (*orig_alertForURL)(id, SEL, id, id) = NULL;

// -[GKQuarantineResolver alertForURL:malwareInfo:] -> NSAlert*
static id hook_alertForURL(id self, SEL _cmd, id url, id info) {
    NSAlert *alert = ((id(*)(id,SEL,id,id))orig_alertForURL)(self, _cmd, url, info);
    if (!alert || ocy_disabled("disabled.gk")) return alert;
    NSMutableString *desc = [NSMutableString string];
    BOOL hasApprove = NO;
    for (NSButton *b in [alert buttons]) {
        [desc appendFormat:@" [tag=%ld title=%@]", (long)b.tag, b.title];
        // Approve-capable buttons: tag 105 = native "Open Anyway" override,
        // tag 1000 = "Open" on the benign first-launch dialog for notarized
        // apps. 100=Cancel, 101=Done, 102=Move to Trash are dismiss/deny.
        // On dialogs that already offer an open path the tag-105 override is
        // a no-op (verified: click dismisses, no auth, no launch).
        if (b.tag == 105 || b.tag == 1000 ||
            [b.title isEqualToString:@"Open Anyway"]) hasApprove = YES;
    }
    gklog(@"alert=%p msg='%@' info='%@' buttons:%@", alert, [alert messageText], [alert informativeText], desc);
    if (!hasApprove) {
        NSButton *btn = [alert addButtonWithTitle:@"Open Anyway"];
        btn.tag = 105;   // -> performOverrideAuthenticationWithError: then approveUpdatingQuarantineTarget:
        btn.keyEquivalent = @"";
        // Optional: make it the default (accent, Return-activated) button when
        // the flag file exists. NSAlert's default button is whichever has
        // keyEquivalent == Return.
        const char *home = getenv("HOME");
        if (home) {
            NSString *flag = [[NSString stringWithUTF8String:home]
                stringByAppendingPathComponent:
                @"Library/Application Support/OneClickYes/primary"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
                for (NSButton *b in [alert buttons])
                    if ([b.keyEquivalent isEqualToString:@"\r"])
                        b.keyEquivalent = @"";
                btn.keyEquivalent = @"\r";
                gklog(@"made Open Anyway the default button");
            }
        }
        gklog(@"added Open Anyway button (tag 105)");
    }
    return alert;
}

// ---- TCC "Device Control and Data Access" Allow button ----
// universalAccessAuthWarn owns the warning window (AXASecurityWarningWindowController).
// macOS 27's dialog has no approve path: Deny just closes, Open System Settings
// opens the pane. The agent holds com.apple.private.tcc.manager.access.modify
// for the services it warns about, so it can grant directly — same write the
// System Settings toggle performs:
//   TCCAccessSetFor{Bundle,Path}(service, subject, @{kTCCInfoGranted:@YES})
// TCC symbols are dlsym'd, not linked — keeps the private framework out of the
// load dependencies of every other process this dylib maps into.

#import <dlfcn.h>

static int (*p_TCCAccessSetForBundle)(id, CFBundleRef, id);
static int (*p_TCCAccessSetForPath)(id, id, id);
static id (*p_TCCAccessCopyInformation)(id);
static CFStringRef *p_kTCCInfoGranted;
static CFStringRef *p_kTCCInfoPath;
static CFStringRef *p_kTCCInfoSubjectIdentityDictionary;
static CFStringRef *p_kTCCCodeIdentityIdentifier;

static BOOL gk_resolve_tcc(void) {
    if (p_TCCAccessSetForPath) return YES;
    p_TCCAccessSetForBundle = dlsym(RTLD_DEFAULT, "TCCAccessSetForBundle");
    p_TCCAccessSetForPath = dlsym(RTLD_DEFAULT, "TCCAccessSetForPath");
    p_TCCAccessCopyInformation = dlsym(RTLD_DEFAULT, "TCCAccessCopyInformation");
    p_kTCCInfoGranted = dlsym(RTLD_DEFAULT, "kTCCInfoGranted");
    p_kTCCInfoPath = dlsym(RTLD_DEFAULT, "kTCCInfoPath");
    p_kTCCInfoSubjectIdentityDictionary =
        dlsym(RTLD_DEFAULT, "kTCCInfoSubjectIdentityDictionary");
    p_kTCCCodeIdentityIdentifier =
        dlsym(RTLD_DEFAULT, "kTCCCodeIdentityIdentifier");
    return p_TCCAccessSetForBundle && p_TCCAccessSetForPath &&
           p_TCCAccessCopyInformation && p_kTCCInfoGranted && p_kTCCInfoPath &&
           p_kTCCInfoSubjectIdentityDictionary && p_kTCCCodeIdentityIdentifier;
}

static BOOL gk_is_granted(id service, NSString *bid, NSString *path) {
    for (NSDictionary *r in p_TCCAccessCopyInformation(service)) {
        NSString *rid = r[(id)*p_kTCCInfoSubjectIdentityDictionary]
                         [(id)*p_kTCCCodeIdentityIdentifier];
        BOOL match = (bid && [rid isEqual:bid]) ||
                     (path && [r[(id)*p_kTCCInfoPath] isEqual:path]);
        if (match && [r[(id)*p_kTCCInfoGranted] boolValue]) return YES;
    }
    return NO;
}

static void gk_allow_clicked(id self_, SEL _cmd, id sender) {
    if (!gk_resolve_tcc()) { gklog(@"allow: TCC symbols unavailable"); return; }
    NSWindow *win = [(NSView *)sender window];
    id ctrl = [win windowController];
    id info = [ctrl warningInfo];
    id service = [info performSelector:@selector(_tccServiceForWarningType)];
    if (!info || !service) { gklog(@"allow: no warningInfo/service"); return; }
    NSDictionary *grant = @{(id)*p_kTCCInfoGranted: @YES};
    NSBundle *bundle = [info bundle];
    NSString *bid = bundle.bundleIdentifier;
    NSString *path = bundle.bundleURL.path;
    if (!path.length) path = [[info binaryURL] path];
    // Dismiss via Apple's own path FIRST: the request lifecycle writes a
    // denied record when the dialog closes without consent, which clobbers
    // a grant written before dismissal (observed: rc=1 but kTCCInfoGranted=0).
    [ctrl performSelector:@selector(pressOKButton:) withObject:sender];
    for (int attempt = 0; attempt < 6; attempt++) {
        int rc = -1;
        if (bundle.bundleURL) {
            CFBundleRef cb = CFBundleCreate(kCFAllocatorDefault,
                                            (CFURLRef)bundle.bundleURL);
            if (cb) {
                rc = p_TCCAccessSetForBundle(service, cb, grant);
                CFRelease(cb);
            }
        }
        if (rc != 0 && path.length)
            rc = p_TCCAccessSetForPath(service, path, grant);
        gklog(@"allow: service=%@ bundle=%@ rc=%d attempt=%d",
              service, bundle, rc, attempt);
        if (gk_is_granted(service, bid, path)) {
            gklog(@"allow: granted verified for %@", path);
            break;
        }
        usleep(250 * 1000);
    }
}

static void (*orig_awakeFromNib)(id, SEL) = NULL;

static void hook_awakeFromNib(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_awakeFromNib)(self, _cmd);
    if (ocy_disabled("disabled.tcc")) return;
    NSWindow *win = [self window];
    NSView *content = [win contentView];
    if (!content) return;
    // Button bar = the subview that already holds the real buttons.
    NSView *bar = nil;
    for (NSView *v in content.subviews)
        if (![v isKindOfClass:[NSImageView class]] &&
            ![v isKindOfClass:[NSStackView class]]) bar = v;
    if (!bar) return;
    NSButton *btn = [[NSButton alloc]
        initWithFrame:NSMakeRect(60, 5, 130, 24)];
    btn.title = @"Allow";
    btn.bezelStyle = NSBezelStyleRounded;
    btn.action = @selector(gkAllowAction);
    static char key;
    // The target must be an ObjC object; register a tiny handler class once
    // and pin an instance to the button so it outlives the window.
    static Class HandlerCls;
    if (!HandlerCls) {
        HandlerCls = objc_allocateClassPair([NSObject class], "GKAllowHandler", 0);
        class_addMethod(HandlerCls, @selector(gkAllowAction),
                        (IMP)gk_allow_clicked, "v@:@");
        objc_registerClassPair(HandlerCls);
    }
    id handler = [[[HandlerCls alloc] init] autorelease];
    objc_setAssociatedObject(btn, &key, handler, OBJC_ASSOCIATION_RETAIN);
    btn.target = handler;
    [bar addSubview:[btn autorelease]];
    gklog(@"added Allow button (service=%@)",
          [[self warningInfo] performSelector:@selector(_tccServiceForWarningType)]);
}

__attribute__((constructor)) static void gkinit(void) {
    char path[PATH_MAX]; uint32_t sz = sizeof(path);
    if (_NSGetExecutablePath(path, &sz) != 0) return;
    if (strstr(path, "CoreServicesUIAgent") != NULL) {
        if (ocy_disabled("disabled.gk")) {
            gklog(@"hook disabled by flag in %s", path); return;
        }
        Class cls = objc_getClass("GKQuarantineResolver");
        if (!cls) { gklog(@"GKQuarantineResolver class not found"); return; }
        SEL sel = @selector(alertForURL:malwareInfo:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { gklog(@"alertForURL:malwareInfo: not found"); return; }
        orig_alertForURL = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_alertForURL);
        gklog(@"installed hook in %s (pid %d)", path, getpid());
        return;
    }
    if (strstr(path, "universalAccessAuthWarn") != NULL) {
        if (ocy_disabled("disabled.tcc")) {
            gklog(@"TCC hook disabled by flag in %s", path); return;
        }
        Class cls = objc_getClass("AXASecurityWarningWindowController");
        if (!cls) { gklog(@"AXASecurityWarningWindowController not found"); return; }
        SEL sel = @selector(awakeFromNib);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { gklog(@"awakeFromNib not found"); return; }
        orig_awakeFromNib = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_awakeFromNib);
        gklog(@"installed TCC hook in %s (pid %d)", path, getpid());
        return;
    }
}
