"""Mistral Timestral-123M, zero-shot, on the 5-hour window (6 hours of context).
Lab score on the owner's history: median miss 3.00 pp vs the shipping
rule's 3.56 (research/lab/foundation)."""
from __future__ import annotations

from lab_timestral import forecast

ID = "lab-timestral-123m"
DISPLAY_NAME = "Timestral 123M (Mistral)"
SUMMARY = "Mistral's pretrained time-series model, 123M parameters, reading your recent meter history."
HOW_IT_WORKS = (
    "A zero-shot transformer from Mistral, pretrained on many time series and not trained on yours. It reads "
    "the last 6 hours of your cumulative meter burn on a 5-minute grid and forecasts the burn until the reset as "
    "quantiles; the median is the line and the 10th to 90th percentiles are the range."
)
WINDOWS = ("five_hour",)


def predict(window, account, t_cut, cycle_start, resets_at, history):
    return forecast("123M", history, t_cut, resets_at, 72)
