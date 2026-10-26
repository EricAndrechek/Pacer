Vendored from the `toto-ts` 0.2.0 wheel on PyPI (Datadog's Toto, Apache
License 2.0: LICENSE and NOTICE copied unchanged): `toto/model/` (the network:
toto, backbone, attention, transformer, rope, util, scaler, distribution,
embedding, feed_forward, fusion), `toto/inference/forecaster.py` and
`toto/data/util/dataset.py`. Training, evaluation, Lightning and GluonTS
predictor code is left out.

Changes: the five GluonTS imports (`AffineTransformed`, `StudentT`, `Scaler`,
`validated`) point at `_gluonts_compat.py`, a torch-only stand-in written for
this copy. Nothing else.

Why vendored: `toto-ts` pins numpy==1.26.4, torch==2.7.0, pandas==2.2.3,
gluonts and a dozen tools; installed beside the arena (numpy 2, polars,
pyarrow) it would replace the harness's own numpy. The network needs only
torch, einops, jaxtyping, rotary-embedding-torch, safetensors and
huggingface_hub. Weights (Datadog/Toto-Open-Base-1.0) are never copied in.
