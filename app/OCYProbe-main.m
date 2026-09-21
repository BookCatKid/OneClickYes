// OCYProbe — test app for the TCC "Allow" button.
// Requests Accessibility (shows the "Device Control and Data Access"
// dialog). TCC caches trust per-process, so a fresh child copy of this
// binary is spawned every 2s to re-check; on success it writes
// /tmp/ocyprobe_GRANTED_<bundle-dir-name>. Exits after 120s.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *markerPath(void) {
    // argv[0] = .../OCYProbe-NNNN.app/Contents/MacOS/ocyprobe — use the
    // bundle dir name so each test copy has a unique marker.
    NSString *arg = @(NSProcessInfo.processInfo.arguments[0].UTF8String);
    NSString *base = arg;
    NSRange d = [arg rangeOfString:@".app/"];
    if (d.location != NSNotFound) {
        NSString *pre = [arg substringToIndex:d.location];
        base = [pre lastPathComponent];
    }
    return [NSString stringWithFormat:@"/tmp/ocyprobe_GRANTED_%@", base];
}

@interface P : NSObject <NSApplicationDelegate>
@property (nonatomic) NSDate *deadline;
@end

@implementation P
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:120];
    NSDictionary *o = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
    [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
        selector:@selector(poll) userInfo:nil repeats:YES];
}
- (void)poll {
    // Fresh process -> fresh trust check (TCC status is cached per process).
    NSTask *t = [NSTask new];
    t.launchPath = @(NSProcessInfo.processInfo.arguments[0].UTF8String);
    t.arguments = @[@"--check"];
    @try {
        [t launch];
        [t waitUntilExit];
    } @catch (...) { return; }
    if (t.terminationStatus == 42) {
        [[NSString stringWithFormat:@"granted pid=%d\n", getpid()]
            writeToFile:markerPath() atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
        [NSApp terminate:nil];
    }
    if ([[NSDate date] compare:self.deadline] == NSOrderedDescending)
        [NSApp terminate:nil];
}
@end

int main(int argc, const char *argv[]) {
    if (argc > 1 && !strcmp(argv[1], "--check"))
        return AXIsProcessTrustedWithOptions(NULL) ? 42 : 43;
    NSApplication *a = [NSApplication sharedApplication];
    [a setDelegate:[P new]];
    [a setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [a run];
    return 0;
}
