# Informed pacing — planning with the numbers

**Read this only when informed pacing is on**: the gate's GO line says
"Informed pacing is on", or `pacer mode` prints `informed`. The user turned it
on (a repo's `.claude/settings.json` `"env": {"PACER_PACING": "informed"}`, a
`PACER_PACING=informed` launch, or `pacer mode informed`) because they want
agents to weigh usage when planning. Without it, the rule in SKILL.md §0 holds:
usage only stops work.

Even in informed mode, the protocol in SKILL.md (gate, status clause, wait,
manifest) is unchanged, and the numbers are an input, not an order: the user's
own instructions about models and scope still come first.

## The capacity is the machine's logins, not one login's window

A rate-limit window is account-wide: every session signed into a login draws on
the same percentage. But a machine with several logins, and an account
switcher rotating between them, has the sum of their room, not one login's.

- `pacer report` prints this session's login, then `other logins: 1 with room
  (7d 11%), 1 near its limit, 1 spent until 11:59 PM`, then, when an account
  switcher is running, `rotation: on — …`.
- **"With room" means room to resume onto**: every account-wide window at
  least `--resume-headroom` points below its limit (by default 20 minutes at
  the higher of that login's burn and this one's, at least 5). A login under
  its limit by less is "near its limit": a switch onto it would be over in
  minutes.
- `pacer accounts` lists every login with its plan, the sessions on it, its
  windows, and `room` / `near its limit` / `spent until …`, with `rotation
  target` where a running switcher would pick it.
- `full in 3d 0h (rotation moves on)` is this login filling, not the machine:
  the switcher moves the sessions before then.

So before calling capacity short, count the logins with room. A login at its
weekly limit with another login at 11% is a switch, not a shortage.

## What the numbers are good for

- **The plan is the denominator.** 20% of a Max 20× budget is four times 20%
  of a Max 5× one. `accounts` reads `Max 20×` when Anthropic reports a tier and
  falls back to the family (`Max`); Pacer never guesses a multiplier.
- **Concurrency is already in the rate.** Four sessions producing 20%/h
  between them is 20%/h, not 80%. `pacer sessions` shows where they are, with
  the branch each one is on, read at the moment you ask.
- **Ordering, not shrinking.** When the user has said the budget matters, the
  useful move is usually to order the work (what must land before a reset)
  rather than to make it smaller or weaker.

## Gating on the forecast

The default gate asks "am I about to run out" and stops just before the limit.
`--eta` asks **"will this finish before this login runs out"**, and pauses
earlier, with room left:

```
$ pacer gate --eta 90m
pace: PAUSE — 5h at 40% is projected to fill in 45m (horizon 1h 30m).
```

Use it only for work that cannot be checkpointed mid-way, and not on a machine
that rotates logins: there, this login filling means a switch.

## Reserving part of a window

`--cap N` pauses at N% instead of the safe limit, and `--margin N` stops N
points below each window's safe limit, so the reserve tracks the burn. Use
them only when the user decides to keep part of a window in reserve: how much
to spend is their call, not a default's.
