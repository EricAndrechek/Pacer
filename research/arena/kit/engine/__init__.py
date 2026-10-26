"""A port of the app's rate-limit forecasting engine (PacerCore's
`BurnTrajectory`, `DiurnalBurnModel`, `EngineSelfEval` and the rate-limit
half of `UsageIntelligenceEngine`), driven only by the `History` a model is
handed. Used by `models/port-engine-*`; `kit/engine/parity.py` checks it
against what the app recorded.

- `params`: `EngineParams` and the version tags the app recorded;
- `core`: segmentation, the seven methods, the display rule;
- `selfeval`: the record, selection, stand-ins, cold start, conformal bands;
- `engine`: one window's refit at a moment (`WindowEngine.observe`);
- `series`: meter series and the activity grid, from History only;
- `paths`: an outlook as forecast paths;
- `model`: the arena model the port-engine-* folders use.
"""
from kit.engine.core import COMPLEXITY, METHOD_IDS, Cycle, Partial, displayed_at_reset, segment
from kit.engine.engine import RULE, Outlook, WindowEngine
from kit.engine.params import SHIPPING, Params, for_version

__all__ = ["COMPLEXITY", "METHOD_IDS", "RULE", "SHIPPING", "Cycle", "Outlook", "Params", "Partial",
           "WindowEngine", "displayed_at_reset", "for_version", "segment"]
