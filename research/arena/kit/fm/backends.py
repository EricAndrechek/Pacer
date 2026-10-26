"""One adapter per pretrained forecaster, all with the same call:

    backend = get_backend("timestral", "mistralai/Timestral-28M@<rev>")
    levels, q = backend.quantiles(context, horizon, past_cov=None, known_cov=None)

- `context` [B, V, T] float (NaN = missing): B series, each with V variates
  forecast jointly (V = 1 for a univariate call). A backend without
  multivariate support forecasts every variate on its own.
- `past_cov` [B, Cp, T]: covariates known over the context only.
- `known_cov` [B, Ck, T + horizon]: covariates known over the horizon too.
  Backends without covariate support ignore both (`covariates` says which).
- returns `levels` (Q,) and `q` [B, V, horizon, Q], sorted along Q.

Samplers (Toto) also offer `samples(...)` -> [B, V, horizon, S].

Weights load offline from the local Hugging Face cache (`kit.fm.weights`),
once per process. Every heavy import happens on first use, so importing
kit.fm costs nothing for a model that never forecasts.

| name | weights | quantiles | NaN | covariates | multivariate |
|---|---|---|---|---|---|
| timestral | mistralai/Timestral-{5M,28M,123M,209M} | 21 (0.01…0.99) | yes | past, known | yes |
| chronos2 | amazon/chronos-2 | 21 (0.01…0.99) | yes | past, known | yes |
| timesfm25 | google/timesfm-2.5-200m-pytorch | 9 (0.1…0.9) | no (filled) | no | no |
| tirex | NX-AI/TiRex | 9 (0.1…0.9) | yes | no | no |
| toto | Datadog/Toto-Open-Base-1.0 | its own samples | no (filled) | no | yes |
| moirai2 | Salesforce/moirai-2.0-R-small | 9 (0.1…0.9) | no (filled) | no | no |
"""
from __future__ import annotations

import contextlib
import math
import sys

import numpy as np

from kit.fm.paths import fix_crossing
from kit.fm.series import fill_gaps
from kit.fm.weights import cached, local_snapshot, parse_spec, set_threads


class Backend:
    name = "base"
    nan_ok = True
    covariates = False
    multivariate = False
    max_context = 4096

    def __init__(self, spec: str, threads: int = 4):
        self.spec = spec
        self.threads = threads

    # Subclasses implement _quantiles on a context they can take.
    def quantiles(self, context, horizon: int, past_cov=None, known_cov=None):
        ctx = np.asarray(context, dtype=np.float64)
        if ctx.ndim == 1:
            ctx = ctx[None, None, :]
        elif ctx.ndim == 2:
            ctx = ctx[:, None, :]
        T = ctx.shape[-1]
        if T > self.max_context:
            ctx = ctx[..., -self.max_context:]
            if past_cov is not None:
                past_cov = np.asarray(past_cov)[..., -self.max_context:]
            if known_cov is not None:
                known_cov = np.asarray(known_cov)[..., T - self.max_context:]
        if not self.nan_ok:
            ctx = fill_gaps(ctx)
        if not self.covariates:
            past_cov = known_cov = None
        with contextlib.redirect_stdout(sys.stderr):
            levels, q = self._quantiles(ctx, int(horizon), past_cov, known_cov)
        return np.asarray(levels, dtype=np.float64), fix_crossing(q)

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        raise NotImplementedError

    def _univariate(self, ctx, fn):
        """Run a univariate forecaster over every (series, variate)."""
        B, V, T = ctx.shape
        levels, q = fn(ctx.reshape(B * V, T))
        return levels, np.asarray(q).reshape(B, V, q.shape[-2], q.shape[-1])


# ---------------------------------------------------------------------------

class TimestralBackend(Backend):
    name = "timestral"
    covariates = True
    multivariate = True
    max_context = 32768

    def __init__(self, spec, threads=4):
        super().__init__(spec, threads)
        set_threads(threads)
        from kit.fm._vendor.timestral import TimestralForecaster
        self.fc = TimestralForecaster.from_pretrained(local_snapshot(spec), device="cpu")
        self.levels = np.asarray(self.fc.quantile_levels, dtype=np.float64)

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        kw = {}
        if past_cov is not None and np.asarray(past_cov).shape[1] > 0:
            kw["past_covariates"] = np.asarray(past_cov, dtype=np.float32)
        if known_cov is not None and np.asarray(known_cov).shape[1] > 0:
            kw["known_covariates"] = np.asarray(known_cov, dtype=np.float32)
        out = self.fc.forecast(ctx.astype(np.float32), prediction_length=horizon, **kw)
        return self.levels, out.quantiles.float().numpy().astype(np.float64)


class Chronos2Backend(Backend):
    name = "chronos2"
    covariates = True
    multivariate = True
    max_context = 8192

    def __init__(self, spec, threads=4):
        super().__init__(spec, threads)
        set_threads(threads)
        import torch
        from chronos import BaseChronosPipeline
        self.pipe = BaseChronosPipeline.from_pretrained(str(local_snapshot(spec)), device_map="cpu",
                                                        torch_dtype=torch.float32)
        self.levels = np.asarray(self.pipe.quantiles, dtype=np.float64)

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        B, V, T = ctx.shape
        has_cov = (past_cov is not None and np.asarray(past_cov).shape[1] > 0) or \
                  (known_cov is not None and np.asarray(known_cov).shape[1] > 0)
        if not has_cov:
            inputs = ctx.astype(np.float32)
        else:
            inputs = []
            for b in range(B):
                past, fut = {}, {}
                if past_cov is not None:
                    for c in range(np.asarray(past_cov).shape[1]):
                        past[f"p{c}"] = np.asarray(past_cov[b, c], dtype=np.float32)
                if known_cov is not None:
                    for c in range(np.asarray(known_cov).shape[1]):
                        row = np.asarray(known_cov[b, c], dtype=np.float32)
                        past[f"k{c}"] = row[:T]
                        fut[f"k{c}"] = row[T:T + horizon]
                item = {"target": ctx[b].astype(np.float32), "past_covariates": past}
                if fut:
                    item["future_covariates"] = fut
                inputs.append(item)
        qs, _ = self.pipe.predict_quantiles(inputs, prediction_length=horizon,
                                            quantile_levels=[float(x) for x in self.levels])
        q = np.stack([np.asarray(x.float().numpy() if hasattr(x, "numpy") else x) for x in qs])   # [B, V, H, Q]
        return self.levels, q.astype(np.float64)


class TimesFM25Backend(Backend):
    name = "timesfm25"
    nan_ok = False
    max_context = 16384

    def __init__(self, spec, threads=4):
        super().__init__(spec, threads)
        set_threads(threads)
        import timesfm
        self.m = timesfm.TimesFM_2p5_200M_torch.from_pretrained(str(local_snapshot(spec)), local_files_only=True,
                                                                 torch_compile=False)
        self._compiled = None
        self.levels = np.round(np.arange(1, 10) / 10.0, 2)

    def _compile(self, T, horizon, batch):
        from timesfm.configs import ForecastConfig
        p, o = self.m.model.p, self.m.model.o
        key = (int(math.ceil(T / p) * p), int(math.ceil(horizon / o) * o), batch)
        if key != self._compiled:
            self.m.compile(ForecastConfig(max_context=key[0], max_horizon=key[1], normalize_inputs=True,
                                          use_continuous_quantile_head=key[1] <= self.m.model.os,
                                          fix_quantile_crossing=True, per_core_batch_size=batch))
            self._compiled = key

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        def fn(x):
            self._compile(x.shape[-1], horizon, min(len(x), 32))
            _, q = self.m.forecast(horizon=horizon, inputs=[r.astype(np.float32) for r in x])
            return self.levels, np.asarray(q, dtype=np.float64)[:, :horizon, 1:10]
        return self._univariate(ctx, fn)


class TiRexBackend(Backend):
    name = "tirex"
    max_context = 4096

    def __init__(self, spec, threads=4):
        super().__init__(spec, threads)
        set_threads(threads)
        from tirex.base import PretrainedModel
        import tirex  # noqa: F401  (registers the model classes)
        snap = local_snapshot(spec)
        cls = PretrainedModel.REGISTRY.get("TiRex")
        self.m = cls.from_pretrained(str(snap / "model.ckpt"), backend="torch", device="cpu")
        self.levels = np.round(np.arange(1, 10) / 10.0, 2)

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        import torch

        def fn(x):
            q, _ = self.m.forecast(context=torch.tensor(x, dtype=torch.float32), prediction_length=horizon)
            return self.levels, np.asarray(q.float().numpy(), dtype=np.float64)
        return self._univariate(ctx, fn)


class TotoBackend(Backend):
    name = "toto"
    nan_ok = False
    multivariate = True
    max_context = 4096
    n_samples = 100

    def __init__(self, spec, threads=4):
        super().__init__(spec, threads)
        set_threads(threads)
        from kit.fm._vendor.toto.model.toto import Toto
        from kit.fm._vendor.toto.inference.forecaster import TotoForecaster
        model = Toto.load_from_checkpoint(str(local_snapshot(spec)), "cpu", True)
        model.eval()
        self.fc = TotoForecaster(model.model)
        self.levels = np.round(np.arange(1, 20) / 20.0, 2)          # from 100 samples: 0.05 … 0.95
        self.step_s = 60.0

    def samples(self, ctx, horizon, step_s: float | None = None, n_samples: int | None = None, seed: int = 0):
        """[B, V, horizon, S] sample paths."""
        import torch
        from kit.fm._vendor.toto.data.util.dataset import MaskedTimeseries
        ctx = fill_gaps(np.asarray(ctx, dtype=np.float64))
        if ctx.shape[-1] > self.max_context:
            ctx = ctx[..., -self.max_context:]
        B, V, T = ctx.shape
        x = torch.tensor(ctx, dtype=torch.float32)
        torch.manual_seed(seed)
        inp = MaskedTimeseries(series=x, padding_mask=torch.ones_like(x, dtype=torch.bool),
                               id_mask=torch.zeros_like(x), timestamp_seconds=torch.zeros_like(x),
                               time_interval_seconds=torch.full((B, V), float(step_s or self.step_s)))
        ns = int(n_samples or self.n_samples)
        f = self.fc.forecast(inp, prediction_length=int(horizon), num_samples=ns, samples_per_batch=ns)
        return np.asarray(f.samples.float().numpy(), dtype=np.float64)       # [B, V, H, S]

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        s = self.samples(ctx, horizon)
        q = np.quantile(s, self.levels, axis=-1)                              # [Q, B, V, H]
        return self.levels, np.moveaxis(q, 0, -1)


class Moirai2Backend(Backend):
    name = "moirai2"
    # Upstream imputes a NaN as 0 (CausalMeanImputation on a [T, 1] array),
    # which in a cumulative series reads as a crash; gaps are filled here.
    nan_ok = False
    max_context = 4096

    def __init__(self, spec, threads=4):
        super().__init__(spec, threads)
        set_threads(threads)
        from kit.fm._vendor.moirai2 import Moirai2
        self.m = Moirai2.load_local(local_snapshot(spec))
        self.levels = np.asarray(self.m.quantile_levels, dtype=np.float64)

    def _quantiles(self, ctx, horizon, past_cov, known_cov):
        def fn(x):
            return self.levels, self.m.predict_quantiles(x, horizon)
        return self._univariate(ctx, fn)


BACKENDS: dict[str, type[Backend]] = {b.name: b for b in (
    TimestralBackend, Chronos2Backend, TimesFM25Backend, TiRexBackend, TotoBackend, Moirai2Backend)}


def get_backend(name: str, spec: str, threads: int = 4) -> Backend:
    """The loaded forecaster, once per process (`weights.cached`). Libraries
    that print while loading (TiRex does) print to stderr: under `arena test`
    the in-process workers share the harness's stdout."""
    if name not in BACKENDS:
        raise ValueError(f"unknown backend {name!r}; known: {sorted(BACKENDS)}")
    parse_spec(spec)

    def load():
        with contextlib.redirect_stdout(sys.stderr):
            return BACKENDS[name](spec, threads)
    return cached(("backend", name, spec), load)
