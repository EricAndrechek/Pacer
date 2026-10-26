"""Models, their price schedule, the catalog rows a snapshot carries, and
truth pricing.

Two views of the same prices:

- the **schedule**: the rate actually billed at each moment (with launch-time
  catalog errors already corrected). Truth and the meter use this.
- the **catalog** (`prices` table): what a price catalog published and when
  Pacer could have known it. A launch is known only after its commit lag,
  a change only after its own lag, and a wrong launch rate is fixed by a
  later curated correction (`is_correction`).

Price rows carry `t_effective_to = null`. The rate in force at time x, as
known at T, is the row with the greatest `t_effective_from <= x` among rows
with `t_known <= T` (ties: a correction wins, then the later `t_known`). A
filled-in `t_effective_to` would tell a model at T when a price is going to
change, so the generator never writes one.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .config import DAY_MS, HOUR_MS, PARTS, SynthConfig

CATALOG_REFRESH_MS = 24 * HOUR_MS     # Pacer refreshes catalogs daily


@dataclass
class Period:
    start: int
    base: np.ndarray          # [5] USD per Mtok, PARTS order
    tier: np.ndarray | None   # [5] or None
    threshold: int


class Catalog:
    def __init__(self, cfg: SynthConfig):
        self.cfg = cfg
        self.models = list(cfg.models)
        self.index = {m.model: i for i, m in enumerate(self.models)}
        self.family = [m.family for m in self.models]
        self.launch = [cfg.start_ms - 180 * DAY_MS if m.launch_frac is None else cfg.at(m.launch_frac)
                       for m in self.models]
        self.periods: list[list[Period]] = []
        for i, m in enumerate(self.models):
            base = np.array([m.rates[p] for p in PARTS], dtype=np.float64)
            tier = None if m.tier_rates is None else np.array([m.tier_rates[p] for p in PARTS], dtype=np.float64)
            ps = [Period(self.launch[i], base, tier, m.tier_threshold)]
            for ch in sorted((c for c in cfg.changes.price_changes if c.model == m.model), key=lambda c: c.at_frac):
                prev = ps[-1]
                # Rounded like a catalog would publish them, so the published
                # rate and the billed rate are the same number.
                ps.append(Period(cfg.at(ch.at_frac), np.round(prev.base * ch.multiplier, 6),
                                 None if prev.tier is None else np.round(prev.tier * ch.multiplier, 6),
                                 prev.threshold))
            self.periods.append(ps)

    # ---- which model a family uses at a time ----------------------------------

    def available(self, model: str, t: int) -> bool:
        return t >= self.launch[self.index[model]]

    def family_models(self, family: str) -> list[int]:
        return [i for i, f in enumerate(self.family) if f == family]

    # ---- truth pricing ------------------------------------------------------------

    def cost(self, model_idx: np.ndarray, t: np.ndarray, tokens: np.ndarray) -> np.ndarray:
        """USD per row at the billed rate. tokens: [n, 5] in PARTS order.
        A prompt over the threshold prices the whole request at the tier."""
        out = np.zeros(len(t), dtype=np.float64)
        prompt = tokens[:, 0] + tokens[:, 2] + tokens[:, 3] + tokens[:, 4]
        for mi, ps in enumerate(self.periods):
            sel = np.flatnonzero(model_idx == mi)
            if sel.size == 0:
                continue
            starts = np.array([p.start for p in ps], dtype=np.int64)
            k = np.clip(np.searchsorted(starts, t[sel], side="right") - 1, 0, None)
            base = np.stack([p.base for p in ps])[k]
            if ps[0].tier is not None:
                tier = np.stack([p.tier for p in ps])[k]
                over = prompt[sel] > np.array([p.threshold for p in ps])[k]
                rates = np.where(over[:, None], tier, base)
            else:
                rates = base
            out[sel] = (tokens[sel].astype(np.float64) * rates).sum(axis=1) / 1e6
        return out

    def schedule_dict(self) -> list[dict]:
        out = []
        for mi, ps in enumerate(self.periods):
            for p in ps:
                out.append({
                    "model": self.models[mi].model, "family": self.family[mi], "from_ms": p.start,
                    "base": dict(zip(PARTS, p.base.tolist())),
                    "tier": None if p.tier is None else dict(zip(PARTS, p.tier.tolist())),
                    "tier_threshold": p.threshold,
                })
        return out

    # ---- the published catalog --------------------------------------------------------

    def catalog_rows(self, rng: np.random.Generator) -> list[dict]:
        cfg = self.cfg
        rows: list[dict] = []
        errors = {(e.model, e.part): e for e in cfg.changes.price_errors}
        changes = {(c.model, cfg.at(c.at_frac)): c for c in cfg.changes.price_changes}

        def sha():
            return "".join(f"{b:02x}" for b in rng.integers(0, 256, size=20, dtype=np.uint8))

        for mi, ps in enumerate(self.periods):
            m = self.models[mi]
            for pi, p in enumerate(ps):
                if pi == 0:
                    lag = (m.catalog_lag_h * HOUR_MS) if m.launch_frac is not None else 0
                else:
                    lag = changes[(m.model, p.start)].catalog_lag_h * HOUR_MS
                known = p.start + int(lag) + CATALOG_REFRESH_MS
                commit = sha()
                for tier_name, rates in (("base", p.base), ("tier", p.tier)):
                    if rates is None:
                        continue
                    for j, part in enumerate(PARTS):
                        rate = float(rates[j])
                        err = errors.get((m.model, part)) if pi == 0 else None
                        published = rate * err.wrong_multiplier if err else rate
                        base_row = {
                            "t_event": p.start, "t_known": known, "t_known_src": "observed",
                            "model": m.model, "part": part,
                            "tier_threshold": p.threshold if tier_name == "tier" else None,
                            "geo_mult": 1.0, "speed_mult": 1.0,
                            "rate_per_mtok": round(published, 6), "source": "litellm",
                            "commit_sha": commit, "t_effective_from": p.start, "t_effective_to": None,
                            "is_correction": False,
                        }
                        rows.append(base_row)
                        if err:
                            rows.append({**base_row, "rate_per_mtok": round(rate, 6), "source": "curated",
                                         "commit_sha": None, "is_correction": True,
                                         "t_known": p.start + int(err.corrected_after_days * DAY_MS)})
        return rows
