"""The engine's tunable constants: a port of `EngineParams` (and of
`research/harness/pacer_replay.py`'s `Params`, which mirrors it), plus the
handful of engine constants that are code rather than params.

`canonical()` and `version_tag()` reproduce the Swift string and FNV-1a tag
exactly, so a tag here is the tag the app recorded into its prediction
snapshots (`PredictionSnapshot.paramsVersion`). `for_version` maps the tags
seen in the records of what the app did to the knob values that produced
them, for the replay-parity check.
"""
from __future__ import annotations

from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Params:
    # --- EngineParams (hashed, in this order) -------------------------------
    conformal_min_residuals: int = 8
    rl_stratum_min_scores: int = 10
    pool_tolerance: float = 1.25
    pool_min_periods: int = 10
    pool_recency_window: int = 30
    linear_recent_lookback_fraction: float = 0.3
    recency_half_life_fraction: float = 0.15
    conformal_block_min_cycles: int = 40
    # The app ranks at the live point of the window since 2026-10-27
    # (`rlCutKernelHalfWidth`, replacing phase selection) and on the moments
    # where the models disagreed since 2026-10-29 (`rlDisagreementPoints`).
    # Neither is ported: this engine still selects by phase. They are hashed
    # so the tag is the app's; None gives an older canonical string
    # (`rlSelectByPhase` in the kernel's place; no disagreement key).
    rl_cut_kernel_half_width: float | None = 0.2
    rl_tie_relative: float = 0.05          # adopted 2026-10-20; 0 = absolute 1.5 pp band
    rl_disagreement_points: float | None = 2.0
    # How this engine selects: hashed only while the kernel is None.
    rl_select_by_phase: bool = True        # adopted 2026-10-20 (#305)
    # --- harness-only selection knob (not hashed until adopted) -------------
    rl_selection_recency: int = 0          # rank on the last N scored periods; 0 = all-time
    # --- engine constants that are code, not EngineParams --------------------
    rate_fetch_days: float = 32.0          # UsageIntelligenceEngine.fetchRate: the live refit's read
    zero_anchor: bool = True               # PartialCycle's 0% reading at the window's start (#311)
    # The engine before #311 (records of what the app did, v1-4c0cc586 only):
    # raw-line grading, all-cut medians, shadow floors, no stand-in, no
    # recent-rate, no launch backfill. Never used by a model; parity only.
    legacy_engine: bool = False
    shadow_promotion_min_periods: int = 15

    def canonical(self) -> str:
        def g(v: float) -> str:
            return f"{v:g}"

        return ";".join([
            f"conformalMinResiduals={self.conformal_min_residuals}",
            f"rlStratumMinScores={self.rl_stratum_min_scores}",
            f"poolTolerance={g(self.pool_tolerance)}",
            f"poolMinPeriods={self.pool_min_periods}",
            f"poolRecencyWindow={self.pool_recency_window}",
            f"linearRecentLookbackFraction={g(self.linear_recent_lookback_fraction)}",
            f"recencyHalfLifeFraction={g(self.recency_half_life_fraction)}",
            f"conformalBlockMinCycles={self.conformal_block_min_cycles}",
            f"rlSelectByPhase={int(self.rl_select_by_phase)}" if self.rl_cut_kernel_half_width is None
            else f"rlCutKernelHalfWidth={g(self.rl_cut_kernel_half_width)}",
            f"rlTieRelative={g(self.rl_tie_relative)}",
        ] + ([] if self.rl_disagreement_points is None
             else [f"rlDisagreementPoints={g(self.rl_disagreement_points)}"]))

    def version_tag(self) -> str:
        return fnv_tag(self.canonical())


def fnv_tag(canonical: str) -> str:
    """`EngineParams.versionTag`: "v1-" + the low 32 bits of FNV-1a 64."""
    h = 0xCBF29CE484222325
    for b in canonical.encode():
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "v1-" + format(h & 0xFFFFFFFF, "08x")


SHIPPING = Params()

# The engine this kit reproduces: the app's knobs up to 2026-10-27.
PHASE_ENGINE = replace(SHIPPING, rl_cut_kernel_half_width=None, rl_disagreement_points=None)

# The tags in the records of what the app did that this kit reproduces, and
# the knobs behind them. The app's later tags (v1-481cca04 with the matched
# point, v1-5e0f894b with the disagreement filter too) select in a way not
# ported here, so their records are left out of the parity check.
# - v1-c13c3f81: phase selection, relative tie.
# - v1-6109fa45: the #311 engine before the two selection knobs existed: its
#   canonical string had only the first eight keys (pinned in the tests), and
#   selection was all-cuts with the absolute 1.5 pp tie band.
# - v1-4c0cc586: the engine before #311 (its canonical carried
#   shadowPromotionMinPeriods=15). Different CODE, not only knobs: the record
#   graded the raw line rather than the displayed value, a stand-in never
#   replaced a model that could not fit, bands came from the 32-day read only,
#   no 0% reading anchored a window's start, there was no recent-rate model
#   and no launch backfill. `legacy_engine` reproduces those differences for
#   the parity check only (kit/engine/parity.py); no model uses it.
VERSIONS: dict[str, Params] = {
    "v1-c13c3f81": PHASE_ENGINE,
    "v1-6109fa45": replace(PHASE_ENGINE, rl_select_by_phase=False, rl_tie_relative=0.0),
    "v1-4c0cc586": replace(PHASE_ENGINE, rl_select_by_phase=False, rl_tie_relative=0.0, zero_anchor=False,
                           legacy_engine=True),
}
LEGACY_VERSIONS = frozenset({"v1-4c0cc586"})


def for_version(tag: str | None) -> Params | None:
    return VERSIONS.get(tag or "")
