# macOS Sequoia App Management TCC Prompt: Investigation & Handoff

**Pacer Research Report**
**Date:** 2026-05-07
**Status:** Partial fix shipped (signing/notarization). One known issue
remains unresolved for the dev workflow; production impact uncertain
and needs verification before v1.

## Executive Summary

On macOS Sequoia 15.7+, `Pacer.app` triggers the
`kTCCServiceSystemPolicyAppData` ("would like to access data from
other apps") prompt on every GUI launch. We investigated for ~3
hours, fixed every signing/notarization layer we could find, and the
prompt still fires.

Root cause is architectural: Pacer is the only app on the user's
system with this exact shape — a separate-bundle-ID daemon
(`com.ericandrechek.pacer.daemon`) and a GUI app
(`com.ericandrechek.pacer`) sharing an App Group container at
`~/Library/Group Containers/group.com.ericandrechek.pacer/`. Sequoia's
App Management framework treats this as cross-app data access and
refuses to write a stable `csreq` (code-signing-requirement blob)
into TCC.db, so each user-clicked Allow lasts only that session.

A separate daemon-side prompt was fully fixed and is no longer an
issue.

The dev workflow now matches what production will look like —
Developer ID Application signed, hardened runtime, secure-timestamped,
notarized via App Store Connect API key, stapled. None of that
suppressed the GUI prompt.

The remaining open question is whether end users on Sparkle releases
will see the same prompt. The production daemon is supposed to be
registered via SMAppService instead of raw launchctl, and
SMAppService-launched helpers reportedly inherit the parent app's
TCC identity. **If true, the prompt will not affect end users.**
This must be tested on a real shipping build before v1 release.

## Final State (2026-05-07)

### What's committed

- `f7d4933` — Daemon signed with `--identifier=com.ericandrechek.pacer.daemon`
  (was `PacerDaemon`). Suppresses daemon-side prompt.
- `0cefd62` — `com.apple.security.get-task-allow=false` on both
  entitlements. Removes one untrusted-binary signal; doesn't fix the
  prompt on its own.
- `3e108a9` — Build flow switched from Xcode auto-provisioned Apple
  Development to manual Developer ID Application + notarize + staple.
  `bin/dev-install.sh` now does:
    1. `xcodebuild build` with `CODE_SIGNING_ALLOWED=NO`.
    2. `codesign --force --options runtime --timestamp --sign
       "Developer ID Application: Eric Andrechek (YZXWMJ5VBY)"`,
       inside-out (dylibs → bundles → embedded Mach-O → outer .app).
    3. `ditto -c -k --keepParent Pacer.app /tmp/Pacer.zip`.
    4. `xcrun notarytool submit ... --keychain-profile pacer-notarization
       --wait`. Fails the install if status ≠ Accepted.
    5. `xcrun stapler staple Pacer.app` + validate.
    6. Existing install/launchd flow.

### Verification commands

After a `make install`:

```bash
# Should show Developer ID Application + Notarization-friendly cert chain
codesign -dvv /Applications/Pacer.app

# Should print "accepted source=Notarized Developer ID"
spctl -av /Applications/Pacer.app

# Should print "The validate action worked!"
xcrun stapler validate /Applications/Pacer.app

# Should show com.ericandrechek.pacer.daemon (NOT just "PacerDaemon")
codesign -dvv /Applications/Pacer.app/Contents/Library/LaunchServices/PacerDaemon
```

### Notarization credentials (already set up)

The user has stored the notarization credential under keychain
profile `pacer-notarization`. It uses an App Store Connect API key
(not an app-specific password). Verify with:

```bash
xcrun notarytool history --keychain-profile pacer-notarization
```

If the profile is missing on a fresh machine, recreate with:

```bash
xcrun notarytool store-credentials pacer-notarization \
    --key /path/to/AuthKey_<KEY_ID>.p8 \
    --key-id <KEY_ID> \
    --issuer <ISSUER_UUID>
```

(Generated at App Store Connect → Users and Access → Integrations →
Team Keys with Developer role; .p8 downloadable once.)

### Container metadata patch (one-off, already applied)

The shared App Group container's metadata had
`MCMMetadataCreator=PacerDaemon` because the old (binary-name-only)
daemon binary first created it. We patched it to
`com.ericandrechek.pacer` so the App is recognized as the group's
owning bundle ID:

```bash
plutil -replace MCMMetadataCreator -string com.ericandrechek.pacer \
    ~/Library/Group\ Containers/group.com.ericandrechek.pacer/.com.apple.containermanagerd.metadata.plist
```

Doesn't suppress the prompt on its own but is a prerequisite. Should
not need to be repeated — the metadata persists across reinstalls.

## What Was Tried (Chronological)

### Stage 1 — Daemon prompt (FIXED, commit `f7d4933`)

**Symptom.** Every launch triggered a TCC prompt. Initial assumption
was the daemon was reaching into another app's data via `pgrep`/`ps`
shell-outs. Confirmed in `tccd` log:

```
AUTHREQ_PROMPTING: service=kTCCServiceSystemPolicyAppData,
  subject=Sub:{com.ericandrechek.pacer}
  Resp:{TCCDProcess: identifier=PacerDaemon, ...}
```

**Cause.** The `PacerDaemon` target is a `tool` (no Info.plist with
CFBundleIdentifier), so `codesign` defaulted the signing identifier
to the bare binary name. TCC treated `PacerDaemon` as a foreign
third-party process touching `com.ericandrechek.pacer`'s App Group
container.

**Fix.** Set `OTHER_CODE_SIGN_FLAGS = "--identifier=com.ericandrechek.pacer.daemon"`
in the daemon target so the signature carries a bundle-style ID.

**Verified.** After fix, no `AUTHREQ_PROMPTING` events with
`Resp:{TCCDProcess: identifier=com.ericandrechek.pacer.daemon}`
during normal operation.

### Stage 2 — Tried adding team-identifier entitlement (REJECTED)

Added `com.apple.developer.team-identifier=YZXWMJ5VBY` to the
daemon's entitlements file, hoping it would make TCC recognize the
daemon as same-team-as-app and waive the App Management check.

**Problem.** AMFI rejected the binary at launchd start with:

```
amfid: ... not valid: Error Domain=AppleMobileFileIntegrityError
  Code=-413 "No matching profile found"
```

That entitlement requires a matching provisioning profile, and Xcode
doesn't generate one for tool targets. The daemon was bootstrapped
in launchd but never actually ran.

**Reverted** in commit `0cefd62`. Comment in
`Daemon/PacerDaemon.entitlements` warns the next agent.

### Stage 3 — Stripped get-task-allow (committed but didn't fix prompt)

Xcode auto-injects `com.apple.security.get-task-allow=true` on Debug
builds for debugger attach. It's a TCC-trustworthiness signal — apps
with it set may receive only session-scoped grants.

Set explicitly to `false` in both `App/Pacer.entitlements` and
`Daemon/PacerDaemon.entitlements`. The dev install runs the binary
under launchd from `/Applications`, never under Xcode's debugger,
so removing it has no functional cost.

**Result.** No prompt change. Still re-prompts every launch. Kept the
change anyway — it's a prerequisite for notarization (which rejects
debuggable binaries).

### Stage 4 — Switched to Developer ID Application signing (committed but didn't fix prompt)

Theory: Apple Development certs (auto-selected by Xcode) get
session-only TCC grants on Sequoia; Developer ID Application is the
shipping path that gets persistent grants.

Switched `bin/dev-install.sh` to:
1. Build unsigned (`CODE_SIGNING_ALLOWED=NO` in project.yml)
2. Manually `codesign --sign "Developer ID Application: Eric Andrechek (YZXWMJ5VBY)"`
3. Use Apple's secure timestamp server (required for notarization)

**Bypassed Xcode's profile demand.** Setting
`CODE_SIGN_STYLE=Manual` + `CODE_SIGN_IDENTITY="Developer ID Application"`
in `project.yml` made `xcodebuild` complain `"Pacer" requires a
provisioning profile` because of the App Groups capability. Working
around that via a Developer ID provisioning profile from
developer.apple.com would have required portal round-trips. The
build-unsigned-then-sign flow sidesteps the profile demand entirely.

**Issue caught during this stage.** Debug-build dylibs
(`Pacer.debug.dylib`, `__preview.dylib`,
`PacerWidgets.debug.dylib`) were unsigned, causing dyld to fail
loading them ("different Team IDs" error) once the loader binary was
signed. Added a `find ... -name "*.dylib"` pass to the install
script so they get the same identity.

**Result.** `codesign -dvv` shows `Developer ID Application: Eric
Andrechek (YZXWMJ5VBY)` chain. Prompt still fires every launch.

### Stage 5 — Notarization (committed but didn't fix prompt)

Theory: Even Developer ID-signed binaries need to be **notarized** for
TCC to mint persistent grants on Sequoia.

Set up notarization with:
- App Store Connect API key (Developer role) at App Store Connect →
  Users and Access → Integrations → Team Keys.
- Stored credentials with
  `xcrun notarytool store-credentials pacer-notarization
      --key AuthKey_*.p8 --key-id <ID> --issuer <UUID>`.

Wired into `bin/dev-install.sh` (commit `3e108a9`):
1. `ditto -c -k --keepParent Pacer.app /tmp/Pacer.zip` — flat archive
   that the notary service expects.
2. `xcrun notarytool submit Pacer.zip --keychain-profile
   pacer-notarization --wait` — typical wall time 10–30s.
3. Parse output, fail if `status != Accepted`.
4. `xcrun stapler staple Pacer.app` so the bundle carries the ticket
   and macOS doesn't have to phone home to verify.

**Verified.** Submission accepted on first try (id
`dd7abe97-2588-4f27-a2f0-e1059eb5ac23`). `xcrun stapler validate`
returns "The validate action worked!"; `spctl -av` reports `accepted
source=Notarized Developer ID`.

**Result.** Prompt still fires every launch.

### Stage 6 — Container metadata patch (committed/manual, didn't fix prompt)

Discovered the App Group container's metadata plist had
`MCMMetadataCreator=PacerDaemon` (binary name from the original
unsigned daemon's first access). Compare to other apps: their group
containers have `MCMMetadataCreator=<bundleID>` (e.g.,
`com.apple.appstoreagent`).

Patched in place:

```bash
plutil -replace MCMMetadataCreator -string com.ericandrechek.pacer \
    ~/Library/Group\ Containers/group.com.ericandrechek.pacer/.com.apple.containermanagerd.metadata.plist
```

**Result.** Container is now correctly attributed to the App's bundle
ID. Prompt still fires every launch.

## Root Cause Analysis

### What we observed

After all of Stages 1–6, the TCC database row for
`com.ericandrechek.pacer` consistently shows:

```
client                   auth_value  length(csreq)  flags  boot_uuid_len
com.ericandrechek.pacer  5           0              0      36
```

The `auth_value=5` is the same value iTerm/Docker/etc. have for their
working entries. The discriminator is **`length(csreq)`**:

```
com.docker.docker        5  160
com.googlecode.iterm2    5  196
com.oleksii.SwiftData-Browser  5  212
com.ericandrechek.pacer  5    0  ← us
```

`csreq` is the binary blob of the app's designated requirement, used
by TCC to verify the app's identity on subsequent launches. With
csreq populated, the Allow grant survives quit+reopen. With csreq
empty, TCC has nothing to match against next launch and re-prompts.

The `tccd` log confirms the per-launch failure mode:

```
matchesCodeRequirement: ... from com.ericandrechek.pacer :
  identifier "com.ericandrechek.pacer" and anchor apple generic and
  certificate ...; status: 0
Session scoped auth is invalid for client: <private>
AUTHREQ_PROMPTING: ...
```

The signature **matches** (status 0). But the auth itself is
"session-scoped" and now invalid. So TCC isn't failing to verify the
binary — it's choosing not to give a persistent grant in the first
place, then invalidating the session grant on the next launch.

### Why our app is different

System Settings → Privacy & Security → App Management lists the
apps with persistent grants. On the user's machine these are
**iTerm, VSCode, Docker, Autodesk Fusion, Ruby apps, System Events**.
Pacer is not in the list, even after multiple Allow clicks.

Common shape across the apps that ARE in the list:
- Single binary, OR
- XPC-hosted helpers (which inherit parent identity), OR
- SMAppService-managed helpers (which inherit parent identity).

Pacer is the only app with: **separate-bundle-ID LaunchAgent helper +
shared App Group container**. macOS Sequoia's App Management
framework was designed specifically to gate this pattern.

### Confirmation that prompts come from the App, not the daemon

After a fresh `tccutil reset SystemPolicyAppData com.ericandrechek.pacer`
and a single user launch:

```
prompts in last 30s:
  com.ericandrechek.pacer    ← only the App on user-launches
```

The daemon prompts only at daemon-startup (rare, since launchd
KeepAlive holds the daemon alive across user app restarts). On a
typical user quit + relaunch cycle, only the App prompts.

## Open Question (Verify Before v1)

The M8 plan (Sparkle release) has the production daemon registered
via `SMAppService.agent`, not raw `launchctl bootstrap`. The dev
workflow uses launchctl deliberately to skip the System Settings
approval step.

**Hypothesis (untested):** SMAppService-launched helpers inherit the
parent app's TCC identity, so the production daemon's accesses are
attributed to `com.ericandrechek.pacer` (no split bundle ID), the
csreq is correctly populated, and end users don't see the prompt.

**Test plan when M8 starts:**

1. Cut a real Sparkle release archive of Pacer.app (notarized,
   stapled, all entitlements as committed).
2. Install on a clean macOS 15.7+ test account (or wipe TCC for
   `com.ericandrechek.pacer`).
3. Click the "Register LaunchAgent" button in Debug to invoke
   `SMAppService.agent.register()`.
4. Approve in System Settings → Login Items & Extensions when
   prompted.
5. Quit + relaunch Pacer.app several times.
6. Inspect:
   - `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db
     "SELECT length(csreq) FROM access WHERE
     client='com.ericandrechek.pacer';"` — should be ≥160.
   - `log show --predicate 'process == "tccd"' --info --last 5m |
     grep -E 'AUTHREQ_PROMPTING.*com.ericandrechek.pacer'` — should
     be empty after the first Allow click.
   - System Settings → Privacy & Security → App Management — Pacer
     should appear with toggle.

**If the test passes:** ship. The dev-time prompt is acceptable
friction; document in release notes if needed.

**If the test fails:** apply one of the architectural fallbacks below.

## Architectural Fallbacks (If End Users Are Affected)

In priority order, lowest-risk first.

### Option A — Move daemon under SMAppService for both dev and prod

Make `make install` use SMAppService.agent.register() instead of
`launchctl bootstrap`. Forces user approval through System Settings
on every dev install, but removes the split-identity issue if the
hypothesis above holds.

Drawback: every `make install` would require the user to click
through a System Settings approval dialog, which is the friction the
project explicitly avoided.

Mitigation: cache the approved state, only re-approve when
SMAppService says `requiresApproval`.

### Option B — Replace the daemon with an XPC service

Move the scan/persist logic into an XPC service hosted at
`Pacer.app/Contents/XPCServices/PacerDaemon.xpc`. XPC helpers
definitively inherit the parent app's TCC identity and run on
demand under the app's lifecycle.

Drawback: largest refactor. The daemon's continuous background
scanning model would have to be re-thought (XPC services are launched
on demand and not kept alive forever). Could mitigate by having the
App keep a connection open while running, but background scanning
without the App running becomes tricky.

This is the architecturally cleanest answer if shipping users are
affected and SMAppService doesn't help.

### Option C — Keep LaunchAgent, route container access through the App

The daemon stays a LaunchAgent but stops touching the App Group
container directly. Instead, the daemon connects to an XPC interface
hosted by the App, and the App is the sole accessor of the container.

Drawback: the App must be running for any data to be persisted. The
whole point of the daemon is collecting data while the App is
closed. Could be made to work with a "headless" agent app that runs
in the background without UI, but at that point Option A or B is
cleaner.

## Reference Material

- AGENTS.md "Real-run bug #6" — terse version of this doc, lives next
  to the code so it's encountered during normal work.
- AGENTS.md "Real-run bug #5" — the daemon-side fix from Stage 1.
- `bin/dev-install.sh` — current sign + notarize + staple flow.
- `App/Pacer.entitlements`, `Daemon/PacerDaemon.entitlements` —
  entitlement files with explanatory comments about each key.
- `project.yml` — `OTHER_CODE_SIGN_FLAGS` daemon identifier override
  + `CODE_SIGNING_ALLOWED=NO` to defer signing to the install script.
- Apple TCC schema: `~/Library/Application Support/com.apple.TCC/TCC.db`
  (read access requires Full Disk Access TCC; user has approved this
  for the running shell).
- Container metadata: `~/Library/Group Containers/group.com.ericandrechek.pacer/.com.apple.containermanagerd.metadata.plist`.

## Diagnostic Recipe (For The Next Session)

If the next session needs to re-verify the current state:

```bash
# 1. Confirm signing
codesign -dvv /Applications/Pacer.app | grep -E "Authority|TeamIdentifier"
codesign -dvv /Applications/Pacer.app/Contents/Library/LaunchServices/PacerDaemon | grep "Identifier="

# 2. Confirm notarization
xcrun stapler validate /Applications/Pacer.app
spctl -av /Applications/Pacer.app

# 3. Inspect TCC state
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value, length(csreq), datetime(last_modified, 'unixepoch', 'localtime')
   FROM access
   WHERE client LIKE '%pacer%' OR client LIKE '%ericandrechek%';"

# 4. Watch a real user launch
osascript -e 'tell application "Pacer" to quit'
sleep 2
tccutil reset SystemPolicyAppData com.ericandrechek.pacer
open /Applications/Pacer.app
sleep 4
log show --predicate 'process == "tccd"' --info --last 30s 2>&1 \
  | grep -E "AUTHREQ_PROMPTING|Session scoped|matchesCodeRequirement.*pacer"

# 5. Container metadata sanity
plutil -p ~/Library/Group\ Containers/group.com.ericandrechek.pacer/.com.apple.containermanagerd.metadata.plist \
  | grep Creator
```

Anything that doesn't match the documented "final state" is a
regression.
