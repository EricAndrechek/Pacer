# Pacer Multi-Device Sync (iPhone + cross-Mac) — Design

Status: **design / pre-implementation.** Produced from a multi-agent research +
adversarial-verification pass (8 dimensions, 5 adversarially stress-tested).
Conclusions are research-grade and must be re-validated against live Apple
behavior in Phase 0/1 before any Production CloudKit schema is frozen.

Goal: let an **iPhone** (and additional **Macs**) see and track Claude Code
usage even when the user's primary Mac is off, with the data durable enough
that a dead/bricked Mac loses nothing. Within the project's hard constraint:
**no telemetry, no Pacer-operated server — all data stays in the user's own
iCloud.**

---

## 1. End-state architecture

The user's own iCloud **private CloudKit database** is the durable
system-of-record and the sole transport. Each device keeps its existing local
SwiftData store authoritative (all `@Attribute(.unique)` constraints and
`SamplePersister` dedup unchanged); CloudKit is an **additive mirror** via
**`CKSyncEngine`** against a plain local `ModelConfiguration`.

`NSPersistentCloudKitContainer` / SwiftData CloudKit mirroring is **rejected**:
it forbids `@Attribute(.unique)` (12 of Pacer's 16 models rely on it) and gives
no natural-key dedup, so the same turn re-mirrored from two Macs would become
two records — the exact 2–3× cost inflation the `dedupKey` guard exists to
prevent. `CKSyncEngine` keeps the local store authoritative and lets us choose
exactly which record types enter the zone.

One container — `iCloud.com.ericandrechek.pacer` — is shared by the Developer-ID
Mac app and a new App-Store iOS app, both under Team `YZXWMJ5VBY`, bound only by
declaring the same container identifier.

```
            ┌─────────── user's private CloudKit DB ───────────┐
            │  data zone:   TokenSample, RateLimitSample,       │
 Mac A ───► │               ExtraUsageSample, DeviceSnapshot,   │ ◄─── Mac B
 (scanner)  │               config (Budget/Alert/PathAlias)     │      (scanner)
            │  control zone: PollerLease (raw CKRecord),         │
            │                Credential (encrypted)             │
            └───────────────────────┬──────────────────────────┘
                                    │ reads DeviceSnapshot only
                                    ▼
                                 iPhone  (+ widgets / Live Activity)
```

## 2. Four sync classes

| Class | Models | Strategy |
|---|---|---|
| **Raw immutable facts** | `TokenSample`, `RateLimitSample`, `ExtraUsageSample` | Sync into one data zone, keyed by a deterministic natural key so the same fact from two Macs collapses to one record. |
| **Derived** | `DailyAggregate`, `HourlyAggregate`, `ProjectDailyAggregate`, `SessionInfo`, `engineOutlookSnapshot` | **Never synced.** Recomputed on each Mac from the unioned facts by the existing recomputers. |
| **Config** | `ProjectBudget`, `AlertRule`, `ProjectPathAlias` | Synced whole-record **last-writer-wins** (CloudKit `modificationDate`), tombstoned deletes, re-keyed on `projectKey`. |
| **Local-only** | `JSONLFileCursor`, `ClaudeCodeMeta`, `ProjectPathProbe`, `Heartbeat` | Never leave the device — per-device scan state; syncing them corrupts other devices. |

### The immutability correction (caught by adversarial review)

The original plan assumed `TokenSample` is fully immutable, so `recordName =
dedupKey` would make it conflict-free. **That premise was false.** Two fields
mutate in place on existing rows:

- **`date`** is timezone-baked (`TimeZone.current`-derived), so the same UTC
  instant differs across machines in different zones.
- **`projectPath`** is canonicalized in place by
  `canonicalizeAffectedSamples` on a path-version bump or alias-graph change.

If those fields were in the synced record, every canonicalization would rewrite
the record and the field would **flap** between machines forever (LWW
ping-pong). Fix: **sync only genuinely-immutable identity fields** — absolute
UTC `sampledAt`, the five token `Int64`s, `sourceCostUSD`, `model`, `sessionId`,
raw `originalProjectPath`, the portable `projectKey`, `ccVersion`, `deviceId`.
**Exclude** `date` and the canonical `projectPath`; each device re-derives `date`
from `sampledAt` + its own timezone and re-derives `projectPath` from the synced
alias graph. The record becomes byte-identical across devices → genuinely
conflict-free.

### Deterministic keys (the other correctness fix)

- `TokenSample`: `recordName` = sanitized `dedupKey` (the `messageId:requestId`
  colon hashed/stripped to safe ASCII; must not start with `_`). **Null-dedupKey
  rows are not synced** — their local "always insert" semantics would
  double-count cross-device.
- `RateLimitSample` / `ExtraUsageSample`: these have **no unique constraint and
  no dedup pass anywhere**, and `sampledAt` is each device's *local* `Date()`.
  So a deterministic, server-derivable key — `source|window|floor(sampledAt to
  the 5-min poll bucket)` — is mandatory: two pollers across a lease handoff
  then collide onto one record instead of forking the rate-limit curve.

## 3. The iPhone reality (honest limits)

`TokenSample` cost/token data can only be produced by the **Mac** (JSONL scanner
over `~/.claude`). The iPhone fundamentally cannot self-source it. Two hard
limits follow, neither removable by engineering under the no-server constraint:

1. **The phone reads a small published `DeviceSnapshot`, not 500K raw facts.** A
   WidgetKit extension can't ingest the raw store or run a recomputer (~30 MB
   jetsam ceiling). The active Mac publishes a `PacerSnapshotPayload`-shaped
   rolling aggregate (current 5h/7d windows with **absolute** `resetsAt` /
   `limitEtaAt`, today/period totals, top projects); the phone and widgets read
   that and tick countdowns locally.
2. **When *all* Macs are off, iPhone freshness is best-effort, not live.** iOS
   gives no reliable scheduled background networking (`BGAppRefreshTask` is
   opportunistic, often hours apart) and no app-originated push (no Pacer
   server). So a phone-only poll cadence is hours, not minutes. This is
   surfaced honestly as an **"updated Nh ago · primary Mac offline"** state —
   never implied as live coverage. Limit-alerts are reliable only while some
   device (a Mac, or the foregrounded phone) is awake.

## 4. The leased poller (best-effort, not a hard mutex)

One `PollerLease` singleton `CKRecord` (`lease.poller.v1`) in a dedicated
**control zone**, managed by **raw CloudKit** (`CKModifyRecordsOperation`,
`.ifServerRecordUnchanged`) — *not* through the SwiftData mirror, which is LWW
and hides `recordChangeTag`.

- **Acquire/renew/preempt** = fetch-then-CAS on `recordChangeTag`; exactly one
  writer wins, the loser gets `serverRecordChanged` and must not poll. First
  boot must also handle the **create-collision** error, not only
  `serverRecordChanged`.
- **Expiry** is computed from the server-assigned `modificationDate` + stored
  `leaseDurationSeconds` + a `GRACE` margin sized against worst-case CloudKit
  write RTT (cellular) — never from device wall clocks.
- **Fencing**: a monotonic `epoch` (++ on acquire/preempt, unchanged on renew).
  A suspended-then-resumed iOS holder finds its `recordChangeTag` stale, fails
  its renew CAS, and drops any in-flight result.
- **Preference**: device-class rank (`mac > ipad > iphone`), upgrade-only
  preemption, Mac stickiness (cheap unconditional renew), Mac re-asserts on
  `NSWorkspace` wake-from-sleep so routine sleep doesn't churn `epoch`. iPhone
  acquires only when no Mac lease is live and best-effort releases on
  backgrounding.

**Two load-bearing corrections:**

- **The lease is NOT the 429 backstop.** CloudKit reads are eventually
  consistent, so two devices can briefly co-poll. The true backstop is
  **mandatory per-device honoring of the endpoint's `429` `Retry-After`**,
  enforced at a single unified poll gate.
- **Every poll path must route through that gate — including the existing local
  Desktop-token `OAuthPoller`.** Otherwise an always-on Desktop-token Mac polls
  un-leased and re-introduces the N-fold load the lease exists to prevent.

## 5. Shared credential delivery

Deliver the long-lived (~354-day) Claude Desktop `user:profile` token via a
**CloudKit `encryptedValues` record**, **not** `kSecAttrSynchronizable` /
iCloud Keychain. Rationale is single-substrate + observable delivery — *not* a
crypto-custody claim: with **Advanced Data Protection OFF (the default)**, plain
`encryptedValues` is Apple-server-key-custodied and is actually *weaker* than
iCloud Keychain's default end-to-end encryption. So **app-managed envelope
encryption is mandatory**: a per-user wrapping key stored only in each device's
`...ThisDeviceOnly` local keychain wraps the token before it reaches CloudKit;
the CloudKit copy is useless without a device-local key. The token field must be
declared encrypted **from schema creation** (Production schema is a one-way
door).

Code-level findings to fix:

- **`HeldCredential.swift:64`** uses `kSecAttrAccessibleAfterFirstUnlock`
  **without** `ThisDeviceOnly` — on iOS that rides into encrypted device backups
  and can migrate to a restored device, leaking a spend-capable token. Change to
  `...ThisDeviceOnly` and set `kSecAttrSynchronizable = false`.
- **Rewriting the credential record does NOT revoke the token.** It stays valid
  server-side until expiry; the project has declined auto-refresh and there is
  no Pacer server to revoke. Treat the blast radius as persisting for the
  token's full ~354-day life on any device that ever fetched it, and document
  it. Only a powered-on Mac with Claude Desktop can mint/refresh — so token
  expiry with all Macs off strands the phone; surface a "needs a Mac with Claude
  Desktop online to refresh" state plus an impending-expiry warning written into
  CloudKit.

## 6. Cross-machine project identity (`projectKey`)

Add a scheme-prefixed `projectKey` **alongside** (not replacing) the path
fields:

- `git:<host>/<owner>/<repo>` for remote-backed repos — cross-machine stable.
- `path:<canonical-local-path>` fallback for origin-less / non-git dirs —
  correctly stays per-Mac.

Normalization is **pure-string over the already-cached
`ProjectPathProbe.originURL`** (zero new `.git/config` reads, honoring the #107
`originBackfillAttempted` gate): rewrite scp-like syntax, strip
scheme/userinfo/port (so ssh and https checkouts collapse, and no PAT reaches
CloudKit), lowercase host only, strip trailing `.git`/slashes. Monorepo
subprojects fold to the repo by default with an opt-in
`#<git-root-relative-subpath>` qualifier.

Three-layer identity: `rawCwd` (`originalProjectPath`, immutable, synced fact) /
`localCanonicalPath` (`projectPath`, mutable, local display, **not** synced) /
`projectKey` (cross-machine merge dimension, synced). Migrate via a
`pathCanonicalizationVersion = 5` bump that folds in `deviceId` too (one additive
pass, no store reset).

## 7. Phased plan

| Phase | Goal | Key deliverables | Depends on |
|---|---|---|---|
| **0 — Signing & feasibility spike (GATE)** | Prove the CloudKit substrate is even shippable on Developer-ID distribution | Notarized Dev-ID build with iCloud(CloudKit)+Push entitlements + embedded provisioning profile + `icloud-container-environment=Production`; confirm `CKContainer.default()` resolves and macOS APNs registration works; **before/after TCC evidence that the embedded profile does NOT revive the per-launch "access data from other apps" prompt** the project re-architected to kill; create the container | none |
| **1 — Module split + CloudKit schema** | Make PacerCore iOS-compilable; stand up the empty substrate, no behavior change | `platforms:[.macOS,.iOS]` + `#if os(macOS)` guards (Watchers/Auth/ServiceManagement/AppKit); extract a shared `PacerSync` target; data + control zones; `CKSyncEngine` wired with an explicit `serverRecordChanged` handler; record-type design (token field encrypted-from-creation) deployed to Production; account-status + probe-write health layer; `projectKey`+`deviceId` migration; fix `HeldCredential.swift:64` | Phase 0 |
| **2 — Durability & cross-Mac sync** | Raw facts become durable + merge across Macs; a rebuilt Mac loses nothing | Sync bridge with its own long-lived `ModelContext` (not the scan-scoped `@ScanActor` `SamplePersister`); exclude `date`/`projectPath`; deterministic recordNames; **`SeedDriver`** (cursored, checkpointed, resumable 500K-row seed gated behind the lease, completeness flag); config LWW sync; per-device re-derivation; round-trip + canonicalization-mutation tests | Phase 1 |
| **3 — iOS app: glance + widgets + alerts** | iPhone sees usage + limit-alerts, reading `DeviceSnapshot` not raw facts | App-Store app + widget/Live-Activity extension; `DeviceSnapshot` publish/consume; signed-out/`.noAccount`/`.restricted` + "Mac offline" states; alert engine decoupled from sync push and background polling; App Privacy "Data Not Collected" + `PrivacyInfo.xcprivacy`; batched+checkpointed iOS apply path | Phase 2 |
| **4 — Leased multi-device poller (highest risk)** | Exactly one active OAuth poller across devices, honest 429 protection | `PollerLease` client (CAS, server-time expiry, epoch fencing, create-collision, wake re-assert); unified poll gate (lease + mandatory `Retry-After`); provenance stamping; iPhone fallback+yield; `CredentialVault` (envelope-wrapped token + expiry state) | Phase 3 |

## 8. Biggest risks (ranked)

1. **Phase-0 signing/TCC unknown.** No evidence yet that a notarized Dev-ID
   build carrying iCloud+Push entitlements + an embedded profile avoids the
   Sequoia per-launch `kTCCServiceSystemPolicyAppData` prompt the project
   re-architected to kill. Incurred by the CloudKit decision itself; could
   invalidate the whole substrate on this distribution. **Prove first.**
2. **iOS background execution** defeats "iPhone sees usage while the Mac is off"
   beyond best-effort. Product-promise limit, not a bug — downgrade the SLA
   honestly.
3. **Durability is bounded by the user's own iCloud** (5 GB shared with
   Photos/Backups; can be full / signed-out / user-deleted). Never prune synced
   facts to stay under quota. Surface as first-class state, never "unconditional
   backup."
4. **Production CloudKit schema is additive-only forever** the instant the App
   Store build ships — wrong recordName / non-encrypted token field / wrong
   type is permanent.
5. **Rate-limit curve divergence** if any future write path uses a
   non-deterministic key (the store can't enforce uniqueness here).
6. **A spend-capable token in iCloud** — envelope wrap is mandatory; blast
   radius persists the token's full life (no revoke path).
7. **App Review** of a thin companion calling an undocumented Anthropic endpoint
   with a Desktop token — must be genuinely useful standalone.
8. **Mac-bound credential replenishment** — token expiry with all Macs off
   strands the phone with no recovery path.

## 9. Open decisions (need Eric's call; several affect the permanent schema)

1. Sync engine self-eval tables (`ForecastModelOutcome`/`EngineEvalOutcome`) for
   instant learned state on a new device, or recompute-local + accept a cold
   track record? (default: recompute-local)
2. Monorepo subproject tracking in v1: folded-to-repo only, or expose the
   `#subpath` qualifier now?
3. Retention/quota policy for raw `TokenSample` in CloudKit: keep forever
   (durability-maximal, approaches 5 GB for multi-year heavy users) vs a
   never-uploaded local "sync last N days" bound (pruning *synced* facts is
   forbidden — it would tombstone-propagate and destroy durability).
4. `ProjectBudget`/`AlertRule` re-key: hard cutover to `projectKey` vs dual-read
   transition window. (recommend dual-read)
5. Per-repo privacy opt-out for `projectKey` (`sha256`+generic label) vs always
   plaintext repo names in the user's own private DB — ship in v1 or defer?
6. Pursue an explicit Anthropic token-revoke-on-rotation (verifying it doesn't
   disturb the separate CC CLI token) to bound blast radius, or formally accept
   and document the persisting radius?
7. iOS deployment floor: iOS 17 (`CKSyncEngine`/SwiftData minimum) vs iOS 18.
