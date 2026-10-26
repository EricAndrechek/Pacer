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

# Vendored and trimmed from uni2ts 2.0.0 model/moirai2/forecast.py
# (Moirai2Forecast) and transform/imputation.py (CausalMeanImputation).
# Univariate, no covariates only; Lightning and gluonts are removed.

import math
from typing import Optional

import numpy as np
import torch
from einops import rearrange, reduce, repeat

from .moirai2_module import Moirai2Module


def _last_value_imputation(x: np.ndarray, value: float = 0.0) -> np.ndarray:
    # Verbatim from uni2ts LastValueImputation, including its behaviour on
    # a [length, 1] array (it transposes first, so leading-row logic applies
    # to the whole series and NaN becomes `value`). Numbers must match upstream.
    x = x.T
    x[0:1][np.isnan(x[0:1])] = value
    mask = np.isnan(x)
    idx = np.arange(len(x))
    if x.ndim == 2:
        idx = np.expand_dims(idx, axis=1)
    idx = np.where(~mask, idx, 0)
    idx = np.maximum.accumulate(idx, axis=0)
    if x.ndim == 2:
        x = x[idx, np.arange(x.shape[1])]
    else:
        x = x[idx]
    return x.T


def causal_mean_imputation(x: np.ndarray, value: float = 0.0) -> np.ndarray:
    """uni2ts CausalMeanImputation as a plain function (same quirks, on purpose)."""
    mask = np.isnan(x).T
    x = _last_value_imputation(x, value)
    mask[0] = False
    x = x.T
    if x.ndim == 1:
        adj = np.concatenate((np.repeat(0.0, 1), x[:-1]))
        cumsum = np.cumsum(adj)
        indices = np.linspace(0, len(x) - 1, len(x))
        indices[0] = 1
        ar_res = cumsum / indices
        x[mask] = ar_res[mask]
    else:
        adj = np.vstack((np.zeros((1, x.shape[1])), x[:-1, :]))
        cumsum = np.cumsum(adj, axis=0)
        indices = np.linspace(0, len(x) - 1, len(x)).reshape(-1, 1)
        indices[0] = 1
        ar_res = cumsum / indices
        x[mask] = ar_res[mask]
    return x.T


def _patched_seq_pad(patch_size, x, dim, left=True, value=None):
    if dim >= 0:
        dim = -x.ndim + dim
    pad_length = -x.size(dim) % patch_size
    pad = (pad_length, 0) if left else (0, pad_length)
    pad = (0, 0) * (abs(dim) - 1) + pad
    return torch.nn.functional.pad(x, pad, value=value)


def _generate_time_id(patch_size, past_observed_target, prediction_token_length):
    past_seq_id = reduce(
        _patched_seq_pad(patch_size, past_observed_target, -2, left=True),
        "... (seq patch) dim -> ... seq",
        "max",
        patch=patch_size,
    )
    past_seq_id = torch.clamp(
        past_seq_id.cummax(dim=-1).values.cumsum(dim=-1) - 1, min=0
    )
    batch_shape = " ".join(map(str, past_observed_target.shape[:-2]))
    future_seq_id = (
        repeat(
            torch.arange(prediction_token_length, device=past_observed_target.device),
            f"prediction -> {batch_shape} prediction",
        )
        + past_seq_id.max(dim=-1, keepdim=True).values
        + 1
    )
    return past_seq_id, future_seq_id


def _convert(patch_size, prediction_length, past_target, past_observed_target, past_is_pad):
    """Univariate (target_dim == 1), no covariates. Mirrors Moirai2Forecast._convert."""
    batch_shape = past_target.shape[:-2]
    device = past_target.device
    context_tokens = math.ceil(past_target.shape[-2] / patch_size)
    pred_tokens = math.ceil(prediction_length / patch_size)

    past_seq_id, future_seq_id = _generate_time_id(
        patch_size, past_observed_target, pred_tokens
    )
    future_target = torch.zeros(
        batch_shape + (prediction_length, 1), dtype=past_target.dtype, device=device
    )
    target = torch.cat(
        [
            rearrange(
                _patched_seq_pad(patch_size, past_target, -2, left=True),
                "... (seq patch) dim -> ... (dim seq) patch",
                patch=patch_size,
            ),
            rearrange(
                _patched_seq_pad(patch_size, future_target, -2, left=False),
                "... (seq patch) dim -> ... (dim seq) patch",
                patch=patch_size,
            ),
        ],
        dim=-2,
    )
    future_observed = torch.ones(
        batch_shape + (prediction_length, 1), dtype=torch.bool, device=device
    )
    observed_mask = torch.cat(
        [
            rearrange(
                _patched_seq_pad(patch_size, past_observed_target, -2, left=True),
                "... (seq patch) dim -> ... (dim seq) patch",
                patch=patch_size,
            ),
            rearrange(
                _patched_seq_pad(patch_size, future_observed, -2, left=False),
                "... (seq patch) dim -> ... (dim seq) patch",
                patch=patch_size,
            ),
        ],
        dim=-2,
    )
    future_is_pad = torch.zeros(
        batch_shape + (prediction_length,), dtype=torch.long, device=device
    )
    sample_id = torch.cat(
        [
            reduce(
                (_patched_seq_pad(patch_size, past_is_pad, -1, left=True, value=1) == 0).int(),
                "... (seq patch) -> ... seq",
                "max",
                patch=patch_size,
            ),
            reduce(
                (_patched_seq_pad(patch_size, future_is_pad, -1, left=False, value=1) == 0).int(),
                "... (seq patch) -> ... seq",
                "max",
                patch=patch_size,
            ),
        ],
        dim=-1,
    )
    time_id = torch.cat([past_seq_id, future_seq_id], dim=-1)
    variate_id = torch.zeros(
        batch_shape + (context_tokens + pred_tokens,), dtype=torch.long, device=device
    )
    prediction_mask = torch.cat(
        [
            torch.zeros(batch_shape + (context_tokens,), dtype=torch.bool, device=device),
            torch.ones(batch_shape + (pred_tokens,), dtype=torch.bool, device=device),
        ],
        dim=-1,
    )
    return target, observed_mask, sample_id, time_id, variate_id, prediction_mask


def forecast_quantiles(
    module: Moirai2Module,
    past_target: torch.Tensor,  # [B, T, 1] float32, NaN already imputed
    past_observed_target: torch.Tensor,  # [B, T, 1] bool
    past_is_pad: torch.Tensor,  # [B, T] bool
    prediction_length: int,
) -> torch.Tensor:
    """Returns [B, Q, prediction_length]; same as Moirai2Forecast.forward (target_dim=1)."""
    patch_size = module.patch_size
    nq = module.num_quantiles
    npt = module.num_predict_token
    (target, observed_mask, sample_id, time_id, variate_id, prediction_mask) = _convert(
        patch_size, prediction_length, past_target, past_observed_target, past_is_pad
    )
    ctx_tok = math.ceil(past_target.shape[-2] / patch_size)
    per_var_predict_token = math.ceil(prediction_length / patch_size)

    pred_index = torch.arange(start=ctx_tok - 1, end=ctx_tok, step=ctx_tok)
    assign_index = torch.arange(
        start=ctx_tok, end=ctx_tok + per_var_predict_token, step=per_var_predict_token
    )
    quantile_prediction = repeat(
        target, "... patch_size -> ... num_quantiles patch_size", num_quantiles=nq
    ).clone()

    preds = module(
        target, observed_mask, sample_id, time_id, variate_id, prediction_mask,
        training_mode=False,
    )

    def structure_multi_predict(n_tokens, pred_index, assign_index, preds):
        preds = rearrange(
            preds,
            "... (predict_token num_quantiles patch_size) -> ... predict_token num_quantiles patch_size",
            predict_token=npt, num_quantiles=nq, patch_size=patch_size,
        )
        preds = rearrange(
            preds[..., pred_index, :n_tokens, :, :],
            "... pred_index predict_token num_quantiles patch_size -> ... (pred_index predict_token) num_quantiles patch_size",
        )
        adjusted = torch.cat(
            [torch.arange(start=i, end=i + n_tokens) for i in assign_index]
        )
        return preds, adjusted

    if per_var_predict_token <= npt:
        preds, adj = structure_multi_predict(
            per_var_predict_token, pred_index, assign_index, preds
        )
        quantile_prediction[..., adj, :, :] = preds
    else:
        # Autoregressive "quantile of quantiles": every quantile path is fed back.
        def expand(x):
            return repeat(
                x, "batch_size ... -> batch_size num_quantiles ...", num_quantiles=nq
            ).clone()

        expand_target = expand(target)
        expand_prediction_mask = expand(prediction_mask)
        expand_observed_mask = expand(observed_mask)
        expand_sample_id = expand(sample_id)
        expand_time_id = expand(time_id)
        expand_variate_id = expand(variate_id)

        preds, adj = structure_multi_predict(npt, pred_index, assign_index, preds)
        quantile_prediction[..., adj, :, :] = preds
        expand_target[..., adj, :] = rearrange(
            preds,
            "... predict_token num_quantiles patch_size -> ... num_quantiles predict_token patch_size",
            num_quantiles=nq, patch_size=patch_size, predict_token=npt,
        )
        expand_prediction_mask[..., adj] = False

        remain_step = per_var_predict_token - npt
        q_levels = torch.tensor(module.quantile_levels, dtype=torch.float32)
        while remain_step > 0:
            preds = module(
                expand_target, expand_observed_mask, expand_sample_id,
                expand_time_id, expand_variate_id, expand_prediction_mask,
                training_mode=False,
            )
            pred_index = assign_index + npt - 1
            assign_index = pred_index + 1
            preds, adj = structure_multi_predict(
                npt if remain_step - npt > 0 else remain_step,
                pred_index, assign_index, preds,
            )
            nxt = rearrange(
                preds,
                "... num_quantiles_prev pred_index num_quantiles patch_size -> ... pred_index (num_quantiles_prev num_quantiles) patch_size",
                num_quantiles=nq, patch_size=patch_size,
            )
            nxt = torch.quantile(nxt, q_levels, dim=-2)
            quantile_prediction[..., adj, :, :] = rearrange(
                nxt, "num_quantiles ... patch_size -> ... num_quantiles patch_size"
            )
            expand_target[..., adj, :] = rearrange(
                nxt,
                "num_quantiles batch_size predict_token patch_size -> batch_size num_quantiles predict_token patch_size",
                num_quantiles=nq, patch_size=patch_size, predict_token=len(adj),
            )
            expand_prediction_mask[..., adj] = False
            remain_step -= npt

    # _format_preds (target_dim == 1)
    preds = quantile_prediction[..., ctx_tok : ctx_tok + per_var_predict_token, :nq, :patch_size]
    preds = rearrange(
        preds, "... seq num_quantiles patch -> ... num_quantiles (seq patch)"
    )[..., :prediction_length]
    return preds
