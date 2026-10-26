"""Calling a child that does not cover everything that was asked.

The runner validates a child's forecast against the whole request and raises
if any key is missing, so a parent that forwards its request unchanged loses
a child completely over one key it cannot answer — `naive-diurnal-spend`
declares `spend.hourly` only, and asking it for `tokens.hourly` as well
throws away its spend forecast too.

`ask` forwards the request once (the cheap path, and the one whose cache key
matches the parent's own request), and only if that fails retries per target
kind, remembering which kinds the child can serve so the next checkpoint goes
straight there.
"""
from __future__ import annotations

from dataclasses import replace

from arena.types import Forecast


class ChildCaller:
    def __init__(self, ctx):
        self.ctx = ctx
        self.whole: dict[str, bool] = {}        # child -> the full request works
        self.bad: dict[str, set] = {}           # child -> target kinds it cannot serve

    def ask(self, name: str, request) -> Forecast | None:
        if self.whole.get(name, True):
            try:
                fc = self.ctx.model(name).forecast(request)
                self.whole[name] = True
                return fc
            except Exception as e:  # noqa: BLE001
                self.ctx.log(f"child {name} whole request failed: {type(e).__name__}: {str(e)[:160]}")
                self.whole[name] = False
        kinds, out = {}, {}
        for tr in request.targets:
            kinds.setdefault(tr.target, []).append(tr)
        bad = self.bad.setdefault(name, set())
        for target, trs in kinds.items():
            if target in bad:
                continue
            try:
                fc = self.ctx.model(name).forecast(replace(request, targets=tuple(trs)))
            except Exception as e:  # noqa: BLE001
                bad.add(target)
                self.ctx.log(f"child {name} cannot serve {target}: {type(e).__name__}: {str(e)[:120]}")
                continue
            out.update(fc.by_key)
        return Forecast(out) if out else None
