// GKOpenAnyway.dylib — runtime patch for CoreServicesUIAgent (macOS 27, SIP off).
// Adds an "Open Anyway" button (tag 105 -> Apple's override flow) to Gatekeeper
// NSAlerts that lack an approval button, by swizzling
// -[GKQuarantineResolver alertForURL:malwareInfo:].
#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <stdio.h>

static void gklog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/gkopenanyway.log", "a");
    if (f) { fprintf(f, "[%lld] %s\n", (long long)getpid(), s.UTF8String); fclose(f); }
    NSLog(@"GKOpenAnyway: %@", s);
}

static id (*orig_alertForURL)(id, SEL, id, id) = NULL;

// -[GKQuarantineResolver alertForURL:malwareInfo:] -> NSAlert*
static id hook_alertForURL(id self, SEL _cmd, id url, id info) {
    NSAlert *alert = ((id(*)(id,SEL,id,id))orig_alertForURL)(self, _cmd, url, info);
    if (!alert) return alert;
    NSMutableString *desc = [NSMutableString string];
    BOOL hasApprove = NO;
    for (NSButton *b in [alert buttons]) {
        [desc appendFormat:@" [tag=%ld title=%@]", (long)b.tag, b.title];
        // tag 105 = Apple's "Open Anyway" override button; 100=Cancel, 101=Done,
        // 102=Move to Trash are dismiss/deny tags, NOT approve buttons.
        if (b.tag == 105 || [b.title isEqualToString:@"Open Anyway"]) hasApprove = YES;
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
                @"Library/Application Support/GKOpenAnyway/primary"];
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

__attribute__((constructor)) static void gkinit(void) {
    char path[PATH_MAX]; uint32_t sz = sizeof(path);
    if (_NSGetExecutablePath(path, &sz) != 0) return;
    if (strstr(path, "CoreServicesUIAgent") == NULL) return;
    Class cls = objc_getClass("GKQuarantineResolver");
    if (!cls) { gklog(@"GKQuarantineResolver class not found"); return; }
    SEL sel = @selector(alertForURL:malwareInfo:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { gklog(@"alertForURL:malwareInfo: not found"); return; }
    orig_alertForURL = (void*)method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_alertForURL);
    gklog(@"installed hook in %s (pid %d)", path, getpid());
}
