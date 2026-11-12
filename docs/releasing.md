# Releasing Pacer

This doc covers cutting a release and the one-time setup behind it.
The release pipeline lives in
[`.github/workflows/release.yml`](../.github/workflows/release.yml) —
tag-driven, GitHub-Actions-hosted, no local steps once the secrets are
in place.

## The fast path: `bin/ship.sh`

Most of a release is plumbing you shouldn't babysit. [`bin/ship.sh`](../bin/ship.sh)
does the mechanical parts and exits non-zero the moment something's off:

```sh
bin/ship.sh preflight            # on main? clean? synced? → suggested next version
bin/ship.sh notes <version>      # preview the exact notes CI will publish
bin/ship.sh release <version>    # tag → watch the Release run → verify (backgroundable)
bin/ship.sh verify <version>     # health-check a published release any time
```

`release` blocks until the workflow finishes and then runs `verify`, which
checks the whole chain end to end: the GitHub Release has the DMG asset, the
live appcast advertises the version, its `<enclosure>` length matches the
published asset, and — if `uv` is available — the DMG's EdDSA signature
validates against the app's embedded `SUPublicEDKey`. For every delta update
the item advertises, it checks the delta is a release asset of its stated
length and that its signature validates too. Run `release` / `wait-ci`
backgrounded so nothing has to poll them.

> **Agent note.** A Claude Code skill, [`/ship`](../.claude/skills/ship/SKILL.md),
> wraps this with the project's release *protocol*: work on branches, install
> locally first, then a **single** approval gate (version bump + notes) before
> anything is pushed/merged/tagged; after approval it lands the PR, converges
> branches, and runs `bin/ship.sh release` autonomously. It never drives your
> GUI to confirm the Sparkle update — the headless signature check stands in.

## Cutting a release (steady state, under the hood)

The steps `bin/ship.sh` automates, spelled out:

1. Land your changes on `main`. `CI` (PacerCore tests + verify build)
   should be green.
1b. If any UI changed this cycle, regenerate the README screenshots so the
   published assets match the shipping version: run the README screenshots
   workflow — it runs when a PR is marked ready, or by hand with
   `gh workflow run screenshots.yml --ref <branch>` — and land its commit. See
   [`docs/screenshots.md`](screenshots.md).
2. Decide the version number. Pacer pre-1.0 uses `0.<minor>.<patch>`
   semver-ish. Breaking changes that need a clean SwiftData reset bump
   the minor; bug fixes / additive UX bumps the patch.
3. Tag and push:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

4. Watch the `Release` workflow. It will:
   - Build a Release-config app.
   - Sign with Developer ID, embed the Hardened Runtime entitlements.
   - Package as a styled DMG with a drag-to-Applications affordance.
   - Sign the DMG, notarize it (one submission; Apple tickets the app inside
     too) and staple it, then check the app inside assesses as notarized.
   - Sign the Sparkle update with the EdDSA private key.
   - Build a delta update from each of the last three releases, prove each
     one rebuilds the new app exactly, and sign the ones that pass
     ([Delta updates](#delta-updates) below).
   - Publish the DMG and the deltas as assets on a GitHub Release named `vX.Y.Z`.
   - Append the new item to `appcast.xml` on the `gh-pages` branch, with the
     deltas in its `<sparkle:deltas>`.

   The Homebrew cask (`brew install --cask ericandrechek/tap/pacer`) is not
   touched by this workflow, and Pacer holds no key to the tap.
   [EricAndrechek/homebrew-tap](https://github.com/EricAndrechek/homebrew-tap)
   pins new releases itself: its `autobump` workflow finds the version with
   the cask's `livecheck`, and pins it only once the DMG proves to be signed
   by team `YZXWMJ5VBY`, notarized and stapled, and newer than the current
   pin. It runs every six hours, and the `Homebrew tap` workflow here asks it
   to run as soon as `Release` succeeds for a tag (using
   `HOMEBREW_TAP_TRIGGER_TOKEN`, which can only start the tap's workflows).
   `bin/ship.sh verify` waits up to ten minutes for the cask to follow and
   warns if it doesn't. To nudge it by hand:
   `gh workflow run autobump.yml -R EricAndrechek/homebrew-tap -f cask=pacer`.

5. Within ~24h, every installed Pacer instance will see the new
   release on its next launch (or on-demand via Pacer → "Check for
   Updates…"). Sparkle handles the download / replace / relaunch.

## Delta updates

A full update is the whole ~158 MB DMG, and most of it is the bundled forecast
networks, which rarely change. A Sparkle *delta* is a binary patch from one
release's app to the next: 0.8.2 → 0.8.3 is 6.5 MB. Sparkle picks the delta
whose `sparkle:deltaFrom` is the build the Mac has installed, and anyone it
doesn't fit (an older version, a modified app) gets the full DMG as before.

### How a release builds them

The `Build Sparkle delta updates` step runs
[`bin/sparkle-deltas.sh`](../bin/sparkle-deltas.sh) after the DMG is notarized.
For each of the last three published releases it:

1. downloads that release's DMG and copies its app out (read-only mount);
2. runs `BinaryDelta create` old → new, in the delta format the *old* app's
   Sparkle can apply (it is the old app's Sparkle that applies it);
3. **proves it:** `BinaryDelta apply` to a fresh copy of the old app (the same
   `applyBinaryDelta()` the installer runs: `Autoupdate/SUBinaryDeltaApply.m`),
   then requires the result to match the new app file for file (path, type,
   permissions, sha256, symlink targets, extended attributes), to pass
   `codesign --verify --deep --strict` with the team's signature, and to
   assess as notarized;
4. only then signs it with the EdDSA key and checks the signature against
   the `SUPublicEDKey` inside the *old* app, the key its Sparkle will check
   it with.

A delta that fails any step is left out with the reason in the log and the
job summary; the release still ships, with the full DMG for everyone. Passing
deltas are uploaded with the DMG, and the appcast step
([`bin/appcast-add-item.py`](../bin/appcast-add-item.py)) only names a delta
that is an asset of the release at exactly its stated length. If the item
with deltas would not validate, it writes the item without them.

Why our own check when BinaryDelta checks too: its format 4 tree hash is a
CRC32, and Sparkle has no fallback for one case (below), so nothing is
published that we have not applied and validated ourselves.

### What a client does when a delta goes wrong

From Sparkle's source (2.10.1, the version 0.8.1–0.8.3 ship):

- **Delta download fails** (missing asset, network): falls back to the full
  DMG. `SPUCoreBasedUpdateDriver.m`, `-downloadDriverDidFailToDownloadFileWithError:`
  → `-fallBackAndDownloadRegularUpdate`.
- **Delta signature fails, or it does not apply** (the installed app differs
  from the release it was made from, a hash check fails): the installer
  reports `SPUArchiveExtractionFailed`, and for a delta the updater falls back
  to the full DMG. `Autoupdate/AppInstaller.m` `-extractAndInstallUpdate` /
  `-unarchiverDidFailWithError:` → `SPUInstallerDriver.m` →
  `SPUCoreBasedUpdateDriver.m` `-installerDidFailToApplyDeltaUpdate`.
- **Delta applies, but the app it built fails validation** (its code
  signature): **no fallback.** `AppInstaller.m` exits with "Update validation
  was a failure" and the update fails, on every check, for every Mac on that
  version, until the delta is removed from the appcast. This is the case
  step 3 above exists for: we apply every delta and run the same codesign
  check before publishing. If it ever happens anyway, roll back (below).
- A Mac whose Sparkle.framework was altered (an architecture or localizations
  stripped) skips the delta up front: the enclosure's
  `sparkle:deltaFromSparkleExecutableSize` / `sparkle:deltaFromSparkleLocales`
  (`SUAppcastDriver.m`, `-preferredUpdateForRegularAppcastItem:`).

### Turning them off

No code change: set the repository variable, and the next release ships as it
did before deltas (one DMG, one `<enclosure>`):

```sh
gh variable set PACER_SPARKLE_DELTAS --body off -R EricAndrechek/Pacer   # off
gh variable delete PACER_SPARKLE_DELTAS -R EricAndrechek/Pacer           # back on
```

A manual run takes `-f deltas=off` too.

### Testing them, publishing nothing

**In CI, with the real keys.** A manual run of the Release workflow never
publishes (the release and appcast steps only run on a tag push). On a manual
run the delta step is strict: deltas from the last three releases to the
run's build must all build, apply, match, pass codesign and notarization
assessment, and sign and verify against the old apps' keys, or the run
fails. A last step adds the item to a copy of the live appcast with the same
script, applies the undo to it, and requires the delta-less item back byte
for byte; the item is in the job summary.

```sh
gh workflow run release.yml --ref <branch> -f dry_run=true
gh run watch "$(gh run list --workflow=Release --limit 1 --json databaseId --jq '.[0].databaseId')"
```

**On a Mac, with a throwaway key.** The release key is never needed and never
read: `sparkle-eddsa.swift keygen` makes a test key outside the Keychain.

```sh
T="$(mktemp -d)"
swift bin/sparkle-eddsa.swift keygen "$T/test.key"
gh release download v0.8.3 -R EricAndrechek/Pacer --pattern 'Pacer-0.8.3.dmg' --dir "$T"
bin/sparkle-deltas.sh --new "$T/Pacer-0.8.3.dmg" --out "$T/out" --from 0.8.2,0.8.1 \
  --key-file "$T/test.key" --public-key "$(swift bin/sparkle-eddsa.swift pubkey "$T/test.key")" \
  --strict          # add --sparkle-bin <dir> if Sparkle isn't resolved under build/ or Build/
cat "$T/out/summary.md" "$T/out/deltas.xml"
rm -rf "$T"
```

It never launches an app and nothing appears on screen. There is no
on-machine end-to-end run of a Sparkle client: any Sparkle client updating a
copy of Pacer keeps its state in Pacer's own defaults domain
(`com.ericandrechek.pacer`, `SUHost.m -initWithBundle:`), shares the running
app's installer service name (`SPUInstallerDriver.m`), and touches the
installed copy so LaunchServices notices it (`SUFileManager.m`), which can
register a second Pacer, widget included, beside the real one. Launching an
old Pacer to update itself would open the shared store and the dashboard. A
client run belongs on a disposable machine.

### Rolling back delta updates

In order of how fast they act. None of them needs a new build.

1. **Stop new releases from carrying deltas:** set `PACER_SPARKLE_DELTAS=off`
   (above).
2. **Take a release's deltas out of the live appcast.** Clients read the feed
   on every check, so this is the real undo. Do it when no Release run is in
   progress (`gh run list --workflow=Release --limit 1`), because it pushes to
   the same branch the appcast step does. The script refuses to write unless
   the only change is the removed `<sparkle:deltas>` blocks: every item and
   full `<enclosure>` stays byte for byte.

   ```sh
   git fetch origin gh-pages
   GHP="$(mktemp -d)/gh-pages"
   git worktree add --detach "$GHP" origin/gh-pages
   bin/appcast-drop-deltas.sh 0.8.4 "$GHP/appcast.xml"      # or: all
   git -C "$GHP" diff                                      # review: only <sparkle:deltas> lines go
   git -C "$GHP" commit -am "appcast: drop delta updates for 0.8.4"
   git -C "$GHP" push origin HEAD:gh-pages                 # the publish; needs the owner's go
   git worktree remove "$GHP"
   ```

   Then confirm what clients get. Pages serves the commit within a minute or
   two, and its CDN may hold the old feed for up to ten minutes more:

   ```sh
   curl -fsSL https://ericandrechek.github.io/Pacer/appcast.xml | grep -c '<sparkle:deltas>'
   bin/ship.sh verify 0.8.4                                # "no delta updates in this item"
   ```

3. **Optionally delete the delta assets**, after step 2 is live:

   ```sh
   gh release view v0.8.4 --json assets --jq '.assets[].name' | grep '\.delta$'
   gh release delete-asset v0.8.4 Pacer-0.8.4-from-0.8.3.delta --yes
   ```

   Deleting them *before* the feed changes also works as an emergency stop,
   because a delta that fails to download falls back to the full DMG
   (above). It leaves the feed naming missing files, so follow it with step 2.

A delta can only reach Macs on the release it was made from, and a failed
one falls back to the full DMG in every case but the one above. The full
`<enclosure>` of each release is never touched by any of this.

## One-time setup

You only need to do this section before the **first** release.

### 1. Apple Developer signing

You already have a Developer ID Application certificate (Team ID
`YZXWMJ5VBY`). For CI to use it, export it as a `.p12`:

1. Open **Keychain Access**.
2. Find `Developer ID Application: Eric Andrechek (YZXWMJ5VBY)`
   under the *login* keychain → My Certificates.
3. Right-click → Export → save as `pacer-signing.p12` with a
   strong password.
4. Base64-encode it for transit:

   ```sh
   base64 -i pacer-signing.p12 | pbcopy
   ```

5. Paste into the `MACOS_CERTIFICATE` secret (see below).
   The password from step 3 goes into `MACOS_CERTIFICATE_PASSWORD`.

### 2. App Store Connect API key (for notarization)

> **Local `make install` note.** Notarizing locally needs a `notarytool`
> keychain profile named `pacer-notarization` in your login Keychain —
> a *different* thing from the CI secrets below, and not a file in
> `keys/`. It goes missing on a fresh machine or after a Keychain reset
> even when `keys/` is complete. `bin/dev-install.sh` self-heals it: when
> the profile is absent but `keys/.env` + `keys/AuthKey_*.p8` are present,
> it recreates it via `xcrun notarytool store-credentials` on the next
> install. (Or skip notarization for fast iteration:
> `PACER_DEV_SKIP_NOTARIZE=1 make install`.)

The local `pacer-notarization` keychain profile won't work in CI.
Use an API key instead:

1. App Store Connect → Users and Access → Integrations →
   App Store Connect API.
2. Create a new key with the `Developer` role.
3. Download the `.p8` file **immediately** — it's only offered once.
4. Note the **Key ID** (visible in the table) and the **Issuer ID**
   (top of the page).

The full contents of the `.p8` file (including the
`-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines)
go into `NOTARY_KEY_P8`. The Key ID → `NOTARY_KEY_ID`. The Issuer ID
→ `NOTARY_ISSUER_ID`.

### 3. Sparkle EdDSA keypair

Sparkle 2.x signs updates with Ed25519 so installed clients can verify
the download. The pubkey is embedded in the app's Info.plist; the
private key signs each release.

1. Resolve the Sparkle SPM package locally once so the tools are
   on disk:

   ```sh
   xcodegen generate
   xcodebuild -resolvePackageDependencies -project Pacer.xcodeproj
   ```

2. Find Sparkle's `generate_keys`:

   ```sh
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path "*/Sparkle*" | head -1
   ```

3. Generate a keypair. The first invocation stores the private key in
   the macOS Keychain and prints the matching public key:

   ```sh
   /path/to/generate_keys
   # → "A new key has been generated and saved in your keychain.
   #     Public key (SUPublicEDKey value): ABCDEF..."
   ```

4. Put the public key into `project.yml`, replacing the
   `PLACEHOLDER_SPARKLE_PUBLIC_KEY_REPLACE_BEFORE_RELEASE` value
   under the `Pacer` target's `info:` → `properties:` → `SUPublicEDKey`.
   Commit + push.

5. Export the private key for CI use:

   ```sh
   /path/to/generate_keys -x sparkle-private.key
   # writes the EdDSA private key in the format `sign_update -f` consumes
   ```

   Paste the contents of `sparkle-private.key` (it's a single line of
   base64-ish text) into the `SPARKLE_ED_PRIVATE_KEY` secret.

   **Then delete the local file** (`shred -u sparkle-private.key` or
   move it to a password manager) — the only copies should be the
   Keychain entry on your Mac (for local re-export if needed) and
   the GitHub Actions secret.

### 4. GitHub Pages (for the appcast)

The Sparkle feed URL declared in `project.yml` is
`https://ericandrechek.github.io/Pacer/appcast.xml`. That serves the
`appcast.xml` at the root of the `gh-pages` branch.

1. Repo Settings → Pages.
2. Source: **Deploy from a branch**.
3. Branch: **gh-pages** / root (`/`).
4. Save.

The first release run creates the `gh-pages` branch with an initial
appcast skeleton; you don't need to bootstrap it manually.

### 5. Set the GitHub Actions secrets

The repo was pre-populated with the three secrets that don't depend on
your local cert/Apple-account state:

| Secret name | Pre-set? | Value source |
| --- | --- | --- |
| `APPLE_TEAM_ID` | ✓ already set | `YZXWMJ5VBY` |
| `KEYCHAIN_PASSWORD` | ✓ already set | auto-generated random string (only used to unlock the ephemeral CI keychain) |
| `SPARKLE_ED_PRIVATE_KEY` | ✓ already set | exported from your Keychain via `generate_keys -x` |
| `MACOS_CERTIFICATE` | needs you | base64 of the `.p12` from step 1 |
| `MACOS_CERTIFICATE_PASSWORD` | needs you | the password used to export the `.p12` |
| `NOTARY_KEY_ID` | needs you | from step 2 |
| `NOTARY_ISSUER_ID` | needs you | from step 2 |
| `NOTARY_KEY_P8` | needs you | the full contents of the `.p8` file from step 2 |
| `SENTRY_AUTH_TOKEN` | optional | a Sentry organization token (Settings → Auth Tokens). Lets `release.yml` upload dSYMs and register the release so crash reports are symbolicated; without it the step is skipped and the release still ships |
| `HOMEBREW_TAP_TRIGGER_TOKEN` | needs you | fine-grained personal access token: repository access *only* `EricAndrechek/homebrew-tap`, permission *Actions: Read and write*, nothing else. It can only start the tap's workflows; it cannot write to the tap. Used by `.github/workflows/homebrew-tap.yml`; without it the tap still follows on its six-hourly schedule. Rotate before it expires: generate a new one the same way, `gh secret set HOMEBREW_TAP_TRIGGER_TOKEN -R EricAndrechek/Pacer`, then delete the old token. |

The fastest way to set the five remaining secrets is the
[`bin/setup-release-secrets.sh`](../bin/setup-release-secrets.sh)
helper:

```sh
bin/setup-release-secrets.sh
```

It walks you through the .p12 path + password and the App Store Connect
.p8 + Key ID + Issuer ID and uses `gh secret set` to upload each, so
the values never go through the GitHub web UI's text input and never
hit your shell history (the password prompt uses `read -s`).

If you prefer the web UI, **Settings → Secrets and variables → Actions
→ New repository secret** is the manual equivalent for each one.

### 6. Smoke-test with workflow_dispatch

Before tagging the first real release, manually run the workflow with
`dry_run: true`:

1. Actions → Release → Run workflow.
2. Set `dry_run` to `true`. Click Run.

This exercises every step (signing, notarization, DMG, Sparkle sign,
delta updates, strictly) *except* publishing the GitHub Release and pushing
to gh-pages, so a broken secret surfaces without polluting the release feed.
A manual run never publishes, whatever `dry_run` says.

When it goes green, you're ready to tag.

## Failure modes worth recognizing

- **`Developer ID Application: Eric Andrechek (XXXXXXXX)` not found** —
  the `MACOS_CERTIFICATE` secret is malformed (likely a bad base64
  paste) or the `.p12` doesn't actually contain the Developer ID
  cert. Re-export and re-encode.
- **Notarization `status: Invalid`** — fetch the log line that the
  workflow prints with `xcrun notarytool log`. Most common cause:
  a binary inside the bundle wasn't signed with Hardened Runtime
  (`--options runtime`). The release workflow signs all known
  components but if you add a new bundled tool, update the signing
  loop in `release.yml`.
- **`Apple still processing (dmg)`** — Apple's notary queue
  didn't answer within `NOTARY_WAIT` (75 min) in `bin/ci-notarize.sh`. It's
  not a rejection, and it happens: 49 min for the app on 2026-10-06 (#189).
  Every submission ID is on the run page (a notice annotation and the job
  summary's Notarization table). Check one with
  `xcrun notarytool info <id> --keychain-profile pacer-notarization`; the
  profile sees CI's submissions because it's the same team. Don't
  resubmit by hand: once Apple is answering again, re-run the failed job,
  which builds and submits afresh. A stapled ticket only fits the exact
  binary it was issued for.
- **Sparkle update not detected** — check `appcast.xml` on the
  `gh-pages` branch: it must list a `sparkle:version` greater than
  what's installed. Sparkle compares `CFBundleVersion` (which the
  workflow stamps with a unix timestamp), so version comparisons
  are strictly monotonic per release run.
- **`no delta from X` warning on a release** — that delta failed a check and
  was left out (the reason is in the log and the job summary); Macs on X get
  the full DMG. Nothing to fix for the release itself. A warning that the
  script exited non-zero means no deltas at all for that release.
- **Macs on one version stuck failing to update after a release** — check
  Sentry/PostHog update outcomes for that version, then roll back that
  release's deltas ([Rolling back delta updates](#rolling-back-delta-updates)).
- **`SUPublicEDKey` mismatch after rotating the keypair** — clients
  installed against the old public key will refuse the new signature
  and you'll have to publish a one-off "manual download" build to
  shepherd them over. Don't rotate the EdDSA keys casually; treat
  the private key the same way you'd treat a code-signing cert.

## Release-cadence notes

- `Release` workflow's `concurrency: release` group is intentionally
  `cancel-in-progress: false` — if two tags land back-to-back they
  serialize cleanly instead of one stomping the other's appcast push.
- `appcast.xml` only ever grows. If you publish a bad release, tag a
  new patch and let users update past it; don't try to delete items. The
  one sanctioned edit is removing a release's `<sparkle:deltas>` block with
  `bin/appcast-drop-deltas.sh`, which leaves every item and full
  `<enclosure>` as it was.
