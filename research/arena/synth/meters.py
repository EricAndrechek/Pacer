"""The server side: per-account meters, their cycles, and what happens at 100 %.

A window's cycle starts at the first use after the previous reset (floored to
`start_floor_min`) and resets one window later. Utilisation is converted
spend since the cycle start:

    points = cost_usd × (100 / usd_full[plan][window]) × family_weight[family]
             × policy_multiplier[window](t)

The premium family's weekly cap (`weekly_scoped`) shares the 7-day cycle and
counts only that family's spend: points = cost × 100 / usd_full_scoped × policy.

`util_clean` is that sum exactly (the noiseless path in truth/meter_true);
`util_actual` multiplies each request by lognormal noise and adds usage the
transcripts never see. The actual value is what the server enforces and what
readings report (as integers). At 100 the account refuses requests until the
window resets: the user waits (limit hits) or switches account, by policy.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .activity import UserActivity
from .catalog import Catalog
from .config import MIN_MS, WINDOW_MS, SynthConfig, UserSpec

W5, W7 = 0, 1
WINDOWS = ("five_hour", "seven_day")


@dataclass
class Account:
    gid: int                     # global index (label = A{gid+1})
    user: int
    local: int                   # index within the user's accounts
    added: int
    plans: list[tuple[int, str]]  # (from_ms, plan), sorted

    @property
    def label(self) -> str:
        return f"A{self.gid + 1}"

    def plan_at(self, t: int) -> str:
        p = self.plans[0][1]
        for t0, name in self.plans:
            if t >= t0:
                p = name
        return p


def build_accounts(cfg: SynthConfig, users: list[UserSpec]) -> list[Account]:
    """Every account, labelled A1… in first-seen order (ties by user, then
    account order). Injected changes (plan change, new account) attach here."""
    ch = cfg.changes
    names = [u.name for u in users]
    raw = []
    for ui, u in enumerate(users):
        for ai, a in enumerate(u.accounts):
            raw.append([ui, ai, cfg.at(a.added_frac), [(cfg.at(a.added_frac), a.plan)]])
    # New account (falls back to the last user when its persona is absent).
    na_user = names.index(ch.new_account["user"]) if ch.new_account["user"] in names else len(users) - 1
    n_local = sum(1 for r in raw if r[0] == na_user)
    t_new = cfg.at(ch.new_account["at_frac"])
    raw.append([na_user, n_local, t_new, [(t_new, ch.new_account["plan"])]])
    # Plan change.
    pc_user = names.index(ch.plan_change["user"]) if ch.plan_change["user"] in names else 0
    for r in raw:
        if r[0] == pc_user and r[1] == ch.plan_change["account"]:
            r[3].append((cfg.at(ch.plan_change["at_frac"]), ch.plan_change["to"]))
    raw.sort(key=lambda r: (r[2], r[0], r[1]))
    return [Account(gid=i, user=r[0], local=r[1], added=r[2], plans=sorted(r[3])) for i, r in enumerate(raw)]


class _State:
    __slots__ = ("first", "start", "reset", "act", "clean", "cyc", "act_s", "clean_s", "hit")

    def __init__(self):
        self.first = [None, None]
        self.start = [None, None]
        self.reset = [None, None]
        self.act = [0.0, 0.0]
        self.clean = [0.0, 0.0]
        self.cyc = [-1, -1]
        self.act_s = 0.0
        self.clean_s = 0.0
        self.hit = [False, False, False]


@dataclass
class MeterResult:
    # candidate turns, concatenated over users in user order
    kept: np.ndarray
    account: np.ndarray              # gid, -1 if dropped
    model: np.ndarray                # final model (after a premium substitution)
    substituted: np.ndarray
    cost: np.ndarray                 # USD at the billed rate, final model
    noise: np.ndarray
    # cycles per window kind: list of dicts (weekly_scoped mirrors seven_day)
    cycles: dict[str, list[dict]]
    # increments per window kind: dict of arrays
    inc: dict[str, dict[str, np.ndarray]]
    limit_hits: list[dict]
    activations: list[dict]          # who was active when
    switches: list[dict]
    unobserved: list[dict]


def _floor(t: int, step: int) -> int:
    return t - t % step if step > 0 else t


def run_meters(cfg: SynthConfig, cat: Catalog, users: list[UserSpec], acts: list[UserActivity],
               accounts: list[Account], cost: list[np.ndarray], cost_alt: list[np.ndarray],
               user_rngs: list[np.random.Generator]) -> MeterResult:
    """user_rngs: one stream per user, so adding a user changes nobody else."""
    m = cfg.meter
    plans = cfg.plans
    pol_at = cfg.at(cfg.changes.limit_policy["at_frac"])
    pol_mult = cfg.changes.limit_policy["multiplier"]
    fw = m.family_weight
    floors = [m.start_floor_min["five_hour"] * MIN_MS, m.start_floor_min["seven_day"] * MIN_MS]
    wins = [WINDOW_MS["five_hour"], WINDOW_MS["seven_day"]]
    anchored = m.seven_day_mode == "anchored"
    fable_models = set(cat.family_models("fable"))
    fam_of = cat.family

    states = [_State() for _ in accounts]
    by_user: dict[int, list[Account]] = {}
    for a in accounts:
        by_user.setdefault(a.user, []).append(a)

    cycles = {"five_hour": [], "seven_day": [], "weekly_scoped": []}
    inc = {k: {"acc": [], "t": [], "cyc": [], "d_clean": [], "d_act": [], "clean": [], "act": [],
               "src": [], "ref": []} for k in cycles}
    limit_hits, activations, switches, unobserved = [], [], [], []

    def factor(a: Account, w: int, t: int) -> float:
        p = plans[a.plan_at(t)]
        full = p.usd_full_five_hour if w == W5 else p.usd_full_seven_day
        mult = pol_mult[WINDOWS[w]] if t >= pol_at else 1.0
        return 100.0 / full * mult

    def factor_s(a: Account, t: int) -> float:
        mult = pol_mult["weekly_scoped"] if t >= pol_at else 1.0
        return 100.0 / plans[a.plan_at(t)].usd_full_scoped * mult

    def close(a: Account, w: int):
        s = states[a.gid]
        if s.cyc[w] < 0:
            return
        c = cycles[WINDOWS[w]][s.cyc[w]]
        c["final_act"], c["final_clean"] = s.act[w], s.clean[w]
        if w == W7:
            cs = cycles["weekly_scoped"][s.cyc[w]]
            cs["final_act"], cs["final_clean"] = s.act_s, s.clean_s
        s.first[w] = s.start[w] = s.reset[w] = None
        s.act[w] = s.clean[w] = 0.0
        s.cyc[w] = -1
        s.hit[w] = False
        if w == W7:
            s.act_s = s.clean_s = 0.0
            s.hit[2] = False

    def refresh(a: Account, t: int):
        s = states[a.gid]
        for w in (W5, W7):
            if s.reset[w] is not None and t >= s.reset[w]:
                close(a, w)

    def open_cycle(a: Account, w: int, t: int):
        s = states[a.gid]
        if w == W7 and anchored:
            anchor = _floor(a.added, floors[W7])
            k = (t - anchor) // wins[W7]
            start = anchor + k * wins[W7]
        else:
            start = _floor(t, floors[w])
        s.first[w], s.start[w], s.reset[w] = t, start, start + wins[w]
        s.cyc[w] = len(cycles[WINDOWS[w]])
        rec = {"acc": a.gid, "first_use": t, "start": start, "reset": start + wins[w],
               "hit_t": None, "final_act": 0.0, "final_clean": 0.0}
        cycles[WINDOWS[w]].append(rec)
        if w == W7:
            cycles["weekly_scoped"].append(dict(rec))

    def add(a: Account, t: int, usd: float, fam: str, noise: float, src: int, ref: int):
        s = states[a.gid]
        for w in (W5, W7):
            if s.cyc[w] < 0:
                open_cycle(a, w, t)
            pts = usd * factor(a, w, t) * fw.get(fam, 1.0)
            s.clean[w] += pts
            s.act[w] += pts * noise
            d = inc[WINDOWS[w]]
            d["acc"].append(a.gid); d["t"].append(t); d["cyc"].append(s.cyc[w])
            d["d_clean"].append(pts); d["d_act"].append(pts * noise)
            d["clean"].append(s.clean[w]); d["act"].append(s.act[w]); d["src"].append(src); d["ref"].append(ref)
            if not s.hit[w] and s.act[w] >= 100.0:
                s.hit[w] = True
                cycles[WINDOWS[w]][s.cyc[w]]["hit_t"] = t
        if fam == "fable":
            pts = usd * factor_s(a, t)
            s.clean_s += pts
            s.act_s += pts * noise
            d = inc["weekly_scoped"]
            d["acc"].append(a.gid); d["t"].append(t); d["cyc"].append(s.cyc[W7])
            d["d_clean"].append(pts); d["d_act"].append(pts * noise)
            d["clean"].append(s.clean_s); d["act"].append(s.act_s); d["src"].append(src); d["ref"].append(ref)
            if not s.hit[2] and s.act_s >= 100.0:
                s.hit[2] = True
                cycles["weekly_scoped"][s.cyc[W7]]["hit_t"] = t

    def blocked_until(a: Account) -> int | None:
        s = states[a.gid]
        until = None
        for w in (W5, W7):
            if s.cyc[w] >= 0 and s.act[w] >= 100.0:
                until = s.reset[w] if until is None else max(until, s.reset[w])
        return until

    def util(a: Account, w: int) -> float:
        s = states[a.gid]
        return s.act[w] if s.cyc[w] >= 0 else 0.0

    def has_room(b: Account, t: int) -> bool:
        refresh(b, t)
        return util(b, W5) < m.room_5h and util(b, W7) < m.room_7d

    def best_alt(ui: int, a: Account, t: int) -> Account | None:
        cands = [b for b in by_user.get(ui, []) if b.gid != a.gid and b.added <= t and has_room(b, t)]
        if not cands:
            return None
        return min(cands, key=lambda b: (util(b, W5), util(b, W7), b.gid))

    n_all = sum(len(x.t) for x in acts)
    kept = np.zeros(n_all, dtype=bool)
    account = np.full(n_all, -1, dtype=np.int32)
    model_out = np.concatenate([x.model for x in acts]) if acts else np.zeros(0, np.int16)
    substituted = np.zeros(n_all, dtype=bool)
    cost_out = np.concatenate(cost) if cost else np.zeros(0)
    sig = m.noise_sigma
    noise_all = np.ones(n_all)

    offset = 0
    for ui, (u, ua) in enumerate(zip(users, acts)):
        mine = sorted(by_user.get(ui, []), key=lambda a: (a.added, a.gid))
        n = len(ua.t)
        if not mine:
            offset += n
            continue
        rng = user_rngs[ui]
        if sig > 0:
            noise_all[offset:offset + n] = rng.lognormal(-sig * sig / 2, sig, size=n)
        rotate_at = cfg.at(u.rotate_from_frac) if u.rotate_from_frac is not None else None
        nu = len(ua.u_t)
        u_noise = rng.lognormal(-sig * sig / 2, sig, size=nu) if sig > 0 else np.ones(nu)
        delays = rng.lognormal(np.log(u.switch_delay_s_median), 0.8, size=n + 1)
        # Events in time order: turns (kind 0) and unobserved usage (kind 1).
        ev_t = np.concatenate([ua.t, ua.u_t])
        ev_k = np.concatenate([np.zeros(n, np.int8), np.ones(nu, np.int8)])
        ev_i = np.concatenate([np.arange(n), np.arange(nu)])
        order = np.lexsort((ev_i, ev_k, ev_t))
        ev_t, ev_k, ev_i = ev_t[order].tolist(), ev_k[order].tolist(), ev_i[order].tolist()
        sess = ua.session.tolist()
        mdl = ua.model.tolist()
        alt = ua.alt_model.tolist()
        c_true = cost[ui].tolist()
        c_alt = cost_alt[ui].tolist()
        u_cost = ua.u_cost.tolist()

        active = mine[0]
        act_rec = {"user": ui, "acc": active.gid, "t": active.added, "t_decision": active.added,
                   "evidence": "first_seen", "t_end": None}
        activations.append(act_rec)
        pending = None                       # (account, t_effective, kind)
        hits_seen: set = set()
        n_delay = 0
        # An account added later is why the user added it: they move onto it.
        joins = [b for b in mine[1:] if b.added > active.added]

        def do_switch(to: Account, t_eff: int, kind: str, t_dec: int, ui: int = ui):
            nonlocal active, act_rec
            act_rec["t_end"] = t_eff
            switches.append({"user": ui, "from": active.gid, "to": to.gid, "t": t_eff,
                             "t_decision": t_dec, "kind": kind})
            active = to
            act_rec = {"user": ui, "acc": to.gid, "t": t_eff, "t_decision": t_dec,
                       "evidence": {"rotate": "rotation", "new_account": "new_account"}.get(kind, "switch"),
                       "t_end": None}
            activations.append(act_rec)

        for t, k, i in zip(ev_t, ev_k, ev_i):
            while joins and t >= joins[0].added:
                b = joins.pop(0)
                if b.gid != active.gid:
                    do_switch(b, b.added, "new_account", b.added)
                    pending = None
            if pending is not None and t >= pending[1]:
                do_switch(pending[0], pending[1], pending[2], pending[3])
                pending = None
            a = active
            refresh(a, t)
            if k == 1:
                if blocked_until(a) is None:
                    add(a, t, float(u_cost[i]), "other", float(u_noise[i]), 1, i)
                    unobserved.append({"user": ui, "acc": a.gid, "t": t, "cost": float(u_cost[i]),
                                       "noise": float(u_noise[i])})
                continue
            gi = offset + i
            policy = u.limit_policy
            if rotate_at is not None and t >= rotate_at and policy == "switch":
                policy = "rotate"
            if policy == "rotate" and pending is None:
                if util(a, W5) >= u.rotate_threshold_5h or util(a, W7) >= u.rotate_threshold_7d:
                    b = best_alt(ui, a, t)
                    if b is not None and util(b, W5) < u.rotate_threshold_5h - 20:
                        tick = ((t // (5 * MIN_MS)) + 1) * 5 * MIN_MS + int(rng.integers(0, 30_000))
                        pending = (b, tick, "rotate", t)
            until = blocked_until(a)
            if until is not None:
                key = (a.gid, sess[i], until)
                if key not in hits_seen:
                    hits_seen.add(key)
                    limit_hits.append({"user": ui, "acc": a.gid, "t": t, "session": sess[i], "model": mdl[i]})
                if policy in ("switch", "rotate") and pending is None:
                    b = best_alt(ui, a, t)
                    if b is not None:
                        d = int(delays[n_delay % len(delays)] * 1000)
                        n_delay += 1
                        pending = (b, t + d, "switch", t)
                continue
            mi, usd = mdl[i], c_true[i]
            if mi in fable_models and states[a.gid].cyc[W7] >= 0 and states[a.gid].act_s >= 100.0 \
                    and m.on_scoped_cap == "substitute" and alt[i] >= 0:
                mi, usd = alt[i], c_alt[i]
                substituted[gi] = True
                model_out[gi] = mi
                cost_out[gi] = usd
            add(a, t, usd, fam_of[mi], float(noise_all[gi]), 0, gi)
            kept[gi] = True
            account[gi] = a.gid
        offset += n

    # Close every open cycle so its final values are recorded.
    for a in accounts:
        for w in (W5, W7):
            close(a, w)

    inc_np = {}
    for kname, d in inc.items():
        inc_np[kname] = {
            "acc": np.asarray(d["acc"], np.int32), "t": np.asarray(d["t"], np.int64),
            "cyc": np.asarray(d["cyc"], np.int32), "d_clean": np.asarray(d["d_clean"], np.float64),
            "d_act": np.asarray(d["d_act"], np.float64), "clean": np.asarray(d["clean"], np.float64),
            "act": np.asarray(d["act"], np.float64), "src": np.asarray(d["src"], np.int8),
            "ref": np.asarray(d["ref"], np.int64),
        }
    return MeterResult(kept=kept, account=account, model=model_out, substituted=substituted,
                       cost=cost_out, noise=noise_all, cycles=cycles, inc=inc_np,
                       limit_hits=limit_hits, activations=activations, switches=switches,
                       unobserved=unobserved)
