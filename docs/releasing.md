# Releasing Pacer

This doc covers cutting a release and the one-time setup behind it.
The release pipeline lives in
[`.github/workflows/release.yml`](../.github/workflows/release.yml) —
tag-driven, GitHub-Actions-hosted, no local steps once the secrets are
in place.

## Cutting a release (steady state)

1. Land your changes on `main`. `CI` (PacerCore tests + verify build)
   should be green.
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
   - Notarize and staple via App Store Connect.
   - Package as a styled DMG with a drag-to-Applications affordance.
   - Sign the DMG itself + notarize that too.
   - Sign the Sparkle update with the EdDSA private key.
   - Publish the DMG as the asset on a GitHub Release named `vX.Y.Z`.
   - Append the new item to `appcast.xml` on the `gh-pages` branch.

5. Within ~24h, every installed Pacer instance will see the new
   release on its next launch (or on-demand via Pacer → "Check for
   Updates…"). Sparkle handles the download / replace / relaunch.

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

Under **Settings → Secrets and variables → Actions → New repository
secret**, add each of the seven secrets the workflow expects:

| Secret name | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the `.p12` from step 1 |
| `MACOS_CERTIFICATE_PASSWORD` | the password used to export the `.p12` |
| `KEYCHAIN_PASSWORD` | any strong random string (one-time, only used to lock the ephemeral CI keychain) |
| `APPLE_TEAM_ID` | `YZXWMJ5VBY` |
| `NOTARY_KEY_ID` | from step 2 |
| `NOTARY_ISSUER_ID` | from step 2 |
| `NOTARY_KEY_P8` | the full contents of the `.p8` file from step 2 |
| `SPARKLE_ED_PRIVATE_KEY` | the contents of `sparkle-private.key` from step 3 |

### 6. Smoke-test with workflow_dispatch

Before tagging the first real release, manually run the workflow with
`dry_run: true`:

1. Actions → Release → Run workflow.
2. Set `dry_run` to `true`. Click Run.

This exercises every step (signing, notarization, DMG, Sparkle sign)
*except* publishing the GitHub Release and pushing to gh-pages, so a
broken secret surfaces without polluting the release feed.

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
- **Sparkle update not detected** — check `appcast.xml` on the
  `gh-pages` branch: it must list a `sparkle:version` greater than
  what's installed. Sparkle compares `CFBundleVersion` (which the
  workflow stamps with a unix timestamp), so version comparisons
  are strictly monotonic per release run.
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
  new patch and let users update past it; don't try to delete items.
