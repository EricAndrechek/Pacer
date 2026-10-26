"""What a user does: sessions, prompts, turn chains, subagents, and usage the
meter sees but the transcripts don't (claude.ai, another device).

Sessions arrive as an inhomogeneous Poisson process: a daily rhythm in the
user's local time, a weekly rhythm, busy spells and away spells. A session is
a run of prompts; each prompt starts a chain of agentic turns, sometimes with
a burst of subagents. Every main-chain turn re-reads the session's context
from the cache, so cache reads grow through a session until it compacts;
a long pause past the cache TTL forces the whole context to be written again.

Everything here is a *candidate*: the meter loop (meters.py) decides which
turns actually happen (an account at 100 % refuses them) and on which account.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .catalog import Catalog
from .config import DAY_MS, HOUR_MS, MIN_MS, SynthConfig, UserSpec

AGENT_KINDS = ("main", "fork", "builtin", "custom")
PROMPT_ORIGINS = ("human", "tool_result", "scheduled", "task_notification", "compact", "unknown")
BUILTIN_TYPES = ("general-purpose", "Explore", "Plan")
EPOCH_DOW_OFFSET = 3   # 1970-01-01 was a Thursday; Monday = 0


def tz_offset_min(u: UserSpec, cfg: SynthConfig, t: np.ndarray | int):
    if u.dst_change_frac is None:
        return np.full(np.shape(t), u.tz_offset_min, dtype=np.int64) if np.ndim(t) else u.tz_offset_min
    at = cfg.at(u.dst_change_frac)
    return np.where(np.asarray(t) >= at, u.dst_new_offset_min, u.tz_offset_min)


def rhythm(u: UserSpec, cfg: SynthConfig, t: np.ndarray) -> np.ndarray:
    """Relative activity at times t from the daily and weekly rhythm only."""
    local = t + tz_offset_min(u, cfg, t).astype(np.int64) * MIN_MS
    hour = (local % DAY_MS) / HOUR_MS
    dow = ((local // DAY_MS) + EPOCH_DOW_OFFSET) % 7
    prof = np.full(len(t), u.night_floor, dtype=np.float64)
    for centre, width, weight in u.day_bumps:
        d = np.abs(hour - centre)
        d = np.minimum(d, 24 - d)
        prof += weight * np.exp(-0.5 * (d / width) ** 2)
    return prof * np.asarray(u.weekday_weights, dtype=np.float64)[dow]


@dataclass
class Spell:
    start: int
    end: int
    mult: float
    kind: str


def spells(u: UserSpec, cfg: SynthConfig, rng: np.random.Generator) -> list[Spell]:
    out = []
    span = cfg.end_ms - cfg.start_ms
    for kind, rate, med, mult in (
        ("crunch", u.burst.crunch_per_30d, u.burst.crunch_days_median, u.burst.crunch_mult),
        ("away", u.burst.away_per_30d, u.burst.away_days_median, u.burst.away_mult),
    ):
        n = rng.poisson(rate * span / (30 * DAY_MS))
        for _ in range(n):
            s = cfg.start_ms + int(rng.uniform(0, span))
            dur = int(rng.lognormal(np.log(med), 0.4) * DAY_MS)
            out.append(Spell(s, s + dur, mult, kind))
    return sorted(out, key=lambda x: x.start)


def spell_mult(sp: list[Spell], t: np.ndarray) -> np.ndarray:
    m = np.ones(len(t), dtype=np.float64)
    for s in sp:
        m[(t >= s.start) & (t < s.end)] *= s.mult
    return m


def expected_turns_per_session(u: UserSpec) -> float:
    per_prompt = u.turns_per_prompt_mean + u.subagent_prob * u.subagents_mean * u.subagent_turns_mean
    return u.prompts_per_session_mean * per_prompt


def poisson_times(rate_per_day: float, weight_fn, cfg: SynthConfig, rng: np.random.Generator,
                  bin_ms: int = 5 * MIN_MS) -> np.ndarray:
    """Event times of an inhomogeneous Poisson process with mean
    `rate_per_day` (before spells) shaped by weight_fn(t) (mean 1 over a
    typical week)."""
    edges = np.arange(cfg.start_ms, cfg.end_ms, bin_ms, dtype=np.int64)
    lam = rate_per_day * weight_fn(edges + bin_ms // 2) * (bin_ms / DAY_MS)
    counts = rng.poisson(lam)
    starts = np.repeat(edges, counts)
    return np.sort(starts + rng.integers(0, bin_ms, size=starts.size))


class _Draws:
    """Chunked random draws consumed one at a time from a Python loop."""

    def __init__(self, rng: np.random.Generator, fn, chunk: int = 65_536):
        self.rng, self.fn, self.chunk = rng, fn, chunk
        self.buf: list[float] = []
        self.i = 0

    def __call__(self) -> float:
        if self.i >= len(self.buf):
            self.buf = self.fn(self.rng, self.chunk).tolist()
            self.i = 0
        v = self.buf[self.i]
        self.i += 1
        return v


@dataclass
class UserActivity:
    user: int
    spells: list[Spell]
    # sessions
    s_start: np.ndarray
    s_project: np.ndarray        # index into the user's projects
    s_entry: np.ndarray          # index into entrypoint names
    s_cc_patch: np.ndarray
    s_subdir: np.ndarray
    s_scheduled: np.ndarray
    s_model: np.ndarray          # main model index
    # prompts
    p_t: np.ndarray
    p_session: np.ndarray
    p_origin: np.ndarray
    # candidate turns
    t: np.ndarray
    session: np.ndarray
    model: np.ndarray
    alt_model: np.ndarray        # substitute when the premium cap is full; -1 = none
    is_sub: np.ndarray
    kind: np.ndarray             # AGENT_KINDS index
    tokens: np.ndarray           # [n, 5] input, output(true), cache_read, cw5m, cw1h
    interrupted: np.ndarray
    api_error: np.ndarray
    # spawns
    sp_t: np.ndarray
    sp_session: np.ndarray
    sp_kind: np.ndarray          # AGENT_KINDS index (fork/builtin/custom)
    sp_builtin: np.ndarray       # BUILTIN_TYPES index or -1
    sp_model: np.ndarray
    sp_depth: np.ndarray
    # unobserved usage
    u_t: np.ndarray
    u_cost: np.ndarray
    entrypoints: tuple[str, ...]


def _pick_model(cat: Catalog, family: str, t: int, u01: float, cfg: SynthConfig) -> int:
    """The family's model at t: the newest launched one ramps in over
    `adoption_days` to `adoption_final`; otherwise the one before it."""
    cands = [i for i in cat.family_models(family) if cat.launch[i] <= t]
    if not cands:
        return -1
    cands.sort(key=lambda i: cat.launch[i])
    if len(cands) == 1:
        return cands[0]
    newest = cands[-1]
    age = (t - cat.launch[newest]) / DAY_MS
    share = cfg.changes.adoption_final * min(1.0, age / max(cfg.changes.adoption_days, 1e-9))
    return newest if u01 < share else cands[-2]


def generate_user(ui: int, u: UserSpec, cfg: SynthConfig, cat: Catalog, rng: np.random.Generator) -> UserActivity:
    sp = spells(u, cfg, rng)
    week = np.arange(cfg.start_ms, cfg.start_ms + 7 * DAY_MS, 5 * MIN_MS, dtype=np.int64)
    norm = float(rhythm(u, cfg, week).mean())

    def weight(t):
        return rhythm(u, cfg, t) / norm * spell_mult(sp, t)

    rate = u.turns_per_day / expected_turns_per_session(u)
    s_start = poisson_times(rate, weight, cfg, rng)
    n_human = s_start.size

    # Scheduled sessions: fixed local times, 3 h apart from 03:00.
    sched = []
    if u.scheduled_sessions_per_day > 0:
        n_per = int(round(u.scheduled_sessions_per_day))
        day0 = cfg.start_ms - cfg.start_ms % DAY_MS
        for d in range(cfg.days + 1):
            for k in range(n_per):
                local_h = 3.0 + 3.0 * k
                t = day0 + d * DAY_MS + int(local_h * HOUR_MS) - int(tz_offset_min(u, cfg, day0 + d * DAY_MS)) * MIN_MS
                t += int(rng.normal(0, 4 * MIN_MS))
                if cfg.start_ms <= t < cfg.end_ms and rng.uniform() < 0.9:
                    sched.append(t)
    s_start = np.concatenate([s_start, np.array(sched, dtype=np.int64)])
    s_sched = np.concatenate([np.zeros(n_human, bool), np.ones(len(sched), bool)])
    order = np.argsort(s_start, kind="stable")
    s_start, s_sched = s_start[order], s_sched[order]
    ns = s_start.size

    # Per-session attributes.
    proj_p = 1.0 / np.arange(1, u.projects + 1) ** 1.1
    s_project = rng.choice(u.projects, size=ns, p=proj_p / proj_p.sum())
    entry_names = tuple(u.entrypoints)
    ep = np.array([u.entrypoints[k] for k in entry_names])
    s_entry = rng.choice(len(entry_names), size=ns, p=ep / ep.sum())
    s_subdir = rng.choice(4, size=ns, p=[0.8, 0.15, 0.04, 0.01]).astype(np.int16)
    release = (s_start - int(u.cc_update_lag_days * DAY_MS) - cfg.start_ms) / (cfg.cc_release_every_days * DAY_MS)
    s_cc_patch = cfg.cc_version_start[2] + np.floor(np.maximum(release, 0)).astype(np.int64)
    ctx1m = rng.uniform(size=ns) < u.context_1m_share
    s_compact_at = np.where(ctx1m, rng.uniform(600_000, 700_000, ns), rng.uniform(140_000, 165_000, ns))

    # Main model per session.
    fams = list(u.family_mix)
    fw = np.array([u.family_mix[f] for f in fams], dtype=np.float64)
    fw /= fw.sum()
    prem_launch = min((cat.launch[i] for i in cat.family_models("fable")), default=None)
    s_model = np.empty(ns, dtype=np.int16)
    fam_draw = rng.uniform(size=ns)
    prem_draw = rng.uniform(size=ns)
    mdl_draw = rng.uniform(size=ns)
    cum = np.cumsum(fw)
    for i in range(ns):
        t = int(s_start[i])
        if prem_launch is not None and t >= prem_launch and prem_draw[i] < u.premium_share:
            fam = "fable"
        else:
            fam = fams[min(int(np.searchsorted(cum, fam_draw[i], side="right")), len(fams) - 1)]
        s_model[i] = _pick_model(cat, fam, t, mdl_draw[i], cfg)

    # Draw pools.
    lg = lambda med, sig: (lambda r, n: r.lognormal(np.log(med), sig, n))  # noqa: E731
    d_out = _Draws(rng, lg(u.output_median, u.output_sigma))
    d_write = _Draws(rng, lg(u.cache_write_median, 1.2))
    d_inp = _Draws(rng, lg(8.0, 1.5))
    d_tool = _Draws(rng, lg(u.tool_gap_s_median, 1.0))
    d_think = _Draws(rng, lg(u.think_gap_s_median, u.think_gap_sigma))
    d_u = _Draws(rng, lambda r, n: r.uniform(size=n))

    def negbin(mean_extra: float, r: float) -> int:
        if mean_extra <= 0:
            return 0
        return int(rng.negative_binomial(r, r / (r + mean_extra)))

    # Output lists.
    T, S, M, SUB, K, TOK, INT, ERR = [], [], [], [], [], [], [], []
    PT, PS, PO = [], [], []
    SPT, SPS, SPK, SPB, SPM, SPD = [], [], [], [], [], []
    sonnet_now = lambda t: _pick_model(cat, "sonnet", t, 0.0, cfg)  # noqa: E731
    haiku_now = lambda t: _pick_model(cat, "haiku", t, 0.0, cfg)    # noqa: E731
    sub_fams = list(u.subagent_mix)
    sub_w = np.cumsum([u.subagent_mix[f] for f in sub_fams])
    sub_w = sub_w / sub_w[-1]
    er = cfg.eras
    tok_rate = 70.0  # output tokens per second

    def gen_ms(out: float) -> int:
        return int((1.2 + out / tok_rate) * 1000)

    def run_subagent(si: int, t0: int, model: int, kind: int, main_ctx: float, n_turns: int) -> int:
        ctx = main_ctx if kind == 1 else 8_000 + 7_000 * d_u()
        t = t0
        cached = kind == 1          # a fork reuses the parent's cache
        for k in range(n_turns):
            out = min(max(d_out() * 0.8, 1.0), 32_000.0)
            new = min(d_write() * 0.9, 50_000.0)
            inp = max(1.0, d_inp())
            t += gen_ms(out)
            if not cached:
                cr, w = 0.0, ctx + new
                cached = True
            else:
                cr, w = ctx, new
            if d_u() < er.api_error_share:
                T.append(t); S.append(si); M.append(model); SUB.append(True); K.append(kind)
                TOK.append((inp, 0.0, 0.0, 0.0, 0.0)); INT.append(False); ERR.append(True)
                continue
            T.append(t); S.append(si); M.append(model); SUB.append(True); K.append(kind)
            TOK.append((inp, out, cr, w, 0.0)); INT.append(False); ERR.append(False)
            ctx += new + out
            t += int(d_tool() * 1000)
        return t

    for si in range(ns):
        model = int(s_model[si])
        if model < 0:
            continue
        sched_s = bool(s_sched[si])
        n_prompts = 1 if sched_s else 1 + negbin(u.prompts_per_session_mean - 1, 1.2)
        base_ctx = 16_000 + 12_000 * d_u()
        ctx = base_ctx
        last_main = None
        t = int(s_start[si])
        compact_at = float(s_compact_at[si])
        for p in range(n_prompts):
            PT.append(t); PS.append(si); PO.append(2 if (sched_s and p == 0) else 0)
            t += int(1000 + 2000 * d_u())
            chain = 25 + negbin(10, 2.0) if sched_s else 1 + negbin(u.turns_per_prompt_mean - 1, 1.5)
            spawn_at = int(d_u() * chain) if d_u() < u.subagent_prob else -1
            for k in range(chain):
                out = min(max(d_out(), 1.0), 32_000.0)
                if k == chain - 1:
                    out = min(out * 1.5, 32_000.0)
                new = min(d_write(), 60_000.0)
                inp = max(1.0, d_inp())
                t += gen_ms(out)
                hit = last_main is not None and (t - last_main) <= HOUR_MS
                cr, w = (ctx, new) if hit else (0.0, ctx + new)
                last_main = t
                interrupted = d_u() < er.interrupted_share
                if interrupted:
                    out = 1.0 + 39.0 * d_u()
                if d_u() < er.api_error_share:
                    T.append(t); S.append(si); M.append(model); SUB.append(False); K.append(0)
                    TOK.append((inp, 0.0, 0.0, 0.0, 0.0)); INT.append(False); ERR.append(True)
                else:
                    T.append(t); S.append(si); M.append(model); SUB.append(False); K.append(0)
                    TOK.append((inp, out, cr, 0.0, w)); INT.append(interrupted); ERR.append(False)
                    ctx += new + out
                if interrupted:
                    break
                if ctx > compact_at:
                    # /compact: a summary turn, then the context restarts small
                    # and the next turn writes it to the cache again.
                    t += int(d_tool() * 1000)
                    PT.append(t); PS.append(si); PO.append(4)
                    summ = 3_000 + 6_000 * d_u()
                    t += gen_ms(summ)
                    T.append(t); S.append(si); M.append(model); SUB.append(False); K.append(0)
                    TOK.append((max(1.0, d_inp()), summ, ctx, 0.0, 0.0)); INT.append(False); ERR.append(False)
                    ctx = base_ctx + summ
                    last_main = None
                if k == spawn_at:
                    n_sub = 1 + int(rng.poisson(max(u.subagents_mean - 1, 0)))
                    t_end = t
                    for _ in range(n_sub):
                        r = d_u()
                        kind = 1 if r < 0.1 else (3 if r < 0.3 else 2)
                        f = sub_fams[min(int(np.searchsorted(sub_w, d_u(), side="right")), len(sub_fams) - 1)]
                        if kind == 1 or f == "same":
                            sm = model
                        elif f == "haiku":
                            sm = haiku_now(t)
                        else:
                            sm = sonnet_now(t)
                        t0 = t + int(500 + 2500 * d_u())
                        SPT.append(t0); SPS.append(si); SPK.append(kind)
                        SPB.append(int(d_u() * len(BUILTIN_TYPES)) if kind == 2 else -1)
                        SPM.append(sm); SPD.append(2 if d_u() < 0.03 else 1)
                        n_t = 1 + negbin(u.subagent_turns_mean - 1, 2.0)
                        t_end = max(t_end, run_subagent(si, t0, sm, kind, ctx, n_t))
                    t = t_end + int(d_tool() * 1000)
                t += int(d_tool() * 1000)
            t += int(d_think() * 1000)

    t_arr = np.asarray(T, dtype=np.int64)
    model_arr = np.asarray(M, dtype=np.int16)
    tok = np.asarray(TOK, dtype=np.float64).reshape(-1, 5).round().astype(np.int64)
    keep = t_arr < cfg.end_ms
    # Premium turns fall back to the substitute family at the same moment.
    fable_set = set(cat.family_models("fable"))
    alt = np.full(len(t_arr), -1, dtype=np.int16)
    sub_fam = cfg.meter.substitute_family
    alt_draw = rng.uniform(size=len(t_arr))
    for i in np.flatnonzero(np.isin(model_arr, list(fable_set))):
        alt[i] = _pick_model(cat, sub_fam, int(t_arr[i]), alt_draw[i], cfg)

    # Unobserved usage: small chat-sized costs during the user's waking hours.
    if u.unobserved_usd_per_day > 0:
        med, sig = 0.25, 0.8
        mean_cost = med * np.exp(sig ** 2 / 2)
        u_t = poisson_times(u.unobserved_usd_per_day / mean_cost, weight, cfg, rng)
        u_cost = rng.lognormal(np.log(med), sig, size=u_t.size)
    else:
        u_t, u_cost = np.zeros(0, np.int64), np.zeros(0, np.float64)

    return UserActivity(
        user=ui, spells=sp,
        s_start=s_start, s_project=s_project, s_entry=s_entry, s_cc_patch=s_cc_patch,
        s_subdir=s_subdir, s_scheduled=s_sched, s_model=s_model,
        p_t=np.asarray(PT, np.int64), p_session=np.asarray(PS, np.int32), p_origin=np.asarray(PO, np.int8),
        t=t_arr[keep], session=np.asarray(S, np.int32)[keep], model=model_arr[keep], alt_model=alt[keep],
        is_sub=np.asarray(SUB, bool)[keep], kind=np.asarray(K, np.int8)[keep], tokens=tok[keep],
        interrupted=np.asarray(INT, bool)[keep], api_error=np.asarray(ERR, bool)[keep],
        sp_t=np.asarray(SPT, np.int64), sp_session=np.asarray(SPS, np.int32), sp_kind=np.asarray(SPK, np.int8),
        sp_builtin=np.asarray(SPB, np.int8), sp_model=np.asarray(SPM, np.int16), sp_depth=np.asarray(SPD, np.int16),
        u_t=u_t, u_cost=u_cost, entrypoints=entry_names,
    )
