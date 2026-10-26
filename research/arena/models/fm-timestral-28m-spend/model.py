"""A pretrained forecaster on hourly spend and tokens; the logic is
kit.fm.spend_model (shared by every fm-*-spend), the forecaster, covariates
and variates are in model.toml."""
from kit.fm.spend_model import SpendModel as Model  # noqa: F401
