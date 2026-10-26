#  Copyright (c) 2024, Salesforce, Inc.
#  SPDX-License-Identifier: Apache-2
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

"""Moirai 2.0 inference, vendored from uni2ts 2.0.0 without uni2ts/gluonts/lightning."""

import json
from pathlib import Path

import numpy as np
import torch
from safetensors.torch import load_file

from .forecast import causal_mean_imputation, forecast_quantiles
from .moirai2_module import Moirai2Module

__all__ = ["Moirai2", "Moirai2Module"]


class Moirai2:
    def __init__(self, module: Moirai2Module):
        self.module = module.eval().to("cpu", torch.float32)
        self.quantile_levels = tuple(float(q) for q in module.quantile_levels)

    @classmethod
    def load_local(cls, path) -> "Moirai2":
        path = Path(path)
        cfg = json.loads((path / "config.json").read_text())
        if "quantile_levels" in cfg:
            cfg["quantile_levels"] = tuple(cfg["quantile_levels"])
        module = Moirai2Module(**cfg)
        module.load_state_dict(load_file(str(path / "model.safetensors")), strict=True)
        return cls(module)

    def predict_quantiles(
        self, context: np.ndarray, horizon: int, context_length: int | None = None
    ) -> np.ndarray:
        """context [N, T] (NaN = missing) -> [N, horizon, Q] float64."""
        context = np.asarray(context)
        if context.ndim != 2:
            raise ValueError("context must be [N, T]")
        L = int(context_length or context.shape[1])
        rows, obs = [], []
        for row in context:
            arr = row.astype(np.float64)[:, None] if row.dtype != np.float32 else row[:, None]
            observed = ~np.isnan(arr)
            if np.isnan(arr).any():
                arr = causal_mean_imputation(arr.copy())
            rows.append(arr)
            obs.append(observed)
        pad = np.zeros((len(rows), L), dtype=bool)

        def fit(a, idx, is_target):
            if a.shape[0] > L:
                return a[-L:, :]
            n = L - a.shape[0]
            if is_target:
                pad[idx, :n] = True
            return np.concatenate([np.full((n, 1), a[0], dtype=a.dtype), a], axis=0)

        rows = [fit(a, i, True) for i, a in enumerate(rows)]
        obs = [fit(a, i, False) for i, a in enumerate(obs)]
        with torch.inference_mode():
            out = forecast_quantiles(
                self.module,
                torch.tensor(np.array(rows), dtype=torch.float32),
                torch.tensor(np.array(obs), dtype=torch.bool),
                torch.tensor(pad, dtype=torch.bool),
                int(horizon),
            )
        return out.numpy().astype(np.float64).transpose(0, 2, 1)
