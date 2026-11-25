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
bin/ship.sh preflight            # on main? clean? synced? feed live? → suggested next version
bin/ship.sh notes <version>      # preview the exact notes CI will publish
bin/ship.sh release <version>    # tag → watch the Release run → verify (backgroundable)
bin/ship.sh verify <version>     # health-check a published release any time
bin/ship.sh feeds                # is the update feed live where a release will write it?
```

`preflight`, and `release` again just before it tags, fail unless the update
feed is where the release will write it and live: the app's `SUFeedURL` is
`https://pacer.andrechek.com/appcast.xml`, the site serves main's
`site/public/appcast.xml` and `price-history.json` byte for byte, the newest
Workers Builds check on `main`'s site commit succeeded (a failed site build
leaves the old deployment serving, and would also swallow the release's feed
commit), and, while the [legacy mirror](#the-legacy-github-pages-mirror) is
on, gh-pages holds the same bytes. `SHIP_SKIP_SITE_BUILD_CHECK=1` skips only
the Workers Builds check, loudly, for the case where Cloudflare reports no
check runs at all.

`release` blocks until the workflow finishes and then runs `verify`, which
checks the whole chain end to end: the GitHub Release has the DMG asset; the
site's appcast (`https://pacer.andrechek.com/appcast.xml`, what 0.9.4 and later
read) advertises the version, waiting up to 15 minutes for Workers Builds to
deploy it; while the mirror is on, the GitHub Pages copy (what 0.9.3 and
earlier read) is byte-identical to it, and so is `price-history.json`; the
price history served decodes and is no older than the release's; the item's
`<enclosure>` length matches the published asset, and — if `uv` is available —
the DMG's EdDSA signature validates against the app's embedded
`SUPublicEDKey`. For every delta update the item advertises, it checks the
delta is a release asset of its stated length and that its signature
validates too. Run `release` / `wait-ci` backgrounded so nothing has to poll
them.

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
   semver-ish. A schema change bumps the minor; bug fixes / additive UX
   bump the patch. Nothing resets the store: a changed schema is migrated in
   place on the first launch, from whatever release the Mac had, so a release
   that touches the schema or a one-time upgrade runs `make upgrade-matrix`
   first ([Skipped releases](#skipped-releases-the-upgrade-matrix) below).
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
   - Build a delta update from each of the last five releases, prove each
     one rebuilds the new app exactly, and sign the ones that pass
     ([Delta updates](#delta-updates) below).
   - Publish the DMG and the deltas as assets on a GitHub Release named `vX.Y.Z`.
   - Publish the update feed ([The update feed](#the-update-feed) below): add
     the new item, with the deltas in its `<sparkle:deltas>`, to
     `site/public/appcast.xml` on `main`, with the release's
     `price-history.json` beside it; Cloudflare Workers Builds deploys that to
     `https://pacer.andrechek.com/`. The same two files go, byte for byte, to
     the root of `gh-pages`, the legacy mirror older Pacers read.

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

## The update feed

Every installed Pacer finds its updates in one file, and only an update can
change which file that is. A Pacer pointed at a feed that stops getting
releases is stranded for good. So the feed has exactly one source of truth,
and the release that writes it also checks it is being served.

| | Site copy (primary) | Legacy mirror |
| --- | --- | --- |
| Source | `site/public/appcast.xml`, `site/public/price-history.json` on `main` | `appcast.xml`, `price-history.json` at the root of `gh-pages` |
| Served at | `https://pacer.andrechek.com/appcast.xml` (static files of the Cloudflare site; no Worker code runs for them) | `https://ericandrechek.github.io/Pacer/appcast.xml` (GitHub Pages) |
| Read by | Pacer 0.9.4 and later (`SUFeedURL`, `CuratedPriceHistory.remoteURL`) | Pacer 0.9.3 and earlier |
| Written by | the release workflow, and reviewed hand edits | a copy of the site copy, never edited on its own |

### The fallback source

If the site cannot be read, Pacer 0.9.5 and later read
`https://raw.githubusercontent.com/EricAndrechek/Pacer/main/site/public/appcast.xml`
and `.../price-history.json`: the files the site deploys from, so byte-identical
once deployed, and nothing extra to publish. Not the `gh-pages` mirror, which is
frozen. The appcast moves to it for one check after a failed one (EdDSA signatures,
not hosts, are trusted); `X-Pacer-*` headers never go there; each failure is a
Sentry problem at most once a day (`docs/telemetry-plan.md`, "Feed fallbacks").
Never rename or move those paths on `main` without a migration plan.

Two more things keep Macs current (`UpdateRetryPolicy`, `App/Update/PacerUpdater.swift`):
a failed update download (`updater(_:failedToDownloadUpdate:error:)`) schedules a
background re-check after 30 minutes, then 2 hours, then leaves it to the 6-hour
interval (reset when an update gets to install), and reports "update download
failed" (`feed=update_archive`, same once-a-day limit); and a launch whose
`CFBundleVersion` differs from the previous launch's (Pacer just updated) runs
`checkForUpdatesInBackground()` once, two minutes later, so a Mac that installed an
older held update finds the newest quickly.

### How a release publishes it

The `Publish the update feed` step runs `bin/publish-feeds.sh release`
([`bin/publish-feeds.sh`](../bin/publish-feeds.sh)):

1. a worktree of `origin/main`; the release's item goes into
   `site/public/appcast.xml` ([`bin/appcast-add-item.py`](../bin/appcast-add-item.py),
   which checks the whole feed still parses with the item intact), and the
   tag's `price-history.json` replaces the one beside it (the site's is kept
   only when it is strictly newer by `asOf`, or the tag's would not decode);
2. the site's own deploy check (`site/scripts/check-feeds.mjs`) runs on the
   result, so a copy Workers Builds would refuse never reaches `main`;
3. the commit `site: publish appcast and price history for X.Y.Z` is pushed to
   `main` as `github-actions[bot]`. If `main` moved meanwhile, the push is
   redone on the new `main` (fetch, regenerate from its copy, commit, push), up
   to five times. Workers Builds builds `main` (its watch paths include
   `site/*`), runs `pnpm build:ci`, and deploys in a minute or three. The
   commit must never carry `[skip ci]`: Workers Builds honours it;
4. while the mirror is on, the same two files are copied to `gh-pages` and
   pushed as `appcast: X.Y.Z`, after the site's check and an XML/JSON parse
   pass on them. If the site's check refused the copy in step 2, the mirror
   gets nothing either: it fails closed;
5. the step fails, after trying both, unless both copies were published and
   are byte-identical. The job summary has a table saying which is where;
6. the next step, `Wait for the site to serve the new feed`, polls
   `https://pacer.andrechek.com/appcast.xml` (with a cache-busting query) until
   it advertises the version, and fails the run with an annotation saying what
   to check after 15 minutes. A green run means 0.9.4+ Macs can see the
   release.

A re-run for a release already in the feed adds nothing. A manual
(`workflow_dispatch`) run never publishes: it previews the item against
`main`'s copy and runs the same script with `--no-push`, requiring the two
copies it would push to be identical. `bin/publish-feeds.sh self-test` (in
CI) runs the whole path against a throwaway local remote.

**The deploy gate.** `pnpm build` ends with `scripts/check-feeds.mjs`, which
fails the build, so Workers Builds keeps the deployment that is live, when
either file is missing, differs from `site/public/`, or is not fit to serve: an
appcast that is not well-formed (a stray `<`, a bare `&`, an attribute given
twice, unclosed tags), not an `<rss>`, or has an item without a build, a
version, a DMG on Pacer's releases, a length and an EdDSA signature (deltas
likewise), or a price history the app would not decode. A broken copy on
`main` therefore means *no new deploy*, never a broken feed, and `verify`
reports it as the feed not advertising the release. It also blocks every later
deploy, the next release's feed included, until it is fixed; `bin/ship.sh
preflight` fails while the site does not serve `main`'s copy, so a release is
never tagged into that state.

### When the site's feed did not update

`verify` says `https://pacer.andrechek.com/appcast.xml does not advertise
X.Y.Z`. Macs on 0.9.4 and later do not see the release until it does; the
mirror still serves 0.9.3 and earlier.

1. Find the build of the release commit (`site: publish appcast … X.Y.Z`) in
   Cloudflare: Workers & Pages → pacer → Deployments (and its build log).
2. A failed build: read its log. A failed `check-feeds` names the file and the
   problem; a test or a flaky install is fixed or retried in the dashboard
   ("Retry build"). Fix forward on `main` (a PR touching `site/` deploys on
   merge); never hand-edit the live Worker.
3. No build at all: check the Workers Builds connection and its watch paths
   (`site/*`, `docs/release-notes/*`, `docs/screenshots/*`), then retry the
   latest `main` build from the dashboard, or start one by hand:
   `cf builds create pacer --branch main`.
4. Then `bin/ship.sh verify X.Y.Z` again.

If the publish step itself failed, its log and job summary say which copy
did not publish:

- **`the site copy on main was NOT published`, mirror published:** the mirror
  is main's copy plus the new item, so put it on `main`: in a worktree of
  `origin/main` ([Editing the feed by hand](#editing-the-feed-by-hand)),
  `git show origin/gh-pages:appcast.xml > site/public/appcast.xml` and the
  same for `price-history.json`, check `git diff` adds only the new `<item>`,
  commit, push.
- **mirror not published, site published:** `bin/publish-feeds.sh mirror`.
- **neither:** re-run the Release workflow's failed job. Do this only then: a
  re-run rebuilds and re-uploads the DMG with a new build number, which is
  harmless only while no feed names the first one. The script adds an item
  once per version and build.

### Editing the feed by hand

Pulling a release and dropping deltas are the only hand edits. Make them on
`main`'s copy, then copy it to the mirror, and do neither while a Release run
is in progress (`gh run list --workflow=Release --limit 1`):

```sh
git fetch origin main
W="$(mktemp -d)/site"
git worktree add --detach "$W" origin/main
# edit "$W/site/public/appcast.xml" (or run bin/appcast-drop-deltas.sh on it)
git -C "$W" diff                                         # review
git -C "$W" commit -am "site: <what and why>"
git -C "$W" push origin HEAD:main                        # the publish; needs the owner's go
git worktree remove "$W"
bin/publish-feeds.sh mirror                              # gh-pages becomes the same bytes
bin/publish-feeds.sh status                              # "byte-identical" for both files
```

Workers Builds deploys the `main` commit; check it with `curl -fsSL
https://pacer.andrechek.com/appcast.xml` (served within a minute of the
deploy; clients may cache it for a minute, `max-age=60`). `mirror` refuses to
run until the site serves `main`'s copies byte for byte, so run it once the
deploy is done; it also refuses a copy that fails the site's check or does
not parse.

### The legacy GitHub Pages mirror

Pacer 0.9.3 and earlier read only `https://ericandrechek.github.io/Pacer/appcast.xml`,
so every release also writes the same bytes there, behind the repository
variable `PACER_LEGACY_PAGES_MIRROR` (on by default; `off`, `false` or `0`, any
case, turns it off):

```sh
gh variable set PACER_LEGACY_PAGES_MIRROR --body off -R EricAndrechek/Pacer   # off: gh-pages frozen
gh variable delete PACER_LEGACY_PAGES_MIRROR -R EricAndrechek/Pacer           # back on
```

A Mac on 0.9.3 updates from the mirror to the newest release there, which reads
the site's feed from then on, so any mirrored release from 0.9.4 on moves a Mac
over for good. Only a copy that passed the site's own check is ever mirrored
(`bin/publish-feeds.sh`: a release fails closed, and `mirror` also waits until
the site serves the copy).

**Retiring it: turn it off and freeze gh-pages. Never delete it.** No count can
prove that no Pacer below 0.9.4 is left: PostHog only hears from Macs that keep
usage data on, and a Mac that is rarely switched on still has to come back for
its update. A frozen mirror costs nothing and keeps moving every straggler
over; a deleted one strands them for good.

1. Wait until the 0.9.3-and-earlier share of PostHog's daily check-ins is
   negligible, over several weeks, and the mirror's newest item is a release
   from 0.9.4 on that is not pulled (so a straggler lands on a build that reads
   the site).
2. Turn the mirror off (`PACER_LEGACY_PAGES_MIRROR=off`). gh-pages stays frozen
   at the last release it mirrored, permanently, and GitHub Pages stays on.
3. Leave the mirror code in place: `bin/publish-feeds.sh mirror` is still how a
   pulled release comes out of the frozen copy (below).

A pulled release has to come out of the mirror too (`bin/publish-feeds.sh
mirror` after the edit on `main` has deployed), even when it is off: run that
once with `PACER_LEGACY_PAGES_MIRROR=on` set in the shell, or the frozen mirror
keeps offering what was pulled. Check its newest item is still a release from
0.9.4 on afterwards.

## Skipped releases: the upgrade matrix

A Mac that is several releases behind does not step through them. Sparkle
reads the whole appcast and offers the newest item it may install
(`SUAppcastDriver.m` `bestItemFromAppcastItems`, 2.10.1): a Mac on 0.9.0 when
0.9.5 ships downloads 0.9.5 and installs it, once. It takes the delta whose
`sparkle:deltaFrom` is its own `CFBundleVersion` when the newest release has
one (the last five releases do), and the full DMG otherwise or if the delta
fails. The one exception is an update already downloaded and waiting: Sparkle
resumes that one before it reads the feed again (`SPUUpdater.m`, the
`resumableUpdate` branch), so that Mac installs it and then, on its next
check, the newest. 0.8.3 and later install a waiting update at the next idle
moment (`UpdateInstallScheduler`, within a day, three at most), so the gap is
hours, not a second update cycle; 0.8.0–0.8.2 hold it until Pacer quits.

So 0.9.0's store meets 0.9.5's code directly, and every migration has to
compose across any gap:

- **The SwiftData schema.** Core Data's lightweight migration infers one
  mapping from the model the store recorded to the current one, in one hop;
  there are no intermediate models. Additive changes (an optional attribute,
  one with a default, a new `@Model` named to sort last, an `#Index`) compose.
  A removed, renamed or retyped attribute, or a new mandatory one with no
  default, needs a `VersionedSchema` + `SchemaMigrationPlan`
  (`PacerStore.makeModelContainer`).
- **One-time upgrades** are written as "stored differs from current: bring it
  to current, then record current" (`ScanCoordinator`'s `current*Version`
  gates, the archive's catalog-checked columns, the defaults flags), never as
  "stored is the previous version". The work they do rebuilds to the current
  rules, so a store several versions back runs each one once.

`make upgrade-matrix` is the evidence, and the gate for any release that
changes what opens, migrates, maintains or archives the store. The trigger is
deliberately wide (a false "needed" costs ten minutes; a false "not needed"
ships an untested migration): any change under `Models/` or `Persistence/`
(`StoreIndexRepair`, `StoreMaintenance`, the dedup index…), to `PacerStore`,
`Heartbeat`, `ScanCoordinator`, `AccountBackfill`/`AccountActivation`,
`App/Archive/`, `StoreLoader` or `Vendor/duckdb-version.txt` (it decides
whether old archives open); or, in any other app source, a code line that
declares a `@Model` (`@MainActor @Model` included), the schema list, a
`current*Version`, `addedColumns`, `layoutDefaultsVersions`, a `migrate`
function or a migration plan, or calls what opens or maintains the store. A
renamed or deleted file is judged by its old name and contents too, and
untracked files count. `bin/upgrade-matrix.sh --needed [<base>]` (default:
the latest release tag) answers it:

| Exit | Means | Do |
| --- | --- | --- |
| 0 | it lists the files and why | run the matrix |
| 1 | nothing touches the store | skip it |
| 2 | it could not tell: no tag fetched, a shallow clone, a base that is not a commit | run the matrix |

```sh
bin/upgrade-matrix.sh --needed; [ $? -ne 1 ] && echo "run the matrix"
mkdir -p /tmp/frozen/projects && cp -c -R ~/.claude/projects/<a few projects> /tmp/frozen/projects/
make upgrade-matrix CLAUDE=/tmp/frozen          # the last five releases
make upgrade-matrix CLAUDE=/tmp/frozen TAGS="v0.8.0 v0.9.2"
make upgrade-matrix CLAUDE=/tmp/frozen STORE=<a copy of a real store>   # e.g. an old backup
```

For each release tag it builds, once, that release's own store: a detached
worktree at the tag, its PacerCore and DuckDB importer with
`UpgradeMatrixProbe`, one full scan of the frozen tree and its raw archive, a
copy with a generic row in every table the scan left empty, and its model as
text. Those are cached outside the repo (`CACHE=`, default
`~/Library/Caches/pacer-upgrade-matrix`), keyed by the tag, the tree and the
probe. Then, with this tree, through `bin/dev-ingest-harness.sh`:

| Column | Passes when |
| --- | --- |
| schema vs HEAD | informational: attributes added; a removed, retyped or new mandatory attribute is a WARN |
| opened, migrated | the seeded copy opens; a changed schema migrates (`needs-migration → current`), an unchanged one does not |
| preserved | every old table and column is still there, with every row and value, and no entity is renumbered (#387); a failed query or an empty sample table fails |
| kept | a first launch with NO transcripts leaves exactly the release's own `TOTALS`, and every sample row (`Z_PK` and dedup key) survives: nothing could be read back, so nothing lost hides |
| totals | after this tree's first launch on the frozen tree, `TOTALS` equals a fresh ingest of it by this tree, and every old sample row still survives (a row re-read from the transcripts has a new `Z_PK`) |
| values | the upgraded store against a reference (this tree's own store, made like the tags' and given the same first launch): every sample by dedup key and every daily, hourly, project and session rollup row by key, in every column (reals to 1e-9), and the `COST` lines. A `thinkingTokens` that is NULL where the reference has one is reported, not failed: releases before 0.8.3 did not read it and it is never backfilled (#362) |
| verify-data | `bin/dev-verify-data.sh` passes on the upgraded store |
| archive | this launch's own archive check: a higher check count than the release's, its `integrity check N: ok` line, and no `disabled after error` (the cached store already holds the release's `ok`) |
| second launch | no migration, an incremental cycle that inserts nothing, no one-time work again, archive still enabled and in agreement, same totals |

and the first launch's time and bytes written (and the migration's alone).
`STORE=` adds a row for a real store copy, where "kept" means unchanged by
the upgrade and an entity renumbering (a store from before 0.8.0, #387) is
reported but is not a failure: it costs writes, not data.
`PACER_MATRIX_SELF_TEST=rows`, `=column` or `=archive` proves the checks bite:
on copies, it drops 100 samples and every file cursor (a migration that lost
rows the transcripts still hold), gives 50 samples another model (a rewritten
column TOTALS does not sum), or overwrites the archive's header (an archive
this tree cannot open). Each must FAIL. A fixture with no transcripts, a tag
that is not an existing `vX.Y.Z` tag, a tag whose store holds no samples or
whose archive sync left no verdict are refused or fail before anything is
compared.
Every step is `swift build`/`swift test` under a sandbox profile that denies
writes to the live App Group container, the app's preferences and all of
`~/.claude`, and denies running `open`, `osascript` or the installed app;
nothing is launched. One run holds a cache at a time, and a failed or
interrupted run removes the worktree and build it was making. The first run spends two to four minutes per tag building its store
(a debug build of that tag and one scan) plus one release build of this tree;
after that, seven tags and a 1.1 GB store copy took about ten minutes.
Results and per-step logs land in `OUT=` (default `$CACHE/results/<tree>`).
A working tree with uncommitted changes is labelled `<HEAD>-dirty-<hash>` in
the results, the summary and the kept builds, so a pass is never mistaken for
the commit's.

## Delta updates

A full update is the whole ~158 MB DMG, and most of it is the bundled forecast
networks, which rarely change. A Sparkle *delta* is a binary patch from one
release's app to the next: 0.8.2 → 0.8.3 is 6.5 MB. Sparkle picks the delta
whose `sparkle:deltaFrom` is the build the Mac has installed, and anyone it
doesn't fit (an older version, a modified app) gets the full DMG as before.

### How a release builds them

The `Build Sparkle delta updates` step runs
[`bin/sparkle-deltas.sh`](../bin/sparkle-deltas.sh) after the DMG is notarized.
For each of the last five published releases it:

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

A manual run takes `-f deltas=off` too. `off`, `false` and `0` all switch them
off, in any case (`OFF`, `False`).

The delta step is bounded (20 minutes) and, on a tag push, tolerated: a failure
or timeout there, a failed delta upload, or a failed asset listing at the
appcast step each leave the release published with the full DMG and an appcast
item that names only the deltas that really are assets. A manual run is strict.

### Testing them, publishing nothing

**In CI, with the real keys.** A manual run of the Release workflow never
publishes (the release and appcast steps only run on a tag push). On a manual
run the delta step is strict: deltas from the last five releases to the
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

### Pulling a bad release

1. **Take its item out of the appcast**, so Sparkle stops offering it: delete
   the `<item>` from `site/public/appcast.xml` on `main`, then copy it to the
   mirror ([Editing the feed by hand](#editing-the-feed-by-hand)). The GitHub
   release can stay. The site's download button
   (`pacer.andrechek.com/download/`) reads the same file, so it stops handing
   the release out with the same deploy, even though GitHub still lists the
   pulled release as latest (`site/worker/lib.ts`).
2. **Check the Homebrew cask: it does not follow the appcast.** The tap pins
   releases itself and only ever moves forward, so it keeps installing the
   pulled version (`gh api repos/EricAndrechek/homebrew-tap/contents/Casks/pacer.rb
   --jq .content | base64 -d | grep version`).
   - A **patch** release (no store migration): pin the cask back with a PR to
     the tap.
   - A **minor** release migrated the store, and the version before it cannot
     open a migrated store. Pinning back would give a brew user who already
     has it a Pacer that can't read their data. Ship the fix as the next
     version instead; the tap moves forward to it.

   0.9.0 (2026-11-13) is the case this is from: the appcast was pulled within
   hours, the cask stayed on 0.9.0 until 0.9.1 shipped.

### Rolling back delta updates

In order of how fast they act. None of them needs a new build.

1. **Stop new releases from carrying deltas:** set `PACER_SPARKLE_DELTAS=off`
   (above).
2. **Take a release's deltas out of the live appcast.** Clients read the feed
   on every check, so this is the real undo. Do it when no Release run is in
   progress (`gh run list --workflow=Release --limit 1`), because it pushes to
   the same branches the publish step does. The script refuses to write unless
   the only change is the removed `<sparkle:deltas>` blocks: every item and
   full `<enclosure>` stays byte for byte. It edits `main`'s copy, and the
   mirror is then made the same bytes:

   ```sh
   git fetch origin main
   W="$(mktemp -d)/site"
   git worktree add --detach "$W" origin/main
   bin/appcast-drop-deltas.sh 0.8.4 "$W/site/public/appcast.xml"   # or: all
   git -C "$W" diff                                      # review: only <sparkle:deltas> lines go
   git -C "$W" commit -am "site: drop delta updates for 0.8.4"
   git -C "$W" push origin HEAD:main                     # the publish; needs the owner's go
   git worktree remove "$W"
   bin/publish-feeds.sh mirror                           # gh-pages: the same bytes (while it exists)
   ```

   Then confirm what clients get. The site serves the commit once Workers
   Builds has deployed it (a minute or three); Pages serves the mirror within
   a minute or two, and its CDN may hold the old copy ten minutes more:

   ```sh
   curl -fsSL https://pacer.andrechek.com/appcast.xml | grep -c '<sparkle:deltas>'
   curl -fsSL https://ericandrechek.github.io/Pacer/appcast.xml | grep -c '<sparkle:deltas>'
   SHIP_ALLOW_NO_DELTAS=1 bin/ship.sh verify 0.8.4         # "no delta updates in this item"
   ```

   Without `SHIP_ALLOW_NO_DELTAS=1`, `verify` fails on an item with no deltas.
   The delta step only warns when it fails on a tag push, so that failure is
   how a release that quietly lost its deltas gets noticed.

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

### 4. The site (for the appcast)

The Sparkle feed URL declared in `project.yml` is
`https://pacer.andrechek.com/appcast.xml`: `site/public/appcast.xml` on `main`,
served by the Cloudflare site, which Workers Builds deploys from GitHub. Its
one-time setup is in [`site/README.md`](../site/README.md) ("How it deploys").
The workflow's `GITHUB_TOKEN` pushes the release commit to `main`, so `main`
must accept pushes from `github-actions[bot]`; a branch rule that blocks it
blocks every release's feed.

**GitHub Pages** serves the legacy mirror, permanently, frozen once it is
turned off ([The legacy GitHub Pages mirror](#the-legacy-github-pages-mirror)):
Settings → Pages → Deploy from a branch → `gh-pages` / root. It already exists;
the publish script only starts a `gh-pages` branch if there is none.

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
the feed to `main` and gh-pages, so a broken secret surfaces without polluting
the release feed.
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
- **Sparkle update not detected** — check the feed the Mac reads
  (`https://pacer.andrechek.com/appcast.xml` from 0.9.4, the gh-pages mirror
  before): it must list a `sparkle:version` greater than
  what's installed. If the site's copy lacks the release, see
  [When the site's feed did not update](#when-the-sites-feed-did-not-update). Sparkle compares `CFBundleVersion` (which the
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
  serialize cleanly instead of one stomping the other's feed push.
- `appcast.xml` only ever grows. If you publish a bad release, tag a
  new patch and let users update past it; don't try to delete items. The
  one sanctioned edit is removing a release's `<sparkle:deltas>` block with
  `bin/appcast-drop-deltas.sh`, which leaves every item and full
  `<enclosure>` as it was.

## Soak check before tagging

`bin/ship.sh release` runs `bin/ship.sh soak` first, and refuses to tag when:
- Pacer isn't running on this Mac;
- the installed build is not the code being released: `make install` records the commit it built in `~/Library/Logs/Pacer/installed-commit`, and the soak fails if that commit differs from `HEAD` under `App/`, `PacerCore/`, `Widgets/`, `Relauncher/`, `CLI/` or `project.yml`, or was built from a tree with uncommitted changes. It compares content, not time, so the squash merge (which restamps everything) does not fail it; without a stamp it falls back to comparing the install time with the last change;
- it has run less than `SHIP_SOAK_MIN_HOURS` (default 1; overnight is better);
- macOS filed any `Pacer-*.ips` crash report since the install (Retired/ included).

It also prints the hangs and the awake stall lines since the install, so you can compare with the previous build. `SHIP_SKIP_SOAK=1` skips it, for an emergency fix only.

Why: 0.9.0 was tagged about 2.5 h after its code was installed. It crashed on the owner's Mac about 2 h after that (the log writer's stack grew with every line), and every 0.9.0 install had the same crash. Run `make install` first, then open the PR: CI and the release run take long enough to give the soak its hour.
