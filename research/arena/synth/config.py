"""Every parameter the synthetic generator uses, in one place.

Nothing here comes from a real store: scales are judgement, shaped by the
published aggregates in docs/snapshot-spec.md (cadences, lags, eras). A run
writes the fully resolved config to `truth/params.json`, so a test or a model
that "knows the truth" can rebuild the meter path from it.

Dates of injected changes and collection eras are fractions of the simulated
period, so a short run (`--days 20`) still contains every one of them. The
resolved absolute times (epoch ms) are what `truth/params.json` records.
"""
from __future__ import annotations

import copy
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

DAY_MS = 86_400_000
HOUR_MS = 3_600_000
MIN_MS = 60_000
WEEK_MS = 7 * DAY_MS

FAMILIES = ("haiku", "sonnet", "opus", "fable", "other")
WINDOW_MS = {"five_hour": 5 * HOUR_MS, "seven_day": WEEK_MS, "weekly_scoped": WEEK_MS}


# --------------------------------------------------------------------------
# Plans: how much API-equivalent spend fills each window.
# --------------------------------------------------------------------------

@dataclass
class PlanSpec:
    tier: str
    # USD of API-equivalent spend (at family weight 1) that takes the window
    # from 0 to 100 %. Points per $ = 100 / usd_full.
    usd_full_five_hour: float
    usd_full_seven_day: float
    # The premium family's weekly cap, in USD of that family's spend.
    usd_full_scoped: float


def default_plans() -> dict[str, PlanSpec]:
    return {
        "pro": PlanSpec("default_claude_pro", 6.0, 55.0, 18.0),
        "max5": PlanSpec("default_claude_max_5x", 35.0, 320.0, 110.0),
        "max20": PlanSpec("default_claude_max_20x", 140.0, 1250.0, 420.0),
    }


# --------------------------------------------------------------------------
# Models and prices.
# --------------------------------------------------------------------------

PARTS = ("input", "output", "cache_read", "cache_write_5m", "cache_write_1h")


@dataclass
class ModelSpec:
    model: str
    family: str
    # Base rates, USD per million tokens, by part.
    rates: dict[str, float]
    # Rates above the long-context threshold (whole request priced at the
    # tier once its prompt crosses it, as Anthropic bills). None = no tier.
    tier_rates: dict[str, float] | None = None
    tier_threshold: int = 200_000
    launch_frac: float | None = None      # None = available from the start
    catalog_lag_h: float = 0.0            # catalog commit after launch (launch-lag trap)


def _rates(i, o, cr, w5, w1):
    return {"input": i, "output": o, "cache_read": cr, "cache_write_5m": w5, "cache_write_1h": w1}


def default_models() -> list[ModelSpec]:
    # Ids are obviously synthetic but carry the family name, so naive parsers
    # still work. model_family is the column to trust.
    return [
        ModelSpec("claude-haiku-s1", "haiku", _rates(1.0, 5.0, 0.10, 1.25, 2.0)),
        ModelSpec("claude-sonnet-s1", "sonnet", _rates(3.0, 15.0, 0.30, 3.75, 6.0),
                  tier_rates=_rates(6.0, 22.5, 0.60, 7.5, 12.0)),
        ModelSpec("claude-opus-s1", "opus", _rates(5.0, 25.0, 0.50, 6.25, 10.0),
                  tier_rates=_rates(10.0, 37.5, 1.00, 12.5, 20.0)),
        # A model launched mid-period, within an existing family.
        ModelSpec("claude-opus-s2", "opus", _rates(5.0, 25.0, 0.50, 6.25, 10.0),
                  tier_rates=_rates(10.0, 37.5, 1.00, 12.5, 20.0),
                  launch_frac=0.58, catalog_lag_h=40.0),
        # The premium family, launched mid-period (a new model family).
        ModelSpec("claude-fable-s1", "fable", _rates(15.0, 75.0, 1.50, 18.75, 30.0),
                  tier_rates=_rates(30.0, 112.5, 3.00, 37.5, 60.0),
                  launch_frac=0.25, catalog_lag_h=30.0),
    ]


@dataclass
class PriceChange:
    model: str
    at_frac: float
    multiplier: float          # applied to every part (base and tier)
    catalog_lag_h: float = 24.0


@dataclass
class PriceError:
    """The catalog lists a wrong rate at launch and a curated correction
    arrives later (`is_correction`). Truth always uses the corrected rate."""

    model: str
    part: str
    wrong_multiplier: float
    corrected_after_days: float


# --------------------------------------------------------------------------
# Users.
# --------------------------------------------------------------------------

@dataclass
class AccountSpec:
    plan: str
    added_frac: float = 0.0           # when the account first exists (0 = from the start)


@dataclass
class BurstSpec:
    crunch_per_30d: float = 1.0       # busy spells
    crunch_days_median: float = 3.0
    crunch_mult: float = 2.2
    away_per_30d: float = 0.3         # vacations / away spells
    away_days_median: float = 3.0
    away_mult: float = 0.04


@dataclass
class UserSpec:
    name: str
    persona: str
    accounts: list[AccountSpec]
    turns_per_day: float              # target average (main + subagent turns)
    tz_offset_min: int = -240
    dst_change_frac: float | None = None
    dst_new_offset_min: int | None = None
    # Daily rhythm in local time: bumps (centre hour, width h, weight).
    day_bumps: list[tuple[float, float, float]] = field(default_factory=lambda: [(10.5, 2.0, 1.0), (15.5, 2.5, 1.0)])
    night_floor: float = 0.03
    weekday_weights: list[float] = field(default_factory=lambda: [1, 1, 1, 1, 1, 0.3, 0.25])  # Mon..Sun
    burst: BurstSpec = field(default_factory=BurstSpec)
    # Session shape.
    prompts_per_session_mean: float = 6.0
    turns_per_prompt_mean: float = 9.0
    think_gap_s_median: float = 70.0
    think_gap_sigma: float = 1.3
    tool_gap_s_median: float = 4.0
    subagent_prob: float = 0.12       # per prompt
    subagents_mean: float = 2.0       # per spawn burst
    subagent_turns_mean: float = 14.0
    # Model mix (main sessions). Premium family share applies after its launch.
    family_mix: dict[str, float] = field(default_factory=lambda: {"opus": 0.6, "sonnet": 0.35, "haiku": 0.05})
    premium_share: float = 0.15
    subagent_mix: dict[str, float] = field(default_factory=lambda: {"same": 0.35, "haiku": 0.35, "sonnet": 0.30})
    context_1m_share: float = 0.12
    output_median: float = 260.0
    output_sigma: float = 1.1
    cache_write_median: float = 1100.0
    projects: int = 8
    # What happens at 100 %: "stop" (wait for the reset), "switch" (move to
    # another account with room), "rotate" (switch proactively at a threshold
    # once the rotation controller is live).
    limit_policy: str = "stop"
    rotate_from_frac: float | None = None
    rotate_threshold_5h: float = 90.0
    rotate_threshold_7d: float = 96.0
    switch_delay_s_median: float = 90.0
    # claude.ai / other-device usage: fills the meter, never appears in turns.
    unobserved_usd_per_day: float = 0.0
    scheduled_sessions_per_day: float = 0.0
    cc_update_lag_days: float = 1.0
    entrypoints: dict[str, float] = field(default_factory=lambda: {
        "cli": 0.78, "sdk-cli": 0.08, "claude-vscode": 0.09, "claude-desktop": 0.05})


def _personas() -> list[UserSpec]:
    return [
        UserSpec(
            "U1", "power_rotator",
            [AccountSpec("max20"), AccountSpec("max20"), AccountSpec("max5"), AccountSpec("max5", 0.08)],
            turns_per_day=2300.0,
            day_bumps=[(10.0, 2.5, 1.0), (15.0, 3.0, 1.2), (21.0, 2.0, 0.8)],
            night_floor=0.06, weekday_weights=[1, 1, 1, 1, 0.95, 0.7, 0.6],
            burst=BurstSpec(crunch_per_30d=1.5, crunch_days_median=3.0, crunch_mult=2.0, away_per_30d=0.25),
            prompts_per_session_mean=7.0, subagent_prob=0.2, subagents_mean=2.5,
            family_mix={"opus": 0.7, "sonnet": 0.25, "haiku": 0.05}, premium_share=0.2,
            limit_policy="switch", rotate_from_frac=0.73, scheduled_sessions_per_day=2.0,
            cc_update_lag_days=0.3,
        ),
        UserSpec(
            "U2", "nine_to_five_upgrader", [AccountSpec("max5")], turns_per_day=520.0,
            tz_offset_min=-240, dst_change_frac=0.92, dst_new_offset_min=-300,
            day_bumps=[(10.0, 1.6, 1.0), (14.5, 1.8, 1.0)], night_floor=0.01,
            weekday_weights=[1, 1.05, 1, 1, 0.85, 0.08, 0.05],
            family_mix={"opus": 0.55, "sonnet": 0.4, "haiku": 0.05}, premium_share=0.1,
        ),
        UserSpec(
            "U3", "night_owl_adds_account", [AccountSpec("max5")], turns_per_day=600.0,
            tz_offset_min=-420,
            day_bumps=[(22.0, 2.5, 1.0), (1.0, 2.0, 0.9), (16.0, 2.0, 0.4)], night_floor=0.04,
            weekday_weights=[0.9, 1, 1, 1, 1.1, 1.2, 1.0],
            family_mix={"opus": 0.5, "sonnet": 0.45, "haiku": 0.05}, premium_share=0.12,
            limit_policy="switch",
        ),
        UserSpec(
            "U4", "bursty_premium", [AccountSpec("max20")], turns_per_day=420.0,
            tz_offset_min=60,
            day_bumps=[(11.0, 2.0, 1.0), (16.0, 2.0, 1.0)], night_floor=0.02,
            burst=BurstSpec(crunch_per_30d=2.5, crunch_days_median=2.0, crunch_mult=3.5,
                            away_per_30d=0.6, away_days_median=2.0),
            family_mix={"opus": 0.55, "sonnet": 0.4, "haiku": 0.05}, premium_share=0.45,
            output_median=320.0,
        ),
        UserSpec(
            "U5", "pro_hobbyist", [AccountSpec("pro")], turns_per_day=110.0,
            tz_offset_min=-240,
            day_bumps=[(20.0, 2.0, 1.0), (14.0, 2.5, 0.35)], night_floor=0.01,
            weekday_weights=[0.8, 0.8, 0.8, 0.8, 0.9, 1.6, 1.5],
            prompts_per_session_mean=8.0, turns_per_prompt_mean=7.0, subagent_prob=0.05,
            family_mix={"sonnet": 0.85, "haiku": 0.1, "opus": 0.05}, premium_share=0.0,
            context_1m_share=0.0, projects=3,
        ),
        UserSpec(
            "U6", "light_steady_web", [AccountSpec("max5")], turns_per_day=190.0,
            tz_offset_min=-240,
            day_bumps=[(9.0, 3.5, 1.0), (15.0, 4.0, 1.0)], night_floor=0.03,
            weekday_weights=[1, 1, 1, 1, 1, 0.6, 0.6],
            burst=BurstSpec(crunch_per_30d=0.3, away_per_30d=0.2),
            family_mix={"sonnet": 0.6, "opus": 0.35, "haiku": 0.05}, premium_share=0.05,
            unobserved_usd_per_day=4.0,
        ),
    ]


# --------------------------------------------------------------------------
# Meters, polling, recording.
# --------------------------------------------------------------------------

@dataclass
class MeterSpec:
    # Family weights on the 5h and 7d meters (points per $ multiplier).
    family_weight: dict[str, float] = field(default_factory=lambda: {
        "haiku": 0.7, "sonnet": 1.0, "opus": 1.0, "fable": 1.25, "other": 1.0})
    noise_sigma: float = 0.05         # per-request lognormal noise on converted spend
    server_lag_s: float = 15.0        # a reading reflects usage up to t - lag
    start_floor_min: dict[str, int] = field(default_factory=lambda: {"five_hour": 60, "seven_day": 60})
    seven_day_mode: str = "first_use"  # or "anchored" (fixed weekly reset per account)
    rounding: str = "floor"           # how the server turns its value into an integer
    scoped_label: str = "Fable"       # scope_model of the premium family's weekly cap
    on_scoped_cap: str = "substitute"  # premium turns fall back to `substitute_family`
    substitute_family: str = "opus"
    room_5h: float = 85.0             # an account "has room" below these
    room_7d: float = 95.0


@dataclass
class PollingSpec:
    # (from_frac, active cadence s, idle cadence s); active = a turn on that
    # account within `hot_window_s`.
    cadence_eras: list[tuple[float, float, float]] = field(default_factory=lambda: [
        (0.0, 300.0, 600.0), (0.17, 60.0, 600.0), (0.90, 15.0, 300.0)])
    hot_window_s: float = 600.0
    poll_jitter_s: float = 2.0
    missed_poll_prob: float = 0.01
    night_off_prob: float = 0.45      # the machine sleeps overnight (host tz = first user's)
    sleep_idle_min: float = 20.0      # ...but only after this long without a turn
    night_off_start_h: float = 1.5
    night_off_hours: float = 6.0
    day_gaps_per_day: float = 0.35    # Pacer not polling while the machine is up
    day_gap_min_median: float = 45.0
    blips_per_day: float = 2.0        # < 15 min: missed polls, interval stays open
    outages: list[tuple[float, float]] = field(default_factory=lambda: [(0.35, 54.0)])  # (at_frac, hours)
    interval_close_gap_min: float = 15.0
    backwards_prob: float = 0.002     # an active reading 1 pp below the last
    backwards_big_prob: float = 0.0001  # 2-5 pp below
    reset_jitter_ms_sd: float = 250.0
    reset_jitter_big_prob: float = 0.001
    twin_every_n: int = 10            # session / weekly_all twins: every n-th oauth poll in the scoped era
    cswap_users: list[str] = field(default_factory=lambda: ["U1"])
    cswap_from_frac: float = 0.45
    cswap_every_s: float = 600.0
    archive_before_frac: float = 0.25  # readings older than this have origin "archive"


@dataclass
class LagSpec:
    # Turn ingest lag (s): a lognormal body (p50 16 s, p90 95 s) plus a slow
    # tail, so p99 lands near the measured ~17 min.
    turn_median_s: float = 16.0
    turn_sigma: float = 1.39
    turn_tail_prob: float = 0.012
    turn_tail_median_s: float = 480.0
    turn_tail_sigma: float = 0.8
    turn_cap_s: float = 3 * 3600.0
    upgrade_share: float = 0.02       # streamed rows recorded first partial, then finished
    upgrade_median_s: float = 47.0
    upgrade_sigma: float = 1.5
    reading_median_s: float = 0.8
    reading_sigma: float = 0.7
    reading_tail_prob: float = 0.005
    reading_tail_max_s: float = 80.0
    cswap_median_s: float = 0.6
    cswap_sigma: float = 2.6
    activation_obs_median_s: float = 30.0
    activation_obs_sigma: float = 1.2
    cost_state_lag_s: float = 2.0
    scan_delay_s: float = 6.0         # after Pacer comes back, the scan catches up


@dataclass
class EraSpec:
    first_copy_until_frac: float = 0.12        # output recorded from the first streamed copy
    first_copy_share: float = 0.7
    transcript_cols_from_frac: float = 0.30    # is_subagent/agent_kind/finished/entrypoint/api_error null before
    cost_state_from_frac: float = 0.33
    cost_state_coverage: float = 0.85
    defect_suspect: tuple[float, float] = (0.375, 0.46)
    defect_suspect_share: float = 0.15
    defect_verified: tuple[float, float] = (0.62, 0.80)
    defect_verified_share: float = 0.5
    defect_discovered_lag_days: float = 2.0
    history_from_frac: float = 0.46            # exact t_known + turn_revisions from here
    geo_reliable_from_frac: float = 0.80       # geo/speed filled at insert from here
    geo_patch_frac: float = 0.80               # history-era rows before it get a geo_speed_patch
    project_rewrite_prob: float = 0.0005
    interrupted_share: float = 0.01
    api_error_share: float = 0.002


@dataclass
class ChangeSpec:
    """Injected changes with known dates (also written to `regimes`)."""

    plan_change: dict = field(default_factory=lambda: {"user": "U2", "account": 0, "at_frac": 0.42, "to": "max20"})
    new_account: dict = field(default_factory=lambda: {"user": "U3", "at_frac": 0.66, "plan": "max5"})
    # Anthropic tightens or loosens a window: points per $ multiplied.
    limit_policy: dict = field(default_factory=lambda: {
        "at_frac": 0.87, "multiplier": {"five_hour": 1.25, "seven_day": 1.0, "weekly_scoped": 0.8}})
    price_changes: list[PriceChange] = field(default_factory=lambda: [PriceChange("claude-fable-s1", 0.50, 2 / 3)])
    price_errors: list[PriceError] = field(default_factory=lambda: [
        PriceError("claude-fable-s1", "cache_write_1h", 0.625, 9.0)])
    adoption_days: float = 6.0                 # a launched model's share ramps up over this
    adoption_final: float = 0.9
    regimes_include_injected: bool = True


@dataclass
class SynthConfig:
    seed: int = 1
    days: int = 120
    start: str = "2026-05-04T00:00:00Z"
    users: int = 6
    scale: float = 1.0                # multiplies every user's turns_per_day
    tiers: str = "3w,3w"              # leaderboard, lockbox (lockbox is last)
    cc_version_start: tuple[int, int, int] = (2, 1, 150)
    cc_release_every_days: float = 1.3
    plans: dict[str, PlanSpec] = field(default_factory=default_plans)
    models: list[ModelSpec] = field(default_factory=default_models)
    personas: list[UserSpec] = field(default_factory=_personas)
    meter: MeterSpec = field(default_factory=MeterSpec)
    polling: PollingSpec = field(default_factory=PollingSpec)
    lags: LagSpec = field(default_factory=LagSpec)
    eras: EraSpec = field(default_factory=EraSpec)
    changes: ChangeSpec = field(default_factory=ChangeSpec)

    # ---- derived ------------------------------------------------------------

    @property
    def start_ms(self) -> int:
        return iso_to_ms(self.start)

    @property
    def end_ms(self) -> int:
        return self.start_ms + self.days * DAY_MS

    def at(self, frac: float) -> int:
        """A fraction of the period as epoch ms, rounded to the minute."""
        t = self.start_ms + frac * self.days * DAY_MS
        return int(round(t / MIN_MS) * MIN_MS)

    def tier_bounds(self) -> dict[str, int]:
        lb, lock = (parse_span(s) for s in self.tiers.split(","))
        t_end = self.end_ms
        t_lb_end = t_end - lock
        t_train = t_lb_end - lb
        if t_train <= self.start_ms + DAY_MS:
            raise ValueError(f"tiers {self.tiers!r} leave no visible period in {self.days} days")
        return {"T_start": self.start_ms, "T_train": t_train, "T_leaderboard_end": t_lb_end, "T_end": t_end}

    def user_specs(self) -> list[UserSpec]:
        """K users: the personas in order, then perturbed repeats."""
        base = self.personas
        out = []
        for i in range(self.users):
            u = copy.deepcopy(base[i % len(base)])
            if i >= len(base):
                rep = i // len(base)
                u.name = f"U{i + 1}"
                u.turns_per_day *= 0.75 + 0.15 * rep
                u.tz_offset_min = ((u.tz_offset_min + 60 * rep + 720) % 1440) - 720
            u.turns_per_day *= self.scale
            out.append(u)
        return out

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "SynthConfig":
        return _build(cls, d)

    def merged(self, overrides: dict) -> "SynthConfig":
        return SynthConfig.from_dict(deep_merge(self.to_dict(), overrides))


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def iso_to_ms(s: str) -> int:
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def ms_to_iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parse_span(s: str) -> int:
    s = s.strip().lower()
    unit = {"h": HOUR_MS, "d": DAY_MS, "w": WEEK_MS}[s[-1]]
    return int(float(s[:-1]) * unit)


def deep_merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def _build(cls, d):
    """Rebuild nested dataclasses from a plain dict (the inverse of asdict)."""
    import dataclasses
    import typing

    if not dataclasses.is_dataclass(cls):
        return d
    hints = typing.get_type_hints(cls)
    kwargs = {}
    for f in dataclasses.fields(cls):
        if f.name not in d:
            continue
        kwargs[f.name] = _coerce(hints[f.name], d[f.name])
    return cls(**kwargs)


def _coerce(tp, v):
    import dataclasses
    import typing

    origin = typing.get_origin(tp)
    args = typing.get_args(tp)
    if dataclasses.is_dataclass(tp) and isinstance(v, dict):
        return _build(tp, v)
    if origin is list and args:
        return [_coerce(args[0], x) for x in v]
    if origin is dict and len(args) == 2:
        return {k: _coerce(args[1], x) for k, x in v.items()}
    if origin is tuple and isinstance(v, list):
        return tuple(v)
    if origin in (typing.Union, getattr(__import__("types"), "UnionType", None)):
        for a in args:
            if a is type(None):
                continue
            try:
                return _coerce(a, v)
            except Exception:  # pragma: no cover - fall through to the raw value
                pass
    return v


def load_config(path: str | None, **overrides) -> SynthConfig:
    cfg = SynthConfig()
    if path:
        with open(path) as fh:
            cfg = cfg.merged(json.load(fh))
    clean = {k: v for k, v in overrides.items() if v is not None}
    if clean:
        cfg = cfg.merged(clean)
    return cfg
