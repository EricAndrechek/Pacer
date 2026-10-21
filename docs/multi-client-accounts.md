# Multi-client accounts: who is active, on what (#245)

> Part of the account design in [`multi-account.md`](multi-account.md). This
> note is the (account, client) model; that one is attribution and scoping.

## The finding

"Active" was one flag, `Account.isActive`: the CLI's login. But several
clients can be live on different accounts at once, even with a switcher set to
one account at a time:

- **The Claude Code CLI**, on the default login.
- **Each Claude Desktop install** (#295), and its built-in Claude Code and agent
  mode, on Desktop's own login. On the maintainer's Mac, Desktop runs routines
  on one account while the CLI is on another.
- **Pinned config roots** (`cswap run`, `CLAUDE_CONFIG_DIR`), on the profile's
  login.

So "active" is a set of (account, client) pairs, `AccountClients`.

## The model

| client | evidence | active while |
|---|---|---|
| CLI | the trail's open default-login span | it is the login. No timeout: it is the account the next message bills. |
| each Desktop install | its session records' `lastActivityAt`, newest per account folder (`DesktopSessionDirectory.activity`) | 30 minutes after the newest |
| each pinned profile | its open trail span, plus the newest transcript write under it (the scan's cursor cache) | 30 minutes after that write |

Each entry carries its evidence's last-seen time and, for the timed ones, when
it stops counting (`activeUntil`).

**The evidence is what #244 already reads.** Desktop's session records carry
`createdAt` / `lastActivityAt`; the same reader that attributes Desktop's turns
keeps the newest per account. Records are listed at most every 30 seconds, and
a record is re-read (its first 4 KB) only when Desktop has rewritten it. The
`oauthAccount` writes the trail rejects as stale are Desktop's too, but the
records make them unnecessary as evidence, so they stay rejected.

**Desktop chat writes no record.** It is not a Claude Code session, leaves no
token record on the Mac, and so never makes Desktop active. It shows only as
account utilisation in the readings Pacer polls.

**Why 30 minutes** (owner decision, 2026-10-20): long enough to cover a
routine's gaps between turns, short enough that a Desktop left open on an idle
account stops claiming it. One rule for every install, and the same rule for
pinned profiles, whose open span alone would otherwise call them active for as
long as the profile exists.

**Built off the main actor, published twice.** The scan builds it after the
trail is read, each cycle and each login pass, and publishes it only when it
changed: to `AccountClientsStore` (a lock, for the HTTP API's queue) and to
`AccountClientsMonitor` (`@Observable`, for views). The monitor moves on its
own at the next `activeUntil`, so a Desktop's 30 minutes running out redraws
what shows it, on an idle machine where no scan would.

## What each surface shows

| surface | shows |
|---|---|
| Dashboard headline | Unchanged: the CLI login, the account the next message bills. |
| Settings → Accounts | Each row names its other active clients as chips beside the plan ("Desktop · Work"). The CLI stays the "Active" badge. Only with more than one account. |
| Accounts header (pace card, all accounts) | The same chips after "signed in". |
| Menu bar | The grouped layout whenever more than one account is active, not only under concurrent profiles. Groups are the active accounts (every account under concurrent profiles, as before); each header names its clients after "signed in". |
| Widgets | Unchanged. They follow the scope, and the scope's limits are the CLI login's unless one is picked. |
| Alerts | Already every account. A banner for an account only Desktop (or a profile) is on says so: "Work (Desktop · Work)". |
| Pacing | Unchanged: a session gates against its own account, `/v1/session`'s `currentAccountId`. |
| `/v1/accounts` | Each row gains `clients`: kind, label, `active`, `lastSeenAt`, `activeUntil`. `isActive` stays the CLI's. |
| `/metrics` | `pacer_account_client_active{account,client,instance}`, 1 or 0, beside the other per-account series and like them only with more than one account. `instance` is an opaque hash, not the folder name. |
| `/v1/stream` | A new `clients` event when the active set changes. `account` stays the CLI login's own event, so a client waiting on a switch is not woken by Desktop. |

The CLI is not given a chip where the screen already marks it ("Active",
"signed in"): one fact, said once.

## Migration

Nothing is stored: the model is rebuilt from the trail, Desktop's records and
the cursor cache on every launch, so there is no schema change.

**A single-account user sees no change.** Every chip is gated on more than one
account; the menu bar groups only when two accounts are active; alerts name a
client only beside an account label, which exists only with two accounts.
`/v1/accounts` rows gain `clients` (additive), and `/metrics` adds nothing for
one account.

## Not done

- A per-client *usage* split (how much of an account's 5-hour window Desktop
  drew). The rate-limit reading is account-wide; the turn-level split is #220.
- Desktop chat as a number: that is the allowance work's "other surfaces"
  share (#219).
