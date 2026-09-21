# Gatekeeper "Open Anyway" button — technical report

Target: macOS 27.0 (26A428), arm64 (T8132), **SIP disabled** (`csrutil status`: disabled).
Status: **working proof of concept, verified end-to-end.**

---

## 1. Verified: who owns the dialog

The "Not Opened" / "Apple could not verify…" dialog is a plain `NSAlert` created,
run and dispatched by:

- **Process:** `/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/MacOS/CoreServicesUIAgent`
  (`com.apple.coreservices.uiagent`, universal arm64e, ~800 KB)
- **Launch:** `gui/<uid>/com.apple.coreservices.uiagent` LaunchAgent,
  `/System/Library/LaunchAgents/com.apple.coreservices.uiagent.plist`
- **XPC endpoints (from `launchctl print`):**
  `com.apple.coreservices.quarantine-resolver`, `com.apple.coreservices.code-evaluation`

Verified empirically, not assumed: while a blocked app was opened,
`CGWindowListCopyWindowInfo` shows the 260×~310 dialog window owned by
CoreServicesUIAgent's pid, and `lsappinfo` lists it. The blocked app is spawned
in `T` (suspended) state under App Translocation while the dialog is up.

syspolicyd does the *assessment* (CoreServicesUIAgent links
`SystemPolicy.framework` and holds `com.apple.private.AuthorizationServices =
[com.apple.security.assessment.update]`,
`com.apple.private.security.syspolicy.gatekeeper.override-source = true`).
CoreServicesUIAgent is only the UI/approval broker for LaunchServices — it does
not render via SecurityAgent or Security.framework.

## 2. Verified: dialog construction and dispatch

Objective-C classes in the binary (from `__objc_classlist`):

- `CSUIQuarantineMessageHandler` — XPC handler; delegate receiving
  `resolver:willApproveURLs:` / `resolver:didApproveURLs:` (this is how
  LaunchServices is told to proceed with the open).
- `GKQuarantineResolver` — owns the whole flow.
- `GKQuarantineInfo`, `GKQuarantineStrings`, `GKSystemPolicy`,
  `GKProgressWindowController`, `AlertInfo`.

Key methods (arm64e unslid addresses):

| Address | Method |
|---|---|
| `0x100013cac` | `-[GKQuarantineResolver approveUpdatingQuarantineTarget:recursively:volume:]` |
| `0x100014c3c` | `-[GKQuarantineResolver alertForURL:malwareInfo:]` → `NSAlert*` |
| `0x100014e30` | `-[GKQuarantineResolver alertForURL:withButtons:notarized:notarizationDate:malwareInfo:quarantineInfo:allowUnsigned:riskCategory:appASN:]` |
| `0x1000186a0` | `-[GKQuarantineResolver performOverrideAuthenticationWithError:]` (LAContext) |
| `0x1000187cc` | `-[GKQuarantineResolver handleButtonClicked:forMalwareInfoDictionary:]` |
| `0x100019388` | `-[GKQuarantineResolver malwareChecksFinished]` |
| `0x10001bbec` | `+[GKSystemPolicy isNewGatekeeperOverrideEnabled]` |

Flow (all verified in disassembly + at runtime):

1. `malwareChecksFinished` → `alertForURL:malwareInfo:` → NSAlert built by the
   long `alertForURL:withButtons:…` method: `objc_opt_new(NSAlert)`,
   up to three `addButtonWithTitle:` + `setTag:` calls, `setShowsSuppressionButton:`,
   `setHelpAnchor:`, `setIcon:` (`NSImageNameCaution` or
   `alertIconWithCautionBadge:`).
2. `malwareChecksFinished` calls `[alert runModal]` and passes the result
   **directly** to `handleButtonClicked:forMalwareInfoDictionary:`.
   `runModal` returns the clicked button's **tag** (all GK buttons get a tag).
3. `handleButtonClicked:` is a switch on the tag (verified cmp chain):

   | Tag | Observed button | Action |
   |---|---|---|
   | 100 (`0x64`) | Cancel | reject/deny path (rejection record for malware types, `deny`) |
   | 101 (`0x65`) | Done | dismiss/deny path |
   | 102 (`0x66`) | Move to Trash | `recycleURLs:` + `deny` |
   | 103 (`0x67`) | (dmg/eject variant) | unmount/recycle + `deny` |
   | 104 (`0x68`) | (other alert type) | `initWithName:` notification path |
   | **105 (`0x69`)** | **"Open Anyway"** | `isNewGatekeeperOverrideEnabled` → `performOverrideAuthenticationWithError:` → shared tail: `approveUpdatingQuarantineTarget:recursively:volume:` |
   | 106 (`0x6a`) | (malware submit) | `stageMalwareSampleForToken:withURL:` + `deny` |

   `isNewGatekeeperOverrideEnabled` is just
   `_os_feature_enabled_impl("SystemPolicy", "NewGatekeeperOverrides")` —
   **enabled on this system** (the auth prompt appears).
   `performOverrideAuthenticationWithError:` builds an `LAContext`
   (policy `0x403`, `setOptionCallerIconPath:/CallerName:/AuthenticationTitle:`)
   — this is the same Touch-ID/admin prompt that System Settings' "Open Anyway"
   produces; the UI is hosted by `coreautha`.

4. `approveUpdatingQuarantineTarget:recursively:volume:` (verified) updates the
   quarantine state **for that URL only** and calls
   `resolver:willApproveURLs:` / `resolver:didApproveURLs:` on the
   `CSUIQuarantineMessageHandler` delegate, plus `LSRegisterURLWithOptions` —
   LaunchServices then resumes the original `open`. This **is** macOS's
   existing per-app approval mechanism; nothing global is touched.

**The important part:** tag `105` is Apple's own "Open Anyway" dispatch entry —
the button is simply not offered for unverifiable apps since macOS 15. Re-adding
it does not require implementing any approval logic; we only need to inject a
button that produces the right `runModal` return value.

**Other dialog variants share this builder (verified):** the benign
first-launch alert for *notarized* apps ("…downloaded from the Internet. Are
you sure you want to open it?") is built by the same method with buttons
`[tag=1000 Open] [tag=1002 Cancel]`. Tag 1000 is already an open path, and
injecting 105 there is a dead button (verified: the click dismisses the
alert; depending on state it either launches with no auth or does nothing —
either way it is wrong UI). The hook therefore skips any alert that already
contains tag 105 or tag 1000.

## 3. Verified: injection vector

- No `__RESTRICT` segment; code signature `flags=0x0` (platform binary, no
  hardened-runtime bit needed by dyld here).
- With SIP disabled, `DYLD_INSERT_LIBRARIES` set via `launchctl setenv` **is
  honored for platform binaries**. Proven: an adhoc-signed probe dylib's
  constructor ran inside CoreServicesUIAgent, triald, geodMachServiceBridge,
  Keychain Circle Notification, AXVisualSupportAgent.
- Deliver via: `launchctl setenv DYLD_INSERT_LIBRARIES <dylib>` then
  `launchctl kickstart -k gui/<uid>/com.apple.coreservices.uiagent`.
- Fully reversible: `launchctl unsetenv` + kickstart. No system files touched.
- **The payload must carry a slice for every architecture in the domain
  (verified):** dyld *aborts the entire process* if an inserted dylib has no
  slice matching the running architecture — the self-gating constructor
  never gets a chance to run. macOS 27 system binaries ship `arm64e` +
  `arm64e.x1` (cpusubtype 12|0x80 — a newer ptrauth ABI variant); Mail and
  Messages spawn as `arm64e.x1` and were killed at launch until the dylib
  gained that slice. Build with all four:
  `-arch arm64 -arch arm64e -arch arm64e.x1 -arch x86_64` (x86_64 covers
  Rosetta processes). `clang` accepts `arm64e.x1` directly.
- **Cascade failure mode (verified):** while a bad insert is active, on-demand
  services crash-loop at spawn (`OS_REASON_DYLD`) and accumulate
  `successive crashes`; launchd then throttles them into `spawn scheduled`,
  so they stay dead *after* the dylib is fixed — and every client doing
  synchronous XPC to them deadlocks (Messages: `DaemonConnectionSetup` →
  imagent → IMDPersistenceAgent → Contacts init → contactsd, wedged at 18
  crashes / 142 runs). `launchctl kickstart` does not override the throttle;
  remediation is `launchctl bootout <dom>/<svc>` +
  `launchctl bootstrap <dom> <plist>` to reset the crash history.

## 4. Proof of concept (verified)

`dylib/OneClickYes.m` (~75 lines): constructor self-gates to CoreServicesUIAgent,
`method_setImplementation`-swizzles `alertForURL:malwareInfo:`; after the
original returns, if no button already has tag 105 it calls
`addButtonWithTitle:@"Open Anyway"` + `setTag:105`.

Verified results (unsigned, quarantined test app):

- Dialog screenshot shows `Move to Trash` / `Done` / **`Open Anyway`**.
- Runtime log of real buttons for the blocked dialog:
  `[tag=102 Move to Trash] [tag=101 Done]` + our `[tag=105 Open Anyway]`.
- Click → `coreautha` Touch ID/password prompt ("…to continue with Privacy &
  Security") — Apple's own override UI.
- After auth → app launched (`main()` ran), `com.apple.quarantine` xattr went
  `0083` → `00c3` (approved bit set), and a second `open` launches instantly
  with no dialog — per-app approval persisted.
- Note: `spctl -a` still reports "rejected / no usable signature" — the override
  is recorded against the quarantined item's launch state, not as a signing
  exception. Normal Gatekeeper behavior.

## 5. Limitations / caveats

- **`launchctl setenv` is session-wide.** Every launchd child spawned afterward
  loads the dylib at exec (it early-returns unless the executable path contains
  `CoreServicesUIAgent`). Harmless but noisy; keep the constructor minimal.
  `setenv` also does not survive logout/reboot — use the included
  `local.oneclickyes.plist` LaunchAgent to re-apply at login.
- The injected dylib must carry an `arm64e` slice (built `-arch arm64 -arch arm64e`),
  adhoc signature is fine.
- The override requires interactive admin auth (Touch ID/password) — this is
  Apple's design; a truly auth-free one-click variant would need a custom tag
  plus a swizzle of `handleButtonClicked:` calling
  `approveUpdatingQuarantineTarget:` directly (unverified, not implemented).
- JETSAM can kill the agent when idle; it respawns on demand with the
  injection intact (env is held by launchd, not the process).
- macOS updates can change method signatures/addresses — the swizzle is by
  selector name so it degrades gracefully (hook just won't install).

## 6. Unverified / hypotheses

- Exact tag semantics for 103/104/106 (trash-variant/notification/submit) —
  inferred from callees, not exercised.
- Whether tag-101-style dismissal is enforced inside `deny`/`setState:` vs.
  the shared tail — empirically "Done" does *not* approve (dialog reappears on
  next open), so don't reuse tag 101.
- Binary patching the on-disk file would additionally require breaking the
  sealed system volume (`csrutil authenticated-root disable` + bless a modified
  snapshot) — unnecessary given runtime injection works.
- lldb/`task_for_pid` attach should also work with SIP off but wasn't needed.

## 7. Reproduction

```sh
# build
clang -arch arm64 -arch arm64e -dynamiclib -o OneClickYes.dylib dylib/OneClickYes.m \
  -framework Foundation -framework AppKit
codesign -s - OneClickYes.dylib

# activate (this session)
cli/install.sh        # = launchctl setenv + kickstart -k gui/$(id -u)/com.apple.coreservices.uiagent

# persist across login (optional)
cp local.oneclickyes.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.oneclickyes.plist

# remove
cli/uninstall.sh
```

Log: `/tmp/oneclickyes.log` (hook installs, alerts seen, buttons added).

## 8. No official way to surface the button (verified)

Question: can Apple's own "Open Anyway" button be enabled in this dialog
without injection? **No — and the reason is now fully traced.** The button and
its entire approval pipeline ship in the OS; the only switch that displays it
is hard-stubbed off inside syspolicyd in this build.

The button-inclusion chain (all verified in disassembly):

1. `-[GKQuarantineResolver alertForURL:withButtons:…]` (0x100015448, dialog
   category `0xc` = unverified): calls
   `+[GKSystemPolicy isFastGatekeeperOverrideActive]`, ORs the result into the
   flag that selects the `Q_HEADLINE_SUNFISH_NOT_VERIFIED_ALLOW` strings /
   Open-Anyway button (`orr w10, w10, w0` → `csel` on the localized key refs at
   0x100015460–0x10001547c). Base flag = `notarized`, so the approve-style
   button only ever appears natively for *notarized-but-blocked* apps — never
   for "could not verify" apps.

2. `+[GKSystemPolicy isFastGatekeeperOverrideActive]` (0x10001bc00) =
   `[[SPExecutionPolicy new] isFastGatekeeperOverrideModeEnabled]` →
   `doBooleanXPCFunction` → syspolicyd XPC method
   `-[ExecManagerService getFastGatekeeperOverrideModeEnabledWithReply:]`
   (0x100039118).

3. That XPC handler's reply block (syspolicyd 0x100039238–0x1000392c8) is an
   **unconditional stub**: it logs the *literal* string
   `"Fast Gatekeeper overrides are: inactive"` and invokes the reply with
   `(NO, nil)` — `mov w1,#0x0; mov x2,#0x0; blraa`. No branch, no defaults
   read, no ivar, no policy check. There is no code path that returns YES.

Every lever that could plausibly enable it was checked:

- **defaults domains read by syspolicyd:** `com.apple.security.syspolicy`
  (generic getter at 0x100061d44) and `com.apple.systempolicy.managed`. The
  only override-related key is `DisableOverride` (0x100061de8,
  `areGatekeeperOverridesAllowed` = `!boolForKey:@"DisableOverride"`) — an MDM
  restriction that *removes* override ability, the opposite direction.
- **Feature flags:** `/System/Library/FeatureFlags/Domain/SystemPolicy.plist`
  ships `NewGatekeeperOverrides: FeatureComplete` (that's why tag 105's
  LAContext dispatch works at all). No flag exists for the override *mode* —
  `isFastGatekeeperOverrideActive` is a live XPC query, not a feature flag.
- **ExecManagerService XPC surface:** contains no setter for the fast-override
  mode. `setGatekeeperPolicy:`, `setStrictGatekeeperEnabled:forDomain:`,
  `setBlockedSoftwareOverride:isEnabled:`, `addGatekeeperOverride…` all exist
  but require the private entitlement
  `com.apple.private.security.syspolicy.gatekeeper.override-source`
  (enforced via `valueForEntitlement:` check at 0x100039488) and none of them
  feed the stubbed reply anyway.
- **`ExecManagerPolicy.newGatekeeperEnabled`** (ivar +0x51, setter
  0x10001a1d8) is never invoked in-binary — only reachable via entitled XPC —
  and it doesn't feed the fast-override reply either.
- **`updateMDMState`** (0x1000214f0) only reads
  `+[ConfigurationProfiles isMDMConfiguredSystem]` → logs
  "GK Is MDM System: %d" — MDM enrolment does not enable the mode.
- The init path reads `csr_get_active_config` and
  `os_variant_allows_internal_security_policies` (0x100061108) — the remaining
  plausible consumer is AppleInternal-only policy paths, i.e. the feature is
  likely unfinished/internal rather than user-reachable.

Officially supported alternatives (all confirmed, all more clicks/different
surface — none put a button in the dialog):

- System Settings → Privacy & Security → "Open Anyway" (the sanctioned flow;
  reaches the same LAContext-auth + `approveUpdatingQuarantineTarget:` path).
- `xattr -d com.apple.quarantine <app>` — strips quarantine for that file.
- `spctl --add <app>` — per-app signing exception (admin).
- `spctl --master-disable` / right-click→Open — global disable / not offered
  for unverified software on this OS version (excluded by requirements anyway).

**Conclusion:** Apple compiles the Open-Anyway button into the dialog builder
and wires its tag-105 dispatch end-to-end (LAContext auth → per-app
`approveUpdatingQuarantineTarget:` → LaunchServices resume), but the only
condition that shows it for unverified software — the "fast Gatekeeper
override" mode — is a stub that unconditionally reports `inactive`. No
defaults key, feature flag, MDM payload, or unentitled XPC call can turn it on
in this build. The injection in this directory is therefore the minimal
change: it surfaces a button Apple already implements, using Apple's own
dispatch and approval code.

## 9. Scoping the injection (verified)

`launchctl setenv` applies to the whole gui domain — every subsequently
spawned launchd child gets `DYLD_INSERT_LIBRARIES`. We investigated every
narrower mechanism:

- **`launchctl debug <svc> --environment VAR=val`** — applies env to a single
  service. Verified: it works (`GKTEST_SCOPED=hello` appeared only in
  CoreServicesUIAgent's env) but is **one-shot** — the override is consumed by
  the next spawn; a JETSAM/idle respawn loses it. It also requires root.
- **Editing the service's own plist** (`EnvironmentVariables` in
  `/System/Library/LaunchAgents/com.apple.coreservices.uiagent.plist`) — the
  system volume is a sealed APFS snapshot (`authenticated-root: enabled`,
  mount: `sealed, read-only`); untouchable without breaking the seal, which
  would defeat the point and break OS updates.
- **Same-label plist in `/Library/LaunchAgents`** — duplicate labels lose to
  the system path; not a supported override.
- **Resident watcher + `task_for_pid`/`lldb` remote `dlopen`** — scoped and
  respawn-safe but requires an always-running helper and remote-injection
  code on arm64e (PAC signing of the entry PC, W^X). Rejected as needless
  complexity.

**Conclusion:** there is no persistent per-service env mechanism in launchd.
The correct scoping boundary is the **payload**, not the env var: the dylib's
constructor runs `_NSGetExecutablePath` first and returns immediately unless
the process is CoreServicesUIAgent — no hooks, no threads, no ObjC messages in
any other process (~nanoseconds per spawn, then the dylib sits idle).
Effective scope = the Gatekeeper dialog process only.

**Service env is a snapshot (verified):** once a service has spawned, its
`inherited environment` is frozen — `launchctl unsetenv` *and* a later
`setenv` to a different value do NOT change what a `kickstart`-respawned
agent receives. Only `launchctl debug --environment` (one-shot, root)
overlays it for a single spawn; the snapshot returns next respawn. Practical
consequence: uninstall relies on **deleting the dylib file** (a missing
insert path is skipped by dyld on respawn) — the env var itself is cosmetic
cleanup for future logins.

**In-place dylib replacement corrupts code-signing state (verified):**
updating the installed dylib with a truncating `cp` (same inode) while any
process holds it mapped leaves stale signature state on the vnode. Every
subsequent load of that path then fails inside dyld with

    fcntl(fd, F_ADDFILESIGS_RETURN) failed with errno=37 (EALREADY)

— `codesign -v` passes and the bytes are correct, but the kernel refuses the
signature, so `launchd`-spawned processes die with
`OS_REASON_CODESIGNING`. Because `setenv` is session-wide this manifested as
a mass crash-storm of GUI-domain children plus a CoreServicesUIAgent
crash-loop. The identical bytes load fine from a different path (fresh
inode). **Fix: always install atomically** — copy to a temp name in the same
directory, sign the temp, `rename()` over the final path. The installer now
does this; `clang -o` output is already safe (new file each build).

## 10. Installer app

`OneClickYes.app` (built by `build-app.sh`) — a small AppKit installer,
no root required (everything runs in the user's gui domain):

- **Install & Enable**: copies the dylib to
  `~/Library/Application Support/OneClickYes/`, adhoc-signs it, writes and
  bootstraps `~/Library/LaunchAgents/local.oneclickyes.plist`
  (`RunAtLoad` → `launchctl setenv` + `kickstart` — one-shot, exits), then
  applies the env and restarts the agent immediately.
- **Uninstall**: boots out the LaunchAgent, removes the plist, `unsetenv`s,
  restarts the agent clean, deletes the support directory. Fully reversible.
- **Test Gatekeeper**: drops a fresh unsigned quarantined app
  (`OCYTest-<random>.app`) and opens it, reproducing the "…could not verify…"
  dialog on demand. The test app writes a unique marker file
  (`/tmp/ocytest_LAUNCHED_<name>`) from `main()` — the installer watches for it
  and shows a green "Test app launched — the Open Anyway button works" line
  once the launch actually completes (120s timeout otherwise).
- **Test Permission**: drops a fresh `OCYProbe-<random>.app` (new bundle id
  per copy, adhoc re-signed) that calls
  `AXIsProcessTrustedWithOptions(prompt:YES)` — raising the real permission
  dialog on demand. Since TCC trust state is cached per-process, the probe
  re-checks via a fresh child (`--check` argv) every 2s and writes
  `/tmp/ocyprobe_GRANTED_<name>` when trust is functionally active.
- **Migration**: on launch the app migrates a GKOpenAnyway install — moves
  the support dir (preserving the `primary` flag), boots out and removes
  the old LaunchAgent, and rewrites the injection env to the new path.
- **Make "Open Anyway" the default button** (optional checkbox): creates a
  flag file in the support dir. When present, the dylib clears `keyEquivalent`
  from Apple's existing default button and sets the tag-105 button's
  `keyEquivalent` to Return — giving it accent styling and Return-key
  activation. Read per-dialog, so toggling needs no restart. Verified: with
  the flag, Open Anyway renders accent-blue and pressing Return enters the
  LAContext auth flow; without it, Apple's default ("Move to Trash") keeps
  the accent.
- Status panel shows SIP state, LaunchAgent presence, env state, and whether
  the running agent has the hook loaded (plus last hook activity timestamp).

Nothing is resident: the LaunchAgent exits immediately, the app is just the
installer, and CoreServicesUIAgent loads the payload itself each time it
spawns.

## 11. TCC "Device Control and Data Access" Allow button (verified)

The same injection architecture extends to the native macOS 27 permission
warning formerly shown for Accessibility. All findings below verified on
macOS 27 (26A428), SIP disabled.

### Owner and classes

- Dialog owner: `universalAccessAuthWarn`
  (`/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app`),
  spawned on demand as `gui/<uid>/com.apple.universalaccessAuthWarn`, fed by
  `com.apple.universalaccessd` / `tccd` over a peer XPC
  (`com.apple.universalaccessAuthWarn.peer[pid]`).
- Window controller: `AXASecurityWarningWindowController`
  (`initWithWarningInfo:`, `awakeFromNib`, `pressOKButton:`,
  `pressOpenSystemPrefsButton:`, `pressHelpButton:`,
  `pressDontShowAgainCheckbox:`, `pressDisclosuerTriangle:`).
- Requester object: `AXAWarningInfo` — carries `pid`, `responsiblePid`,
  `responsiblePidPath`, `binaryURL`, `bundle`, `resolvedBundle`,
  `warningType`, `displayType`, plus `shouldShowWarning`,
  `markBundleAsDenied`, `_tccServiceForWarningType`.
- The binary holds `com.apple.private.tcc.manager.access.{read,modify}` for
  `kTCCServiceAccessibility`, `kTCCServicePostEvent`,
  `kTCCServiceScreenCapture`, `kTCCServiceListenEvent`,
  `kTCCServiceRemoteDesktop`.

### macOS 27 change vs older Accessibility prompts

This dialog has **no approve path at all**. Buttons are "Open System
Settings" (opens the Privacy pane URL), "Deny" (`pressOKButton:` — disassembly
shows it only dismisses the window; it writes nothing), and a help icon.
Denial is persisted separately via `markBundleAsDenied`
(`TCCAccessSetFor{Bundle,Path}(service, subject, NULL)`), invoked when
`shouldShowWarning` is false or "don't show again" is set. The don't-show
list lives in `~/Library/Preferences/com.apple.universalaccessAuthWarning.plist`
(`<warningType>::<identifier>` keys; type 0 = Accessibility).

### The grant operation (verified)

`warningInfo._tccServiceForWarningType` maps the warning to its TCC service
(type 0 → `kTCCServiceAccessibility`, verified live). The symmetric grant is:

```
TCCAccessSetForBundle(service, CFBundle(bundleURL), @{ kTCCInfoGranted: @YES })
```

with `TCCAccessSetForPath(service, path, @{ kTCCInfoGranted: @YES })` as
fallback. Verified end to end: after the call, `TCCAccessCopyInformation`
shows `kTCCInfoGranted = 1` with a proper designated-requirement code
identity (`kTCCCodeIdentityIdentifier = com.example.axprobe6`, cdhash DR) —
a real durable grant, and the requester reports
`AXIsProcessTrustedWithOptions` → `trusted=1` on relaunch.

### Injection (verified)

The domain-wide `DYLD_INSERT_LIBRARIES` already reaches
`universalAccessAuthWarn`; the dylib's self-gate gained a second branch:
if the executable path contains `universalAccessAuthWarn`, swizzle
`-[AXASecurityWarningWindowController awakeFromNib]` and append an "Allow"
`NSButton` to the window's button bar. TCC symbols are `dlsym`'d (not
linked) so the private framework never enters the load dependencies of other
processes. On click, the handler pulls `warningInfo` off the window
controller — real requester identity, not display text — resolves the
service, then **dismisses first** via Apple's own `pressOKButton:` and
only then writes the grant. Ordering matters: the request lifecycle
records a denied auth result when the dialog closes without consent, and
that write can clobber a grant issued beforehand (observed: `rc=1` from
the setter, `kTCCInfoGranted=0` in the record, `AUTHREQ_RESULT authValue=0`
on re-check). After dismissing, the handler sets the grant and verifies
via `TCCAccessCopyInformation`, retrying briefly until the record shows
granted.

Verified on screen: dialog renders "…would like to control this Mac and
access your data" with Allow between Help and Open System Settings; clicking
Allow logged `rc=1`, produced the granted record, and closed the dialog.
Clicking Deny on a second probe left the requester untrusted (`trusted=0`,
no record written). No grant occurs without an explicit click.

### Requester caveats

- The warning only appears for well-formed GUI-app requesters: a bare
  command-line binary launched via `open` gets `displayType != 0` in
  `AXAWarningInfo` → `shouldShowWarning` returns NO → the agent auto-denies
  without UI. Test requesters need `NSApplicationMain` (a real run loop);
  LS-registered or not is not the deciding factor.
- A requester that exits before the agent evaluates it is auto-denied too
  (peer XPC dead → nothing to warn about).

### Other warning types (verified)

The Allow button is not Accessibility-specific: the same
`universalAccessAuthWarn` agent presents the whole "control / monitor /
capture" warning family, and the hook resolves the service per-warning via
`_tccServiceForWarningType` rather than hardcoding. Verified a second type
end to end: the "Keystroke Receiving" prompt (`kTCCServiceListenEvent`,
Input Monitoring) got the Allow button; clicking it wrote granted records
(bundle-id + path identities) and the requester's `CGEventTapCreate`
succeeded on relaunch. The agent's modify entitlement covers
Accessibility, PostEvent, ListenEvent, ScreenCapture, and RemoteDesktop, so
the same path should cover all of them.

Not covered: permission prompts owned by other processes (camera,
microphone, Files & Folders, Full Disk Access, Local Network, etc.) — those
are different dialogs that would need their own investigation.

Caveat: early builds stored a denied record despite the set call
returning success — the pending request's denied result lands at
dialog-close time and overwrote grants written while the window was still
up. Fixed by dismissing before granting; the handler then verifies via
`TCCAccessCopyInformation` and retries (~1.5s budget) until the record
shows `kTCCInfoGranted=1`. Verified on a fresh Accessibility requester:
single click → `granted verified` → requester functionally trusted.

### Other permission dialogs on macOS 27 (verified map)

Two distinct prompt families exist; only one lacks a native approve path.

**UserNotificationCenter family — native `Don't Allow` / `Allow` already
present (verified by triggering each with a signed probe app):**

| Service | Owner | Buttons observed |
|---|---|---|
| Camera | UserNotificationCenter | Don't Allow / Allow |
| Microphone | UserNotificationCenter | Don't Allow / Allow |
| Contacts | UserNotificationCenter | Don't Allow / Allow |
| Photos | UserNotificationCenter | Allow All Photos / Don't Allow |
| Automation ("wants to control") | UserNotificationCenter | Don't Allow / Allow |

Calendar/Reminders, Bluetooth, HomeKit, Media Library, Speech Recognition
and friends use the same prompt machinery and are expected to behave the
same (not individually triggered). Camera/mic requests from an app lacking
`com.apple.security.device.{camera,audio-input}` are silently denied — no
prompt at all.

**universalAccessAuthWarn family — no native approve path; our Allow
button covers all of them:**

- `kTCCServiceAccessibility` — "Device Control and Data Access" (verified)
- `kTCCServiceListenEvent` — "Keystroke Receiving" (verified end to end)
- `kTCCServiceScreenCapture` — "Screen Recording" (verified the dialog is
  owned by this agent and gets our Allow button; grant path is identical)
- `kTCCServicePostEvent`, `kTCCServiceRemoteDesktop` — same agent/entitlement,
  untested but same code path

**Other cases:**

- **Full Disk Access** has no prompt API at all — denial is silent; granting
  is Settings-only by design. Nothing to hook.
- **Files & Folders (Documents/Desktop/Downloads)**: no prompt fired for an
  adhoc non-sandboxed probe even under LaunchServices attribution — read
  and write succeeded silently. Not triggerable here.
- **Local Network**: Bonjour browse from the probe did not prompt
  (probably requires an actual local connect, or suppresses unentitled
  apps). Historically a native Allow prompt; unverified.
- **Notifications** are owned by usernoted/NotificationCenter with native
  Allow — separate mechanism entirely.
