# GKOpenAnyway

Adds an **"Open Anyway"** button directly to the macOS Gatekeeper
"…could not verify… / Not Opened" dialog — the button Apple compiles into the
OS but never displays for unverified software.

Instead of the usual flow (dismiss → System Settings → Privacy & Security →
Open Anyway → re-open the app), you get a one-click approve button in the
dialog itself. It uses **Apple's own per-app approval path**: tag 105 →
`LAContext` authentication (Touch ID/password) →
`approveUpdatingQuarantineTarget:` → LaunchServices resumes the open.
Nothing is patched on disk, nothing global is disabled, and Gatekeeper stays
fully active.

## Requirements

- macOS 27 (verified on build 26A428, Apple Silicon)
- **SIP disabled** (`csrutil disable` in Recovery) — required for dyld
  insertion into platform binaries
- An admin account (Touch ID/password is still requested by Apple when you
  approve — this tool does not bypass authentication)

## Install

Build and run the installer app:

```sh
./build-app.sh
open GKOpenAnyway.app
```

Click **Install & Enable**. Then **Test the dialog** to see it working —
the app shows a green confirmation once the test app actually launches.

Or from the command line:

```sh
./install.sh      # this session
./uninstall.sh    # full removal
```

Persistence across login is handled by a one-shot LaunchAgent
(`local.gkopenanyway`) — it re-applies the env and exits. Nothing stays
resident.

## How it works

`CoreServicesUIAgent` owns the dialog (a plain `NSAlert` built by
`GKQuarantineResolver`). A small self-gating dylib is inserted via
`DYLD_INSERT_LIBRARIES`; its constructor returns immediately in every process
except CoreServicesUIAgent, where it swizzles
`-[GKQuarantineResolver alertForURL:malwareInfo:]` and appends a button with
tag 105 — Apple's own "Open Anyway" dispatch tag.

The button isn't shown natively because its inclusion is gated on
"fast Gatekeeper override" mode, which syspolicyd reports as `inactive` via an
unconditional stub in this build — there is no official way to enable it.

Full reverse-engineering details, verified findings, addresses, and
alternatives: **[REPORT.md](REPORT.md)**.

## Files

| Path | Purpose |
|---|---|
| `GKOpenAnyway.m` | The injected dylib (self-gating swizzle) |
| `app/` | Installer app source (AppKit, no dependencies) |
| `build-app.sh` | Builds dylib + `GKOpenAnyway.app` |
| `install.sh` / `uninstall.sh` | CLI install/remove |
| `local.gkopenanyway.plist` | LaunchAgent template (login persistence) |
| `REPORT.md` | Full technical report |

## Safety

- Per-app approval only; no global quarantine removal, no `spctl` changes.
- Fully reversible: Uninstall (or `uninstall.sh`) unsets the env, restarts
  the agent clean, and deletes all installed files.
- The dylib touches nothing outside CoreServicesUIAgent.
- Breaks nothing if Apple changes internals: the swizzle is by selector name
  and degrades gracefully (hook simply won't install).

## Caveats

- Requires SIP to remain disabled.
- Apple still requires admin authentication on approve — by design.
- macOS updates can rename/remove the private classes; verify after updates.
