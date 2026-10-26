"""split.accounts: one account's share of its group's spend per hour.

A user with several accounts works on one at a time and moves to another when
a limit is hit, so the hourly share is close to 0 or 1 in long runs, not a
blend. The forecast is a regime simulation:

- the *dominant* account now: the one with most spend over the latest active
  hours (recency weighted);
- per path, the dominant account persists hour by hour and switches with a
  per-hour hazard learned from the history's own switches (shrunk to a prior);
  a switch goes to another account in proportion to its long-run spend;
- an account whose 5-hour or 7-day meter reads at the limit is *blocked* until
  that window's reset: it cannot be dominant then (the user cannot use it), and
  the dominant account at the limit forces a switch;
- the share in an hour is drawn from the history's shares of dominant /
  non-dominant accounts (mostly ~1 and ~0, some mixed hours around switches).
"""
from __future__ import annotations

import numpy as np

from kit import spend as kspend

HOUR_MS = 3_600_000


def _blocked_until(history, acct: str, now: int) -> int:
    """Latest reset among the account's 5-hour/7-day meters reading at the limit."""
    until = 0
    for wk in ("five_hour", "seven_day"):
        c = kspend.current_cycle(history, acct, wk)
        if c is None:
            continue
        _, reset, rows = c
        if rows.height and float(rows["util_pct"][-1]) >= 99.5 and reset > now:
            until = max(until, int(reset))
    return until


def forecast_split(history, now: int, trs, group: tuple[str, ...], cfg: dict, rng):
    """Every split target of the request (one per account of `group`) from one
    shared simulation, so the shares of a path add up to 1."""
    group = tuple(sorted(group))
    k = len(group)
    hist_h = int(cfg.get("history_h", 24 * 28))
    V = np.stack([kspend.hourly_series(history, (a,), hist_h)[1] for a in group])     # [k, T]
    tot = V.sum(axis=0)
    act = tot > 1e-9
    n_paths = max(tr.n_paths for tr in trs)
    H = max(int(round((int(tr.grid[-1]) - now) / HOUR_MS)) for tr in trs)
    prior_l = float(cfg.get("hazard_prior", 0.04))
    prior_n = float(cfg.get("hazard_prior_hours", 48))
    if not act.any():
        sh = np.full(k, 1.0 / k)
        out = {}
        for tr in trs:
            i = group.index(tr.accounts[0])
            out[tr.key] = np.full((1, len(tr.grid)), sh[i])
        return out
    S = np.where(act[None, :], V / np.where(act, tot, 1.0)[None, :], np.nan)          # [k, T]
    idx = np.flatnonzero(act)
    dom_series = np.argmax(V[:, idx], axis=0)
    span_h = max(1.0, float(idx[-1] - idx[0] + 1))
    switches = float((np.diff(dom_series) != 0).sum()) if len(dom_series) > 1 else 0.0
    lam = (switches + prior_l * prior_n) / (span_h + prior_n)
    # dominant now: recency-weighted spend over the last active hours
    recent = idx[-int(cfg.get("recent_active_h", 2)):]
    w = 0.5 ** ((idx[-1] - recent) / 1.0)
    dom_now = int(np.argmax((V[:, recent] * w[None, :]).sum(axis=1)))
    # long-run shares: how often each account is dominant (shrunk to equal)
    lr = np.bincount(dom_series, minlength=k).astype(np.float64) + float(cfg.get("share_prior_hours", 12)) / k
    lr = lr / lr.sum()
    # leave rate of each account so that the chain's long-run mix is `lr`
    # (mean switch rate lam): h_i = lam / (k * pi_i)
    pi = np.clip(lr, 0.05, 0.95)
    h_leave = np.minimum(lam / (k * pi), 0.9) if cfg.get("asymmetric", True) else np.full(k, lam)
    # share pools: the dominant account's share, and a non-dominant one's
    dshare = S[dom_series, idx]
    nd_mask = np.ones((k, len(idx)), bool)
    nd_mask[dom_series, np.arange(len(idx))] = False
    ndshare = S[:, idx][nd_mask] if k > 1 else np.zeros(0)
    if len(dshare) < 10:
        dshare = np.concatenate([dshare, np.ones(10)])
    if k > 1 and len(ndshare) < 10:
        ndshare = np.concatenate([ndshare, np.zeros(10)])
    blocked = np.array([_blocked_until(history, a, now) for a in group])
    hours = now + HOUR_MS * np.arange(1, H + 1, dtype=np.int64)
    # the hour (h-1, h] is blocked for an account if its block lasts past its start
    blk = blocked[:, None] > (hours[None, :] - HOUR_MS)                               # [k, H]
    if cfg.get("gap_decay", True):
        # time since the last active hour adds to the chance the regime changed
        gap = (len(act) - 1 - idx[-1])
    else:
        gap = 0
    p_stay0 = (1 - h_leave[dom_now]) ** gap
    dom = np.empty((n_paths, H), dtype=np.int64)
    cur = np.full(n_paths, dom_now)
    if k > 1:
        flip = rng.random(n_paths) > p_stay0
        cur = np.where(flip, _other(cur, lr, k, rng), cur)
    for h in range(H):
        if k > 1:
            sw = rng.random(n_paths) < h_leave[cur]
            cur = np.where(sw, _other(cur, lr, k, rng), cur)
            b = blk[cur, h]
            if b.any():
                free = ~blk[:, h]
                if free.any():
                    p = lr * free
                    p = p / p.sum()
                    cur = np.where(b, rng.choice(k, size=n_paths, p=p), cur)
        dom[:, h] = cur
    dsamp = rng.choice(dshare, size=(n_paths, H))
    out = {}
    for tr in trs:
        i = group.index(tr.accounts[0])
        if k > 1:
            nsamp = rng.choice(ndshare, size=(n_paths, H))
        else:
            nsamp = np.ones((n_paths, H))
        share = np.where(dom == i, dsamp, nsamp)
        if k == 2:
            # two accounts: the shares are complements
            share = np.where(dom == i, dsamp, 1.0 - dsamp)
        steps = np.clip(np.round((np.asarray(tr.grid, dtype=np.int64) - now) / HOUR_MS).astype(int), 1, H) - 1
        out[tr.key] = np.clip(share[:, steps], 0.0, 1.0)
    return out


def _other(cur: np.ndarray, lr: np.ndarray, k: int, rng) -> np.ndarray:
    """For each entry, another account drawn by long-run share."""
    out = cur.copy()
    for c in np.unique(cur):
        m = cur == c
        p = lr.copy()
        p[c] = 0.0
        if p.sum() <= 0:
            p = np.ones(k)
            p[c] = 0.0
        p = p / p.sum()
        out[m] = rng.choice(k, size=int(m.sum()), p=p)
    return out
