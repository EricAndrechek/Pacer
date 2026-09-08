# The OAuth usage endpoint & adaptive multi-token polling

Pacer's rate-limit numbers come from `GET https://api.anthropic.com/api/oauth/usage`
— the undocumented endpoint Claude Code itself polls for its banner. This
note records what we measured about it (2026-07-08) and why the poller is
shaped the way it is, so nobody has to re-run the experiments.

## Request

```
GET /api/oauth/usage
Authorization: Bearer <oauth access token>   # user:profile scope
anthropic-beta: oauth-2025-04-20
User-Agent: pacer/1.0 (+https://github.com/ericandrechek/pacer)
Accept: application/json
```

Response is `application/json`, `cf-cache-status: DYNAMIC` (computed at
origin per request), carrying `anthropic-organization-id` — the account
the token belongs to. Body includes `five_hour` / `seven_day`
(`utilization` 0–100, `resets_at`), plus a richer `limits[]` array with
per-model **scoped** windows, `severity`, and `is_active` that we don't
yet surface (a future enhancement).

## What we measured

Two experiments (a 20s two-token sampler, then a rate-respecting 90s
round-robin over 4 Desktop tokens):

1. **The value is computed live, not bucketed to 5 minutes.** Utilization
   steps landed *mid-bucket* (e.g. 13:47 and 13:56), not only on `:00`/`:05`
   wall-clock marks, and `resets_at` varies by microseconds per request.
   So polling more often genuinely yields fresher numbers.
2. **…but resolution is integer percent.** At moderate burn the value only
   changes about once every 15–25 min, so extra freshness mostly matters
   during heavy bursts.
3. **Rate limit ≈ 1 request / 5 min / token, and it bites.** At 3 req/min
   the Claude Code token 429'd after 28 requests (~9.5 min); a Desktop
   token after 16 (~5.5 min). Once throttled, recovery was ~1 success per
   5 min, and a single ~28-request burst kept a token throttled for **~35
   minutes**. There are **no rate-limit headers**; 429s carry only
   `Retry-After: 0` (present but useless).
4. **Multiple tokens are independent budgets for the same data.** An
   account often has several tokens (Claude Code + Claude Desktop). They
   return **identical** utilization (same account) but each has its own
   per-token budget — 4 Desktop tokens round-robined at 90s ran clean
   indefinitely.

### The consequence

Because the data is *live* but each token is capped at ~1 poll / 5 min,
spreading polls across N same-account tokens gives a genuinely finer
**effective** cadence (5 min ÷ N) at a sustainable per-token rate. That's
the lever the poller pulls.

## Design (`OAuthPoller` + `OAuthPollScheduler`)

- **Lanes.** One lane per discovered token (`OAuthClient.candidateCredentials()`
  — Claude Code keychain always, opted-in Desktop behind the
  `DesktopReadGate` so it isn't re-read/re-prompted).
- **Scheduler** (`OAuthPollScheduler`, pure/unit-tested) spreads polls:
  - **Per-token invariant:** no lane polled more than once per
    `perTokenMinInterval` (300s) — the hard rail that keeps every lane off
    the ~30-min throttle.
  - **Active** (recent Claude usage): the fastest *even* cadence the
    lanes sustain — `max(activeInterval floor 60s, perTokenMin/lanes)`.
    So 5 tokens → ~1 min, 2 → ~2.5 min, 1 → 5 min.
  - **Idle:** relax to `idleInterval` (600s).
  - **Poll-on-wake:** the `ScanCoordinator` calls `notifyActivity()` when
    fresh usage lands, waking the loop to re-evaluate (still bounded by the
    per-token floor, so a nudge can never over-poll).
- **Same-account guard.** The first successful poll sets the pool's primary
  org (`anthropic-organization-id`); a lane resolving to a different org is
  marked *foreign* — never selected, never persisted — so interleaving can
  never mix two accounts into one timeline.
- **Per-lane cooldown.** A 429/transport/5xx cools *that lane* (exponential,
  capped); other lanes keep the timeline fresh. There's no `Retry-After` to
  honor, so cooldown is our own schedule.

With one token this degrades cleanly to single-lane activity-gating. Tuning
constants live in `OAuthPoller.Configuration` / `OAuthPollScheduler.Tuning`.

## Sharing a token with another client

Pacer is not necessarily the only thing on this machine polling these
credentials. `cswap` polls the same tokens to decide when to switch accounts,
and because the budget is **per token**, two clients each politely keeping to
one request per five minutes add up to two — which is over, permanently.

Observed, 2026-09-08, on the account that was signed in: Pacer polled at
14:45:40 (fine), 14:50:52 (429) and 14:55:52 (429), while cswap sat at
`lastError: http-429` for fifty minutes and the reading on screen aged from 0.4
to 12.4 minutes. Neither client was misbehaving on its own. Together they were
double the budget, and every retry from either kept the throttle alive.

The arrangement, in `SwitcherUsageCache` + `OAuthPoller`:

- **Read, don't re-fetch.** cswap writes what it fetched to
  `~/.claude-swap-backup/cache/usage.json`, for every account it manages. A
  reading newer than Pacer's own is recorded as a sample (`source: cswap`), so
  the data arrives without spending any budget.
- **Count its requests, not just its answers.** `lastAttemptAt` moves on a 429;
  `fetchedAt` does not. Reading only the latter made a client retrying every few
  minutes look idle, and Pacer scheduled straight into it. The per-token
  interval now runs from whichever client asked last (`externalLastPollAt`).
- **Keep clear of its next one.** cswap publishes `nextPollAt`; Pacer will not
  poll so close in front of it that the pair breaches the same spacing. An
  *overdue* time counts as imminent — a client that is behind is a client that
  keeps failing, which is when it most needs the room.
- **But never yield forever** (`externalYieldMax`, 15 min). A client that asks
  constantly and never succeeds would otherwise pin a lane, and on an account
  with a single token that means no readings at all. One probe per fifteen
  minutes is well under budget.

Only the credential cswap actually swaps is affected — Claude Code's keychain
entry and the parked `Claude Code-credentials-<suffix>` ones. Desktop tokens for
the same account are separate credentials with separate budgets and are left
alone (`sharesBudgetWithSwitcher`); an early version marked every lane of the
account and collapsed the multi-token stagger that makes the fast cadence
possible.
