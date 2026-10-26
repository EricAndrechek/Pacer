"""Episodes: the test cases every model in a run is scored on.

An episode is a scope (whose data, and whether the model sees only those
accounts or every account), a history start, a cutoff, a horizon, the targets
and the checkpoints. The sampler is seeded; a run draws its episodes once and
hands every model exactly the same ones.

- **Classes.** Each episode has a primary target, taken in turn from the
  requested targets, and the cutoff is uniform over the tier's moments where
  that target exists: an active cycle (known at the cutoff, resetting inside
  the tier) for a meter; an idle five-hour window for `cycle.next_start`;
  accounts already seen for the hourly targets. Meter episodes are one account
  and carry every requested meter target active at the cutoff; hourly
  episodes are a random group and carry spend, tokens (all and per family)
  and the split.
- **History start.** From everything available down to 3 days before the
  cutoff (log-uniform, with a share drawn as "everything"), to test cold
  starts.
- **Horizon.** Meters: the reset known at the cutoff. Spend and tokens: 24 h,
  or 7 d for a share of episodes. `cycle.next_start`: 24 h.
- **Checkpoints.** The cutoff, every reading of the scope's accounts that
  becomes known before the horizon, and every hour; capped per episode by an
  even subsample.
- **Grids.** Meters start with a dense head, so the next reading (often
  seconds away) and the live meter are read off the forecast at their own
  lead rather than at the first coarse step: five-hour +30 s, +1, +2, +3 and
  +5 min, then every 5 min; seven-day and scoped +1, +5, +15 and +30 min, then
  every 30 min. The last meter grid point is the reset itself. Hourly targets
  every hour from `now`, so each value covers a fully future hour.

`TierIndex` holds the fast as-of lookups the sampler and the runner share
(meter series, turn times, hourly sums priced with final rates for truth).
"""
from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass

import numpy as np
import polars as pl

from arena.pricing import SYNTHETIC_MODEL, output_tokens, price_turns
from arena.snapshot.cycles import DAY_MS, HOUR_MS, MeterIndex, meter_frame
from arena.snapshot.views import Mode, SnapshotData
from arena.types import DEFAULT_PATHS, Millis, Request, Scope, Target, TargetRequest

MIN_MS = 60_000

METER_TARGETS = (Target.METER_5H, Target.METER_7D, Target.METER_SCOPED)
HOURLY_TARGETS = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY, Target.SPLIT)
ALL_TARGETS = (*METER_TARGETS, Target.CYCLE_NEXT_START, *HOURLY_TARGETS)
WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
UNITS = {Target.METER_5H: "pct", Target.METER_7D: "pct", Target.METER_SCOPED: "pct",
         Target.CYCLE_NEXT_START: "epoch_ms", Target.SPEND_HOURLY: "usd_per_hour",
         Target.TOKENS_HOURLY: "tokens_per_hour", Target.SPLIT: "share"}
GRID_STEP = {Target.METER_5H: 5 * MIN_MS, Target.METER_7D: 30 * MIN_MS, Target.METER_SCOPED: 30 * MIN_MS,
             Target.SPEND_HOURLY: HOUR_MS, Target.TOKENS_HOURLY: HOUR_MS, Target.SPLIT: HOUR_MS,
             Target.CYCLE_NEXT_START: 0}
# Meter grids' dense head (leads in ms before the regular steps take over at
# the first multiple of GRID_STEP): readings arrive every 15 s to 5 min, so
# `next_reading_ae` and the live meter are scored at leads of seconds.
GRID_HEAD = {Target.METER_5H: (30_000, MIN_MS, 2 * MIN_MS, 3 * MIN_MS),
             Target.METER_7D: (MIN_MS, 5 * MIN_MS, 15 * MIN_MS),
             Target.METER_SCOPED: (MIN_MS, 5 * MIN_MS, 15 * MIN_MS)}
FAMILIES = ("fable", "opus", "sonnet", "haiku", "other")


@dataclass(frozen=True)
class TargetSpec:
    """One target of one episode, fixed at the cutoff."""

    key: str
    target: Target
    accounts: tuple[str, ...]
    horizon_end: Millis
    reset_at: Millis | None = None        # meters: the reset known at the cutoff
    cap: str | None = None                # meter.scoped
    family: str | None = None             # tokens.hourly
    group: tuple[str, ...] | None = None  # split: the group the share is of
    idle_since: Millis | None = None      # next_start: the previous cycle's reset

    @property
    def units(self) -> str:
        return UNITS[self.target]

    @property
    def window_kind(self) -> str | None:
        return WINDOW_OF.get(self.target)


@dataclass(frozen=True)
class Episode:
    episode_id: int
    tier: str
    scope: Scope
    mode: Mode
    history_start: Millis
    cutoff: Millis
    horizon_end: Millis
    targets: tuple[TargetSpec, ...]
    checkpoints: tuple[Millis, ...]
    primary: str
    longrun: bool = False

    def to_dict(self) -> dict:
        d = asdict(self)
        d["scope"] = {"accounts": list(self.scope.accounts), "view": self.scope.view}
        d["targets"] = [{**asdict(t), "target": str(t.target)} for t in self.targets]
        return d

    def fingerprint(self) -> str:
        return json.dumps(self.to_dict(), sort_keys=True, default=list)


@dataclass
class SamplerConfig:
    episodes: int = 20
    seed: int = 0
    targets: tuple[str, ...] = tuple(str(t) for t in ALL_TARGETS)
    mode: Mode = "current_code"
    p_all_view: float = 0.5
    p_full_history: float = 0.25
    min_history_ms: int = 3 * DAY_MS
    checkpoint_cap: int = 24
    hourly_horizons: tuple[int, int] = (DAY_MS, 7 * DAY_MS)
    p_long_hourly: float = 0.25
    next_start_horizon: int = DAY_MS
    min_lead_ms: int = 10 * MIN_MS          # a meter cutoff at least this long before its reset
    n_paths: int = DEFAULT_PATHS
    max_attempts: int = 500
    longrun_every: int = HOUR_MS
    longrun_cap: int = 5000
    longrun_view: str = "scope_only"


# ---------------------------------------------------------------------------
# Tier index
# ---------------------------------------------------------------------------

class TierIndex:
    """Fast lookups over one tier's data, shared by the sampler and runner.
    Holds future data: never handed to a model."""

    def __init__(self, data: SnapshotData):
        self.data = data
        self.tier = data.tier
        self.accounts = data.accounts()
        r = data.tables["meter_readings"]
        self.meters: dict[tuple[str, str, str | None], MeterIndex] = {}
        if r.height:
            for (acct, kind, cap), g in r.group_by(["account", "window_kind", "scope_model"]):
                if acct is None or kind not in ("five_hour", "seven_day", "weekly_scoped"):
                    continue
                self.meters[(acct, kind, cap if kind == "weekly_scoped" else None)] = MeterIndex(
                    meter_frame(g, acct, kind, cap if kind == "weekly_scoped" else None), acct, kind,
                    cap if kind == "weekly_scoped" else None)
        t = data.tables["turns"].filter(pl.col("model") != SYNTHETIC_MODEL)
        self._turns: dict[str, tuple[np.ndarray, np.ndarray]] = {}
        self.first_known: dict[str, int] = {}
        for acct in self.accounts:
            g = t.filter(pl.col("account") == acct).sort("t_event")
            te = g["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
            tk = g["t_known"].dt.epoch("ms").to_numpy().astype(np.int64)
            self._turns[acct] = (te, tk)
            firsts = [int(tk.min())] if len(tk) else []
            firsts += [int(m._k_tk[0]) for k, m in self.meters.items() if k[0] == acct and len(m)]
            if firsts:
                self.first_known[acct] = min(firsts)
        self._hourly: dict[str, tuple] | None = None
        self._tz: tuple[np.ndarray, np.ndarray] | None = None

    # meters ------------------------------------------------------------
    def meter(self, account: str, target: Target, cap: str | None = None) -> MeterIndex | None:
        return self.meters.get((account, WINDOW_OF[target], cap if target is Target.METER_SCOPED else None))

    def caps(self, account: str) -> list[str]:
        return sorted(k[2] for k in self.meters if k[0] == account and k[1] == "weekly_scoped" and k[2])

    def reading_times(self, accounts, since: Millis, until: Millis) -> np.ndarray:
        ts = [m.known_times(since, until) for k, m in self.meters.items() if k[0] in accounts]
        return np.unique(np.concatenate(ts)) if ts else np.zeros(0, np.int64)

    # turns -------------------------------------------------------------
    def known_turn_after(self, account: str, after: Millis, now: Millis) -> bool:
        """Is a turn with t_event > after already known at now?"""
        te, tk = self._turns.get(account, (np.zeros(0, np.int64),) * 2)
        return bool(((te > after) & (tk <= now)).any())

    def first_turn_after(self, account: str, after: Millis) -> Millis | None:
        te, _ = self._turns.get(account, (np.zeros(0, np.int64),) * 2)
        i = int(np.searchsorted(te, after, side="right"))
        return int(te[i]) if i < len(te) else None

    def recent_families(self, accounts, now: Millis, lookback: int = 7 * DAY_MS) -> list[str]:
        t = self.data.tables["turns"]
        if not t.height:
            return []
        tk = pl.col("t_known").dt.epoch("ms")
        f = t.filter(pl.col("account").is_in(list(accounts)) & (tk <= now) & (tk > now - lookback))
        return sorted(x for x in f["model_family"].unique().to_list() if x in FAMILIES)

    def tz_offset_at(self, now: Millis) -> int | None:
        """The device's UTC offset (minutes) as known at `now`: the
        `tz_offset_min` of the latest turn (by t_event, any account) with
        t_known <= now; None before any is known. What `History.tz_offset_min`
        carries to a worker."""
        if self._tz is None:
            t = self.data.tables["turns"]
            t = t.filter(pl.col("tz_offset_min").is_not_null()) if t.height else t
            if not t.height:
                self._tz = (np.zeros(0, np.int64), np.zeros(0, np.int64))
            else:
                tk = t["t_known"].dt.epoch("ms").to_numpy().astype(np.int64)
                te = t["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
                tz = t["tz_offset_min"].to_numpy().astype(np.int64)
                o = np.lexsort((te, tk))                     # knowledge order, ties by t_event
                tk, te, tz = tk[o], te[o], tz[o]
                # Running "latest by t_event" pointer over knowledge order
                # (ties: the later-known row), as MeterIndex.latest_known.
                prev = np.concatenate(([np.iinfo(np.int64).min], np.maximum.accumulate(te)[:-1]))
                best = np.maximum.accumulate(np.where(te >= prev, np.arange(len(te)), 0))
                self._tz = (tk, tz[best])
        tk, tz = self._tz
        i = int(np.searchsorted(tk, now, side="right")) - 1
        return None if i < 0 else int(tz[i])

    # hourly truth ------------------------------------------------------
    def _hourly_arrays(self):
        """Per account: t_event, cost (final rates, best output; NaN when
        unpriced), total tokens, family."""
        if self._hourly is None:
            t = self.data.tables["turns"].filter(pl.col("model") != SYNTHETIC_MODEL)
            priced = price_turns(t, self.data.tables["prices"], output="best")
            priced = priced.with_columns(
                (pl.col("input").cast(pl.Float64) + output_tokens(priced, "best").fill_null(0)
                 + pl.col("cache_read") + pl.col("cache_write_5m") + pl.col("cache_write_1h")
                 ).alias("_tokens")).sort("t_event")
            out = {}
            for acct in self.accounts:
                g = priced.filter(pl.col("account") == acct)
                out[acct] = (g["t_event"].dt.epoch("ms").to_numpy().astype(np.int64),
                             g["cost_usd"].fill_null(np.nan).to_numpy().astype(np.float64),
                             g["_tokens"].fill_null(np.nan).to_numpy().astype(np.float64),
                             np.array(g["model_family"].fill_null("other").to_list(), dtype=object))
            self._hourly = out
        return self._hourly

    def hourly(self, accounts, grid: np.ndarray, what: str, family: str | None = None) -> np.ndarray:
        """Sum over each (g - 1h, g] of the group's spend or tokens, by
        t_event. NaN when any turn in the hour has no price (spend only)."""
        arrs = self._hourly_arrays()
        t_list, v_list = [], []
        for a in accounts:
            if a not in arrs:
                continue
            te, cost, tok, fam = arrs[a]
            v = cost if what == "spend" else tok
            if family is not None:
                keep = fam == family
                te, v = te[keep], v[keep]
            t_list.append(te)
            v_list.append(v)
        if not t_list:
            return np.zeros(len(grid))
        te = np.concatenate(t_list)
        v = np.concatenate(v_list)
        o = np.argsort(te, kind="stable")
        te, v = te[o], v[o]
        nan = np.isnan(v)
        cs = np.concatenate(([0.0], np.cumsum(np.where(nan, 0.0, v))))
        cn = np.concatenate(([0], np.cumsum(nan)))
        hi = np.searchsorted(te, grid, side="right")
        lo = np.searchsorted(te, grid - HOUR_MS, side="right")
        out = cs[hi] - cs[lo]
        out[(cn[hi] - cn[lo]) > 0] = np.nan
        return out


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

def target_key(target: Target, accounts, cap=None, family=None) -> str:
    k = f"{target}:{'+'.join(accounts)}"
    return k + (f":{cap}" if cap else "") + (f":{family}" if family else "")


def grid_for(spec: TargetSpec, now: Millis) -> np.ndarray | None:
    """The spec's grid at `now`, or None when nothing is left to forecast."""
    if spec.target is Target.CYCLE_NEXT_START:
        return np.array([spec.horizon_end], dtype=np.int64) if spec.horizon_end > now else None
    step = GRID_STEP[spec.target]
    if spec.target in METER_TARGETS:
        end = spec.reset_at
        if end is None or end <= now:
            return None
        head = np.asarray(GRID_HEAD[spec.target], dtype=np.int64) + now
        g = np.concatenate([head, np.arange(now + step, end, step, dtype=np.int64)])
        return np.append(g[g < end], np.int64(end))
    g = np.arange(now + step, spec.horizon_end + 1, step, dtype=np.int64)
    return g if len(g) else None


def specs_at(ep: Episode, now: Millis, index: TierIndex, cfg: SamplerConfig) -> list[TargetSpec]:
    """The episode's targets still open at `now`."""
    specs = longrun_specs(ep, now, index, cfg) if ep.longrun else list(ep.targets)
    out = []
    for s in specs:
        if s.horizon_end <= now:
            continue
        if s.target is Target.CYCLE_NEXT_START and index.known_turn_after(s.accounts[0], s.idle_since, now):
            continue                               # already answered by what the model knows
        if grid_for(s, now) is not None:
            out.append(s)
    return out


def build_request(scope: Scope, now: Millis, specs: list[TargetSpec], n_paths: int,
                  targets: set[str] | None = None) -> Request:
    trs = []
    for s in specs:
        if targets is not None and str(s.target) not in targets:
            continue
        trs.append(TargetRequest(key=s.key, target=s.target, accounts=s.accounts, grid=grid_for(s, now),
                                 units=s.units, n_paths=n_paths, cap=s.cap, family=s.family,
                                 reset_at=s.reset_at))
    return Request(now=now, scope=scope, targets=tuple(trs))


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

def meter_specs(index: TierIndex, account: str, now: Millis, wanted, tier_end: Millis,
                 min_lead: int) -> list[TargetSpec]:
    out = []
    for t in METER_TARGETS:
        if t not in wanted:
            continue
        caps = index.caps(account) if t is Target.METER_SCOPED else [None]
        for cap in caps:
            m = index.meter(account, t, cap)
            c = m.cycle_at(now) if m is not None else None
            if c is None or c.reset_at > tier_end or c.reset_at - now < min_lead:
                continue
            out.append(TargetSpec(target_key(t, (account,), cap), t, (account,), c.reset_at,
                                  reset_at=c.reset_at, cap=cap))
    return out


def next_start_spec(index: TierIndex, account: str, now: Millis, horizon: int,
                     tier_end: Millis) -> TargetSpec | None:
    m = index.meter(account, Target.METER_5H)
    if m is None or now + horizon > tier_end or m.cycle_at(now) is not None:
        return None
    since = m.last_reset_before(now)
    if since is None or index.known_turn_after(account, since, now):
        return None
    return TargetSpec(target_key(Target.CYCLE_NEXT_START, (account,)), Target.CYCLE_NEXT_START,
                      (account,), now + horizon, idle_since=since)


def hourly_specs(index: TierIndex, group: tuple[str, ...], now: Millis, horizon: int, wanted) -> list[TargetSpec]:
    end = now + horizon
    out = []
    if Target.SPEND_HOURLY in wanted:
        out.append(TargetSpec(target_key(Target.SPEND_HOURLY, group), Target.SPEND_HOURLY, group, end))
    if Target.TOKENS_HOURLY in wanted:
        out.append(TargetSpec(target_key(Target.TOKENS_HOURLY, group), Target.TOKENS_HOURLY, group, end))
        for fam in index.recent_families(group, now):
            out.append(TargetSpec(target_key(Target.TOKENS_HOURLY, group, family=fam), Target.TOKENS_HOURLY,
                                  group, end, family=fam))
    if Target.SPLIT in wanted and len(group) >= 2:
        for a in group:
            out.append(TargetSpec(target_key(Target.SPLIT, (a,)), Target.SPLIT, (a,), end, group=group))
    return out


def _history_start(rng, cutoff: Millis, data_start: Millis, cfg: SamplerConfig) -> Millis:
    avail = cutoff - data_start
    if avail <= cfg.min_history_ms or rng.random() < cfg.p_full_history:
        return data_start
    length = math.exp(rng.uniform(math.log(cfg.min_history_ms), math.log(avail)))
    return int(cutoff - length)


def _checkpoints(index: TierIndex, accounts, cutoff: Millis, horizon_end: Millis, cap: int) -> tuple[int, ...]:
    reads = index.reading_times(accounts, cutoff, horizon_end - 1)
    hours = np.arange(cutoff + HOUR_MS, horizon_end, HOUR_MS, dtype=np.int64)
    rest = np.unique(np.concatenate([reads, hours]))
    rest = rest[(rest > cutoff) & (rest < horizon_end)]
    if cap > 0 and len(rest) > cap - 1:
        pick = np.unique(np.linspace(0, len(rest) - 1, max(cap - 1, 0)).round().astype(int))
        rest = rest[pick] if cap > 1 else rest[:0]
    return (int(cutoff), *(int(x) for x in rest))


def _classes(cfg: SamplerConfig, n_accounts: int) -> list[Target]:
    wanted = [Target(t) for t in cfg.targets]
    order = [t for t in ALL_TARGETS if t in wanted]
    if n_accounts < 2:
        order = [t for t in order if t is not Target.SPLIT]
    return order


def sample_episodes(index: TierIndex, cfg: SamplerConfig) -> list[Episode]:
    """`cfg.episodes` episodes for the tier, deterministic in `cfg.seed`. A
    class with no eligible moment in the tier is skipped (fewer episodes)."""
    rng = np.random.default_rng(cfg.seed)
    tier = index.tier
    wanted = {Target(t) for t in cfg.targets}
    accounts = [a for a in index.accounts if a in index.first_known]
    classes = _classes(cfg, len(accounts))
    if not classes or not accounts:
        return []
    data_start = index.data.data_start
    eps: list[Episode] = []
    dead: set[Target] = set()
    i = 0
    while len(eps) < cfg.episodes and len(dead) < len(classes):
        primary = classes[i % len(classes)]
        i += 1
        if primary in dead:
            continue
        got = None
        for _ in range(cfg.max_attempts):
            cutoff = int(rng.integers(tier.start + 1, tier.end + 1))
            seen = [a for a in accounts if index.first_known[a] <= cutoff]
            if not seen:
                continue
            if primary in METER_TARGETS or primary is Target.CYCLE_NEXT_START:
                acct = seen[int(rng.integers(0, len(seen)))]
                if primary is Target.CYCLE_NEXT_START:
                    s = next_start_spec(index, acct, cutoff, cfg.next_start_horizon, tier.end)
                    specs = [s] if s is not None else []
                else:
                    specs = meter_specs(index, acct, cutoff, wanted, tier.end, cfg.min_lead_ms)
                    if not any(s.target is primary for s in specs):
                        continue
                group = (acct,)
            else:
                lo = 2 if primary is Target.SPLIT else 1
                if len(seen) < lo:
                    continue
                k = int(rng.integers(lo, len(seen) + 1))
                group = tuple(sorted(rng.choice(seen, size=k, replace=False).tolist()))
                long = rng.random() < cfg.p_long_hourly
                horizon = cfg.hourly_horizons[1] if long else cfg.hourly_horizons[0]
                if cutoff + horizon > tier.end:
                    horizon = cfg.hourly_horizons[0]
                if cutoff + horizon > tier.end:
                    continue
                specs = hourly_specs(index, group, cutoff, horizon, wanted)
            if not specs:
                continue
            got = (cutoff, group, specs)
            break
        if got is None:
            dead.add(primary)
            continue
        cutoff, group, specs = got
        view = "all" if (len(accounts) > 1 and rng.random() < cfg.p_all_view) else "scope_only"
        start = _history_start(rng, cutoff, data_start, cfg)
        horizon_end = max(s.horizon_end for s in specs)
        cps = _checkpoints(index, group, cutoff, horizon_end, cfg.checkpoint_cap)
        eps.append(Episode(len(eps), tier.name, Scope(group, view), cfg.mode, start, cutoff, horizon_end,
                           tuple(specs), cps, str(primary)))
    return eps


def longrun_specs(ep: Episode, now: Millis, index: TierIndex, cfg: SamplerConfig) -> list[TargetSpec]:
    """A long-run episode asks, at every checkpoint, for whatever is open
    then: the active cycles to their resets, the next start when idle, and
    24 hours of the hourly targets."""
    wanted = {Target(t) for t in cfg.targets}
    acct = ep.scope.accounts[0]
    end = index.tier.end
    out = meter_specs(index, acct, now, wanted, end, 1)
    if Target.CYCLE_NEXT_START in wanted:
        s = next_start_spec(index, acct, now, cfg.next_start_horizon, end)
        if s is not None:
            out.append(s)
    if now + cfg.hourly_horizons[0] <= end:
        out += hourly_specs(index, ep.scope.accounts, now, cfg.hourly_horizons[0],
                             wanted - {Target.SPLIT} if len(ep.scope.accounts) < 2 else wanted)
    return out


def longrun_episodes(index: TierIndex, cfg: SamplerConfig, accounts: tuple[str, ...] | None = None) -> list[Episode]:
    """One long episode per account over the whole tier (adaptation, regret,
    recovery after real changes)."""
    tier = index.tier
    eps = []
    for acct in accounts or tuple(a for a in index.accounts if a in index.first_known):
        cutoff = max(tier.start, index.first_known[acct])
        if tier.name in ("visible", "synthetic", "prospective"):
            cutoff = max(cutoff, index.data.data_start + cfg.min_history_ms)
        if cutoff >= tier.end:
            continue
        cps = np.arange(cutoff, tier.end, cfg.longrun_every, dtype=np.int64)
        if cfg.longrun_cap and len(cps) > cfg.longrun_cap:
            cps = cps[:cfg.longrun_cap]
        eps.append(Episode(len(eps), tier.name, Scope((acct,), cfg.longrun_view), cfg.mode,
                           index.data.data_start, int(cutoff), int(tier.end), (),
                           tuple(int(c) for c in cps), "longrun", longrun=True))
    return eps
