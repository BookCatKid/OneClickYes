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

`dylib/GKOpenAnyway.m` (~75 lines): constructor self-gates to CoreServicesUIAgent,
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
  `local.gkopenanyway.plist` LaunchAgent to re-apply at login.
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
clang -arch arm64 -arch arm64e -dynamiclib -o GKOpenAnyway.dylib dylib/GKOpenAnyway.m \
  -framework Foundation -framework AppKit
codesign -s - GKOpenAnyway.dylib

# activate (this session)
cli/install.sh        # = launchctl setenv + kickstart -k gui/$(id -u)/com.apple.coreservices.uiagent

# persist across login (optional)
cp local.gkopenanyway.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.gkopenanyway.plist

# remove
cli/uninstall.sh
```

Log: `/tmp/gkopenanyway.log` (hook installs, alerts seen, buttons added).

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

`GKOpenAnyway.app` (built by `build-app.sh`) — a small AppKit installer,
no root required (everything runs in the user's gui domain):

- **Install & Enable**: copies the dylib to
  `~/Library/Application Support/GKOpenAnyway/`, adhoc-signs it, writes and
  bootstraps `~/Library/LaunchAgents/local.gkopenanyway.plist`
  (`RunAtLoad` → `launchctl setenv` + `kickstart` — one-shot, exits), then
  applies the env and restarts the agent immediately.
- **Uninstall**: boots out the LaunchAgent, removes the plist, `unsetenv`s,
  restarts the agent clean, deletes the support directory. Fully reversible.
- **Test the dialog**: drops a fresh unsigned quarantined app
  (`GKTest-<random>.app`) and opens it, reproducing the "…could not verify…"
  dialog on demand. The test app writes a unique marker file
  (`/tmp/gktest_LAUNCHED_<name>`) from `main()` — the installer watches for it
  and shows a green "Test app launched — the Open Anyway button works" line
  once the launch actually completes (120s timeout otherwise).
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
