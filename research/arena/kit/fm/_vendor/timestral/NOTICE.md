Vendored from https://github.com/mistralai/timestral at commit
a534bdbd244d64f3d9d743f46c7bf6fc330ed4ff (`src/timestral/`), Apache License 2.0
(LICENSE, copied unchanged). The only change: absolute `from timestral.x import`
lines became relative (`from .x import`), so the package works from inside
`kit.fm._vendor` without being installed.

Why vendored: the package is not on PyPI, and a model's `deps` (model.toml)
may name only PyPI requirements, so a Docker worker could not otherwise get it.
It needs only torch, numpy, safetensors and huggingface_hub.

The weights are separate (Hugging Face Hub, Modified MIT license per model repo)
and are never copied into the repository.
