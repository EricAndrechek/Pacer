# Third-party notices

Pacer's own code is MIT-licensed (see `LICENSE`). The forecasting models below
are third-party work that Pacer ports to Swift and/or downloads. Weights are
pinned to the exact revision Pacer was scored against.

## Timestral (Mistral AI)

- Upstream: https://github.com/mistralai/timestral (code, commit
  `a534bdbd244d64f3d9d743f46c7bf6fc330ed4ff`); weights at
  https://huggingface.co/mistralai
- Used: both. The inference code is ported to Swift
  (`PacerCore/Sources/PacerCore/Forecast/Arena/Kit/FM/Timestral/`), and the
  weights are loaded.
- Code licence: Apache License 2.0. Copyright Mistral AI.
- Weights licence: Mistral AI's "Modified MIT License" (attribution notice
  "2026 - Mistral AI"). It requires the notice to travel with every copy and
  withholds rights from companies with global consolidated monthly revenue
  above US$20 million. The pinned `LICENSE` file is kept beside every copy of
  the weights, bundled or downloaded.
- Weights:
  - Timestral-5M, `bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f`: bundled in the app.
  - Timestral-28M, `49b26409ac87b5935539a5d8ffe7f397b720db47`: bundled in the app.
  - Timestral-123M, `5a147287addda85f6acd8da3fb8858fe9af7e8f7`: downloaded on first use.
  - Timestral-209M, `9874d252ab0aae16f7f7c999f98f98d6ad7d8365`: downloaded on first use.

## Chronos-2 (Amazon)

- Upstream: https://github.com/amazon-science/chronos-forecasting
  (`chronos-forecasting` 2.3.2); weights https://huggingface.co/amazon/chronos-2
- Used: both. The Chronos-2 inference code is ported to Swift
  (`.../Kit/FM/Chronos/`), and the weights are loaded.
- Licence: Apache License 2.0 (code; the weights' model card at the pinned
  revision also states Apache-2.0, and the repository has no separate LICENSE
  file, so the card is kept beside the downloaded weights).
  Copyright Amazon.com, Inc. or its affiliates.
- Weights: `amazon/chronos-2`, revision `29ec3766d36d6f73f0696f85560a422f50e8498c`
  (about 478 MB), downloaded on first use; not bundled.

## TimesFM 2.5 (Google)

- Upstream: https://github.com/google-research/timesfm (`timesfm` 3.0.2);
  weights https://huggingface.co/google/timesfm-2.5-200m-pytorch
- Used: both. The TimesFM 2.5 inference code is ported to Swift
  (`.../Kit/FM/TimesFM/`), and the weights are loaded.
- Licence: Apache License 2.0 (code; the weights' model card at the pinned
  revision also states Apache-2.0, and the repository has no separate LICENSE
  file, so the card is kept beside the downloaded weights).
  Copyright 2025 Google LLC.
- Weights: `google/timesfm-2.5-200m-pytorch`, revision
  `1d952420fba87f3c6dee4f240de0f1a0fbc790e3` (about 925 MB), downloaded on
  first use; not bundled.
