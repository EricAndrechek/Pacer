"""Pretrained time-series forecasters ("foundation models") in the arena.

Modules (each imports torch only when a forecast is first made):

- `weights`: where a model's Hugging Face snapshot lives on this machine,
  offline; torch thread pinning; one loaded network per process.
- `backends`: one adapter per forecaster (Timestral, Chronos-2, TimesFM 2.5,
  TiRex, Toto, Moirai-2), all `quantiles(context [B,V,T], horizon,
  past_cov, known_cov) -> (levels, q [B,V,H,Q])`.
- `series`: what they read, from a `History` only: a meter's cumulative burn
  across cycles, resampled onto a regular grid ending at now; hourly spend and
  tokens aligned to now, priced as of now; hourly covariates.
- `paths`: quantiles -> sample paths (comonotone, AR(1) copula, or a
  sampler's own draws), tails, monotone meter clipping.
- `meter_model`, `spend_model`, `struct_model`: the `Model` classes behind
  `models/fm-*-meter`, `models/fm-*-spend` and `models/struct-*` (each model
  folder only names its forecaster and settings in model.toml).
- spend and the live meter come from `kit.spend` (the structural models'
  conversion and start value; `kit.spend.PriceCache` prices turns once per
  model instance).
- `_vendor/`: Timestral, Toto and Moirai-2 inference code (Apache-2.0),
  vendored because their packages are git-only or pin numpy<2.

**Where the packages and weights come from.**

- Host workers (`arena test`, `arena run`, `python -m arena.worker`): the
  arena's own venv with the `fm` extra (`uv sync --extra fm`, then
  `uv run --extra fm arena …`), and the weights in the local Hugging Face
  cache (`~/.cache/huggingface/hub`, found even though a host worker's HOME
  is its scratch folder). Nothing is downloaded.
- Docker workers (`arena-eval`, or any run with the fleet's worker command):
  each model.toml's `deps` (the same pins as the `fm` extra) and `weights`
  (pinned revisions) are installed by `arena build` into an env mounted at
  /env, `HF_HOME=/env/hf`, offline. The vendored code ships in the image
  with the rest of `kit`. A structural model's env is its whole tree's
  (`fleet.evalgate.env_spec`), so the child's torch and weights are there.
  By hand, the same path `arena-eval` takes: `fleet.image.build_image(<arena
  dir>)` for the image tag; `uv run arena build models/<m> --image <tag>`;
  then `uv run arena test models/<m> --worker-cmd <json>` with the command
  from `fleet.evalgate.worker_command(cfg, models=<models dir>, env=<env>,
  prefix=…)` and `--worker-kill-cmd '["docker","kill","{id}"]'`.

Costs to know: a model's code lives in kit/fm, and a model's identity
(`arena.registry.content_hash`) covers kit, so an edit to kit/fm makes every
fm model a new model (new hash, cold child cache). An edit to kit also changes
the image tag, hence every env key: `arena build` again.
"""
