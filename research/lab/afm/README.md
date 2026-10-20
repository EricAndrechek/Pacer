# Apple Foundation Models (on-device) as forecaster and router

Availability (macOS 27, Swift 6.4): `SystemLanguageModel.default.availability` = `available`.

Setup: `swift run -c release afm <prompts.jsonl> <out.jsonl>` (SwiftPM, tools 6.2, macOS 26+, Swift 5 mode). One fresh `LanguageModelSession` per prompt, temperature 0, guided generation into `@Generable struct Forecast { finalPercent: Double }` or `Pick { candidate: Int }`. Prompts are built by `prep.py` (`uv run afm/prep.py` from research/lab), preds by `finish.py`.

Sample (`sample_ids.csv`): 300 five-hour cases, round-robin over account x fold x cut (accounts 140/64/64/32, folds 0-3 = 38/36/98/128, cuts 0.2-0.9 about 37 each), plus all 276 seven-day cases.

Prompts: `afm-forecast` = window length, elapsed/remaining, the meter at each earlier cut, recent burn rate (last 10% of the window), and up to 4 past cycles of the same account (reset before t_cut) closest in used_now at the same cut, each with trajectory and final. `afm-router` = the same header plus four candidates (rule-current, engine-recent-rate, tok-decay-30m, tok-rate-1d-cal) with their prediction and mean abs error over the last 6 past cycles of this account at this cut; model returns an index, pred = that candidate's value (rule-current fallback if its value is missing). No leakage: only readings <= t_cut and cycles with resets_at < t_cut.

Latency: forecast mean 0.64 s (p95 0.77, max 1.7); router mean 0.59 s (p95 0.69). 0 errors in 1152 calls.

Results on the sampled cases (headline = median pp for 5h, mean pp for 7d):

| candidate | 5h (n=300) median / mean | 7d (n=276) mean |
|---|---|---|
| afm-forecast | 27.5 / 38.7 | 18.3 |
| afm-router | 2.62 / 8.08 | 7.86 |
| rule-current | 3.00 / 8.39 | 8.18 |
| tok-decay-30m (5h, n=299) | 2.67 / 7.94 | - |
| tok-rate-1d-cal (7d) | - | 7.80 |

Router picks: rule-current 325, engine-recent-rate 148, tok-decay-30m 91, tok-rate-1d-cal 12 (of 576).

Verdict: direct forecasting is unusable (the ~3B model emits arbitrary numbers, often 100; errors 5-9x worse than the rule). The router roughly matches its best candidate (5h 2.62 vs 2.67 for tok-decay-30m; 7d 7.86 vs 7.80) and shows no real gain over simply using the best token model; differences are inside sampling noise at n=300/276. Not worth pursuing at this size.
