# GKOpenAnyway

A small macOS app that adds an **"Open Anyway"** button directly to the
Gatekeeper "…could not verify… / Not Opened" dialog — the button Apple
compiles into the OS but never displays for unverified software.

Instead of the usual flow (dismiss → System Settings → Privacy & Security →
Open Anyway → re-open the app), you get a one-click approve button in the
dialog itself. It uses **Apple's own per-app approval path** — Touch
ID/password → per-app quarantine approval → the app opens. Nothing is
patched on disk, nothing global is disabled, and Gatekeeper stays fully
active.

| Before | After | After + default-button option |
|---|---|---|
| ![Stock Gatekeeper dialog: Move to Trash, Done](images/dialog-before.png) | ![Patched dialog: Move to Trash, Done, Open Anyway](images/dialog-after.png) | ![Open Anyway as the accent default button](images/dialog-primary.png) |

## Requirements

- macOS 27 (verified on build 26A428, Apple Silicon)
- **SIP disabled** (`csrutil disable` in Recovery)
- An admin account — Apple still asks for Touch ID/password when you
  approve; this tool does not bypass authentication

## Get the app

Download `GKOpenAnyway.app.zip` from
[Releases](../../releases), unzip, and open `GKOpenAnyway.app`.

Or build it yourself (needs Xcode command line tools):

```sh
./build-app.sh
open GKOpenAnyway.app
```

## Using the app

![GKOpenAnyway installer app](images/app-window.png)

1. **Install & Enable** — installs the payload and turns the feature on.
   No root needed, nothing stays running.
2. **Test the dialog** — opens a quarantined unsigned test app so you can
   see the button; the app shows a green confirmation once the test app
   actually launches through the new button.
3. **Make "Open Anyway" the default button** *(optional)* — gives the
   button accent styling and Return-key activation. Takes effect on the
   next dialog.
4. **Uninstall** — removes everything and restarts the agent clean.
   Fully reversible.

The installer app does not need to stay open — persistence across login is
handled by a one-shot LaunchAgent that exits immediately.

## How it works (short version)

`CoreServicesUIAgent` owns the dialog (a plain `NSAlert`). A tiny
self-gating dylib is inserted via `DYLD_INSERT_LIBRARIES`; it returns
immediately in every process except CoreServicesUIAgent, where it appends a
button with tag 105 — Apple's own "Open Anyway" dispatch tag, which is
already wired end-to-end to `LAContext` auth and per-app approval. The
button is hidden natively because "fast Gatekeeper override" mode is
reported `inactive` by an unconditional stub in syspolicyd — there is no
official way to enable it.

Full reverse-engineering details: **[REPORT.md](REPORT.md)**.

## Repository layout

| Path | Purpose |
|---|---|
| `app/` | Installer app source (AppKit, no dependencies) — the main thing |
| `dylib/` | The injected payload source (self-gating swizzle) |
| `build-app.sh` | Builds dylib + `GKOpenAnyway.app` |
| `cli/` | Optional shell install/remove scripts |
| `REPORT.md` | Full technical report |
| `images/` | Dialog screenshots |

## Safety

- Per-app approval only; no global quarantine removal, no `spctl` changes.
- Fully reversible via the app's Uninstall button (or `cli/uninstall.sh`).
- The dylib touches nothing outside CoreServicesUIAgent.
- If Apple renames the private classes, the hook simply won't install —
  nothing breaks.

## Caveats

- Requires SIP to remain disabled.
- Admin authentication is still required on approve — by design.
- macOS updates can rename/remove the private classes; verify after updates.
