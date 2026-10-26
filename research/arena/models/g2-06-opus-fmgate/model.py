"""g2-06-opus-fmgate: the leaders run in-process, meters gated by account state.

The runner re-spawns and re-fits a child at every checkpoint, so a child
that calibrates itself on its own past (g1-08-opus-fm's self-backtests)
redoes that work 24 times an episode and the tree times out. Here the
leaders' own code runs inside this process, sharing one History (and with
it kit.spend's per-History caches):

- meters: g1-08-opus-fm's MeterFM (Timestral-123M, recalibrated per lead on
  the user's past), its spread shrunk around the median, then gated
  (gate.py): an idle or limit-blocked account's meter is held at its
  reading until a resume time drawn from its own past idle stretches;
- spend.hourly / tokens.hourly: g1-08-opus-fm's in-process Timestral-28M;
- split.accounts: g1-09-opus-split (two-state switching chain);
- cycle.next_start: g1-10-fable-analog (hazard on the local hour and the
  idle time).
"""
from __future__ import annotations

from types import SimpleNamespace

import numpy as np

from arena.types import Forecast, Request, Target, TargetForecast
from kit import baselines as B
from kit import spend as S

import fable_model
import g108_model
import gate as G
import split09

WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
HOURLY = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)


def _shim(ctx, cfg):
    return SimpleNamespace(config=dict(cfg), rng=ctx.rng, log=ctx.log, seed=ctx.seed,
                           scratch=ctx.scratch, children=(), model=ctx.model, backtest=ctx.backtest)


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self.fm = g108_model.Model(_shim(ctx, self.cfg.get("g108", {})))
        self.fable = fable_model.Model(_shim(ctx, self.cfg.get("fable", {})))
        self.split = split09.Model(_shim(ctx, self.cfg.get("split09", {})))
        self.parts = (self.fm, self.fable, self.split)
        self._book = None

    def fit(self, history):
        self.history = history
        for p in self.parts:
            p.fit(history)
        self._book = None

    def update(self, events):
        self.history = self.history.extend(events)
        for p in self.parts:
            p.history = self.history
        self._book = None

    # ------------------------------------------------------------------
    def forecast(self, request):
        now = int(request.now)
        out = {}
        groups = {"fm": [], "fable": [], "split": []}
        for tr in request.targets:
            if tr.target in WINDOW_OF or tr.target in HOURLY:
                groups["fm"].append(tr)
            elif tr.target is Target.CYCLE_NEXT_START:
                groups["fable"].append(tr)
            elif tr.target is Target.SPLIT:
                groups["split"].append(tr)
        for name, part in (("fm", self.fm), ("fable", self.fable), ("split", self.split)):
            trs = groups[name]
            if not trs:
                continue
            try:
                fc = part.forecast(Request(request.now, request.scope, tuple(trs)))
                out.update({k: v for k, v in fc.by_key.items() if k in {t.key for t in trs}})
            except Exception as e:  # noqa: BLE001
                self.ctx.log(f"{name} failed: {type(e).__name__}: {str(e)[:300]}")
        for tr in request.targets:
            if tr.key not in out:
                out[tr.key] = self._fallback(tr)
                continue
            if tr.target in WINDOW_OF:
                try:
                    out[tr.key] = self._meter_post(tr, out[tr.key], now)
                except Exception as e:  # noqa: BLE001
                    self.ctx.log(f"gate {tr.key} failed: {type(e).__name__}: {str(e)[:300]}")
        return Forecast(out)

    def _fallback(self, tr):
        try:
            if tr.target in WINDOW_OF:
                return B.meter_flat(self.history, tr)
            if tr.target is Target.CYCLE_NEXT_START:
                return B.next_start_never(self.history, tr)
            if tr.target is Target.SPLIT:
                return TargetForecast.point(np.full(len(tr.grid), 1.0))
            return B.hourly_flat(self.history, tr, 24)
        except Exception:  # noqa: BLE001
            fill = np.nan if tr.target is Target.CYCLE_NEXT_START else 0.0
            return TargetForecast.point(np.full(len(tr.grid), fill))

    # ------------------------------------------------------------------
    def _meter_post(self, tr, tf, now):
        cfg = dict(self.cfg.get("gate", {}).get(WINDOW_OF[tr.target], {}))
        P = np.asarray(tf.paths, dtype=np.float64)
        s = float(cfg.get("shrink", 1.0))
        if s != 1.0:
            med = np.median(P, axis=0, keepdims=True)
            P = np.clip(med + s * (P - med), 0.0, 100.0)
            tf = TargetForecast(P)
        if not cfg.get("on", False):
            return tf
        h = self.history
        acct = tr.accounts[0]
        m = B.meter_now(h, tr)
        if not len(m.util):
            return tf
        u0 = float(m.util[-1])
        if self._book is None:
            self._book = G.TurnBook(h)
        book = self._book
        fam = G.cap_family(tr.cap) if tr.target is Target.METER_SCOPED else None
        T = book.times(acct, fam)
        T = T[T <= now]
        d = G.idle_ms(T, now)
        blk = G.blocked_until(h, acct, now) if cfg.get("blocking", True) else 0
        n = P.shape[0]
        if d < float(cfg.get("min_idle_min", 5)) * G.MIN and blk <= now:
            return tf
        tau = None
        if d >= float(cfg.get("min_idle_min", 5)) * G.MIN:
            tz = S.tz_offset_ms(h, acct)
            tau = G.sample_resume(T, book.others(acct), now, d, tz, n, self.rng, cfg)
        if tau is None:
            if blk <= now:
                return tf
            tau = np.zeros(n)
        if blk > now:
            tau = np.maximum(tau, blk - now)
        k = int(round(float(cfg.get("keep", 0.1)) * n))
        idx = self.rng.permutation(n)
        tau_full = np.empty(n)
        tau_full[idx[:k]] = 0.0
        tau_full[idx[k:]] = tau[: n - k]
        return TargetForecast(G.gate_paths(P, tr.grid, now, u0, tau_full, cfg.get("mode", "shift")))
