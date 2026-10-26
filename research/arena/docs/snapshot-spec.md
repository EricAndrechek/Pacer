# Snapshot spec

From the phase-1 data round (2026-10-24). Numbers come from one real store and are given only for scale.


### 2.1 Tables

Scope key: **E** = every Pacer user; **M** = users with several accounts; **S** = this setup only. All times are UTC `timestamp[ms]`. Every table carries `t_event`, `t_known` and `t_known_src ∈ {history, modeled, observed, unknown}`.

| table | scope | grain | rows (approx.) |
|---|---|---|---|
| `turns` | E | API call | 781k |
| `turn_revisions` | E | update to a turn (from 09-24) | 640k |
| `meter_readings` | E | poll × window | ~700k before dedup |
| `cycles` | derived | account × window × reset | ~4k |
| `prices` | E | model × part × tier × modifier × period × source | ~3k |
| `accounts`, `account_events` | M (+S for cswap/rotation) | account; activation or switch | 4; ~1k |
| `sessions`, `prompts`, `subagent_spawns`, `session_cost_state` | E | session; prompt; spawn; session × model | ~1.2k; ~47k; ~4k; 0.3k |
| `limit_hits` | E | CC rate-limit error line | small |
| `app_alive` | derived | interval when Pacer was polling | ~2k |
| `predictions_of_record` | E | PredictionSnapshot row | 104.5k |
| `eval_of_record` | E | EngineEvalOutcome row | 111.6k |
| `meter_fits` | E | SpendMeterFit row | 22 |
| `regimes` | derived | dated boundary | ~25 |

**`turns`.** Columns have the latest scan's meaning: one row per API call, the finished copy, account by activation, and geo/speed filled in.
- `call_id` u64 is the HMAC of the dedup key. A row without a key hashes (session, t, model, tokens).
- `t_event` is the kept copy's timestamp. `account` is A1–A4.
- `model` keeps the raw id; add `model_family`.
- Token parts `input`, `output`, `cache_read`, `cache_write_5m`, `cache_write_1h`.
- `inference_geo`, `speed`. Re-fill from transcripts wherever a line survives: 35k finished Oct rows have null geo in the store but not in the line. Otherwise null means unknown, never "standard".
- `session_h`, `project_h` (canonical path), `subdir_depth` (depth of the original path below the canonical one; never the path), `cc_version`, `cc_version_num`.
- `tz_offset_min`, from `localHour` against UTC. It is −240 throughout, and the 11-01 DST change is a trap.
- From transcripts, null where pruned: `is_subagent`, `agent_kind` (main / fork / builtin / custom), `finished`, `entrypoint`, `api_error`.
- `output_regime ∈ {first_copy, finished, unfinished_interrupted, subagent_defect, subagent_defect_suspect, unknown}` and `output_reliable` bool.
- `output_imputed` and `output_imputed_src`: only for defect rows. The method is per-session `cost-state` reconciliation spread evenly over the session's unfinished calls, falling back to the per-model median gap. `output` itself is never overwritten.
- `attribution_src ∈ {manual_range, observed, credential, retro_reassign, desktop_restamp}` and `account_as_observed`: the account a replay of observed-only activations gives at `t_known`.
- `t_first_recorded`, `t_final_recorded`, `revised_mask` (account / output / project / geo_speed).
- No cost column. Cost is a view (§2.2).

**`turn_revisions`.** `call_id`, `t_recorded`, `kind ∈ {insert, output_upgrade, account_restamp, project_rewrite, geo_speed_patch}`.
- Decoded from `ACHANGE.ZCOLUMNS`: an MSB-first bitmap over TokenSample's attributes in alphabetical order. Bit 0 is accountId, bit 7 inferenceGeo, bit 12 outputTokens, bit 13 projectPath, bit 17 speed.
- What it has seen so far: 2,987 output upgrades (median 47 s after the turn, p99 46 min); restamps of 7,060 rows on 09-24 and 1,661 on 10-09; 262k geo/speed patches on 10-21; 103 project rewrites.
- History keeps no old values. A revision says *that* a value changed and *when*, not what it was before.

**`meter_readings`.** `account`, `window_kind ∈ {five_hour, seven_day, session, weekly_all, weekly_scoped}`, `scope_model` (Fable or null), `identity`, `util_pct` (an integer stored as float), `resets_at` (nullable), `state ∈ {active, idle}`, `is_active`, `severity`, `source ∈ {oauth, cswap, switcher}`, `origin ∈ {live, archive}`, `dup_group`, `backwards_pp`.
- The table is live ∪ archive, deduplicated on (account, window, `t_event`).
- **A null reset is kept as an explicit `idle` row with its util (0).** Four rows have p>0 and are flagged.
- Session and weekly_all report the same meters as 5h and 7d. Keep both, linked by `dup_group`. For 5h/7d, the RateLimitSample-derived rows are canonical.

**`cycles`** are for labels and helpers only:
- columns: `cycle_id`, `reset_at` (median of the cycle's resets), `start = reset − window`, `first_t`, `last_t`, `n`, `max_util`, `final_util`, `censored`, `t_label_known = max(reset_at, last_t)`;
- segment with the `RateLimitCycle.contains` rule (within half a window), never `==`.

**`prices`.** One table, two time axes, four sources.
- Sources: LiteLLM and models.dev commit periods from `research/price-history`; the curated rows with their audit corrections; Pacer's `PriceRecord`.
- Columns: `model`, `part`, `tier_threshold`, `geo_mult`, `speed_mult`, `rate_per_mtok`, `source`, `commit_sha`, `t_effective_from`/`to`, `t_known`, `is_correction`.

**`account_events`** holds:
- AccountActivation rows: start, end, source, and an evidence *category*, never the raw text;
- cswap "Switched" events (S);
- rotation-controller ticks (S, time of day only, so they need a date reconstructed from the log order).

**`accounts`.** Label, first seen, `plan_current` and `tier_current`. These are current values and must not be used as historical features.

**`prompts`.** Built from `history.jsonl`: `timestamp`, session and project hashes, no `display` or `pastedContents`. Covers 03-30 → now. Add transcript user turns where they survive: `origin ∈ {human, tool_result, scheduled, task_notification, compact}` from `promptSource` / `turnOrigin` / `scheduledTaskId`.

**`subagent_spawns`.** From `*.meta.json`: builtin vs custom (never the custom name), `model`, `spawnDepth`, `isFork`.

**`session_cost_state`.** The last `cost-state` per session and model. `t_known` is the timestamp of the line before it.

**`limit_hits`.** Assistant lines with `isApiErrorMessage` whose error is a rate limit. They are direct sightings of a meter at 100%.

**`app_alive`.** Polling intervals: gaps over 15 min between oauth polls close an interval.

**Records of what the app did.**
- `predictions_of_record`: every PredictionSnapshot column, including `pricingVersion`, `paramsVersion`, `engineVersion` and `method` (with a `lab` flag). They are preserved past the app's 180-day pruning.
- `eval_of_record`: add `retro` (period ended before 06-11, or a per-account period before 09-04) and `rescored`.
- Both are **baselines and labels only, never features.**

**Not exported:**
- rollups (derivable, and repriced);
- logs (rotating);
- session-wakes (S, derived from transcripts);
- stats-cache (stale);
- Desktop records, beyond an `entrypoint`/`is_desktop` flag.

### 2.2 Two clocks

`t_event` is when the event happened by its own clock. `t_known` is **the earliest moment the current Pacer, running then, would have held the row in its final form.**

| source | `t_known` |
|---|---|
| turns from 09-24 17:50 | first ACHANGE insert. If upgraded, `t_final_recorded`, the time the finished copy existed. History exists for 100% of these rows. Lag: p50 16 s, p90 95 s, p99 17 min, p99.9 49 min. |
| turns before then | `t_event` plus a lag drawn once per row, with a fixed seed, from the post-09-24 empirical distribution, then moved to the next `app_alive` start if Pacer was not polling. Before 05-07 (no polls), use p99. |
| readings (oauth) | ACHANGE insert, or else `t_event` (p99 4 s). |
| readings (cswap) | `t_event` is cswap's `fetchedAt`. Pacer inserts it later (p50 0.6 s, p90 40 s, p99 6 min), so use ACHANGE, or else a seeded draw from that distribution. |
| predictions | `recordedAt` (insert lag p50 3 s). |
| evals | first insert where history exists. Before that `unknown`: label-only. `recordedAt` is overwritten on rescoring, so negative "lag" of up to 28 days appears. |
| prices | catalog commit date + 24 h (Pacer's refresh interval) for LiteLLM/models.dev; `reviewedAt` (2026-10-21) for curated rows and corrections; `recordedAt` for the ledger. Never `effectiveFrom`. |
| activations | `startedAt` (observed); 09-03 creation for the manual range; `endedAt` known only when the next switch happens. |
| prompts, limit hits | `t_event`. |
| cost-state | the line's position in time. |

**Rewritten rows: keep the final value. Its `t_known` is the clock-driven availability under current code; the date a backfill happened to run is not used.**
- The v3 repair (08-04), the geo/speed patch (10-21) and the 09-24 attribution fix are code fixes. Today's Pacer would have computed those values at ingest. The arena trains forecasters that will run on today's Pacer, so its features should be what today's code knew at t.
- Gating on repair dates would hide July until 08-04 and remove real signal, and it buys nothing: the corrections are better readings of the past, not information about the future target.
- What does depend on later information is handled separately:
  1. the lag from a streamed upgrade, by using the finished copy's time;
  2. retro attribution, through `attribution_src` and `account_as_observed`;
  3. prices, through `t_known`;
  4. imputations, which carry their own `t_known`.
- Two harness modes:
  - `current_code` (default): `t_known ≤ T`.
  - `as_recorded` (strict, to reproduce baselines of record): rows visible from `t_first_recorded`, and revised columns masked to null before `t_revised`, because the old values are unknown.
- **Cost view.** `turns_costed(T)` prices each row with the rates whose `t_known ≤ T`. When no rate was known yet, cost is **null, never 0**.

### 2.3 Collection eras (dates from the data)

| from → to | change | columns affected |
|---|---|---|
| 03-30 → 07-02 | first-copy output; 07-02 is mixed | `output`, cost |
| 05-07 | readings start for A1; 5-min polling | readings |
| 07-03 | output clean (v3, repaired back to here) | `output` |
| 07-08 | polling ~60 s (A1); 15 s in Oct | reading cadence and resolution |
| 07-11 | scoped limits (Fable weekly, session, weekly_all) | readings |
| 08-25 → 09-15 | **suspected subagent defect**, CC 2.1.245–268 | `output` |
| 09-03 / 09-21 / 10-08 | accounts A2 / A3 / A4 first seen; per-account fits from 09-04 | `account` |
| 09-08; denser from 10-06 | cswap readings | secondary readings |
| 09-23 → 10-22 (stragglers to 10-24) | **verified subagent defect**, CC 2.1.280–306 | `output`, cost |
| 09-24 17:50 | SwiftData history begins (exact `t_known`); attribution clean | `t_known`, `account` |
| 10-19 | rotation controller live (S) | switch behaviour |
| 10-21/22 | geo/speed reliable for new rows; Cowork roots; ledger | `inference_geo`, `speed`, prices |
| 10-23 | per-account grading; unscoped rl snapshots stop; SpendMeterFit | evals, predictions |

**Clean spans by target:**
- 5h/7d meter paths: A1 from 05-07; others from first seen.
- Fable weekly: 07-11 →.
- Input and cache features: all of 03-30 →.
- Output and spend: 07-03 → 08-24, 09-16 → 09-22, and 10-22 →. Defect rows elsewhere carry `output_reliable=false`.
- Per-account turn attribution: from 09-24, earlier on single-account days.

### 2.4 Pseudonymization

- **Accounts** become A1–A4 in first-seen order. Org and account UUIDs, email, display name, org name and switcher slot are never exported.
- **Salted hashes.** Session ids, message and request ids, project paths (canonical and original), agent ids and file names all go through HMAC-SHA256 with a 32-byte salt, truncated to 64 bits.
  - The salt lives outside the repo and the snapshot (for example in `~/.local/share/pacer-arena/salt`).
  - The manifest holds only `salt_id = sha256(salt)[:8]`.
  - One salt per frozen snapshot, so the holdout joins the training data.
- **Kept as is:** public model ids, CC versions, real timestamps (resets and price dates depend on them), token counts.
- **Never exported:**
  - any message or prompt text, `pastedContents`, tool inputs and results;
  - cwd, paths, git branches, custom titles, agent names and custom agent types, PR links;
  - `ownerAccountUuid`/`ownerOrganizationUuid`, token or lane identifiers, log text, keychain anything.
- **Agents see only `train/`** (`t_known ≤ T_train`). `holdout/` is a separate directory outside the agent sandbox, readable only by the evaluator.

### 2.5 Validation the exporter must run (fail = no snapshot)

1. **Store vs transcripts.** Per (day, model, account) where transcripts cover ≥95% of keys, all five token parts against the `isKept` copy. **Exact**: today 415,945 of 415,945 match. Also report coverage per day.
2. **Store vs DuckDB archive.** Row count and six sums, exact.
3. **`cost-state` vs transcripts.** Per session, for sessions with matched cache coverage: median ratio within 1.00 ± 0.02 where `output_reliable`. Report the defect sessions. This keeps catching new CC defects.
4. **Readings:**
   - within a cycle, util never falls by more than 1 pp (flag and count the rest; 15 known);
   - resets jitter within a cycle ≤ 5 s at p99.9;
   - no gap over 30 min while that account has turns, unless `app_alive` is closed;
   - idle rows have util 0.
5. **Cycles:**
   - cycles do not overlap per account and window;
   - resets increase strictly;
   - an observed cycle lasts its window ± 2 min;
   - the first reading after a reset is ≤ the previous cycle's max.
6. **Prices.** Every (model, `t_event`) in turns has a ledger rate. Report every turn whose rate had no catalog `t_known ≤ t_known(turn)` (launch lag); never price it at 0.
7. **Point-in-time self-test.** At 200 random cutoffs, the harness slice equals a raw filter on `t_known ≤ T`, and `train/` holds no row with `t_known > T_train`.
8. **Determinism.** Re-export from the frozen inputs and get byte-identical content hashes.
9. **Leak scan.** String columns must not contain `/Users/`, `@`, UUID-shaped strings, raw account prefixes, or any known project name.

### 2.6 Point-in-time traps the harness must enforce

From the inventory (all still apply): whole-history diurnal grids; today's-ledger costs (cost v19); backdated `effectiveFrom`; rewritten turns; ingest lag; after-the-fact eval rows; cycle truth needs later readings (labels only); open buckets are partial; current-only account attributes; `scoped_identities` survivorship; PredictionSnapshot pruning and its `pricingVersion` join; SpendMeterFit and wakes constants fitted later.

Found here:
- **Imputed output uses session-end `cost-state`.** Gate it on its own `t_known`.
- **cswap readings are stamped with cswap's fetch time** and arrive up to minutes later.
- **Upgraded rows keep the partial copy's timestamp**, so the finished output exists seconds to minutes after `t_event`.
- **An activation's `endedAt` is future information** until the next switch.
- **Transcript-only columns are null before about 09-15.** A model can learn "null ⇒ old era". Ship availability masks, and score with and without those columns.
- **Fold boundaries come from the calendar**, never from quantiles over cases.
- **`localHour` is stored at insert.** Use `tz_offset_min`; DST shifts on 11-01.
- **"Generalize to anyone".** Any feature from an S table must be droppable, and scores are reported both with and without S features.

### 2.7 Size and layout

The measured zstd prototype of `turns` is **14.6 MB** (hashed keys). The transcript-derived columns add about 10 MB, and every other table is under 15 MB in total. **The whole snapshot is about 60 MB**, small enough for memory, so layout is about clean as-of cuts rather than speed.

```
research/arena/data/<snapshot_id>/         (gitignored)
  manifest.json      # ids, created_at, frozen, source fingerprints (store size + max Z_PK
                     #   per table + max ATRANSACTION ts; transcript count/bytes/max mtime),
                     #   exporter git sha, scan v5 / cost v19, price-history shas, salt_id,
                     #   row counts + content hashes, T_train, lag-model params, validation summary
  train/  turns/month=YYYY-MM/*.parquet      # partitioned by month of t_known, sorted by t_known
          meter_readings/window=…/month=…/*.parquet
          turn_revisions/, predictions_of_record/, eval_of_record/  (month of t_known)
          prices.parquet  accounts.parquet  account_events.parquet
          sessions.parquet  prompts.parquet  subagent_spawns.parquet  session_cost_state.parquet
          limit_hits.parquet  app_alive.parquet  regimes.parquet  meter_fits.parquet
  holdout/ (same tree, months after T_train; evaluator-only)
  labels/  cycles.parquet, eval truth columns (harness-only; never features)
  validation/report.json
```

Partition by month of **`t_known`**, not `t_event`. A held-back month is then a set of whole files, and the harness reads `WHERE t_known <= $T` with row-group pruning: zstd, row groups of about 100k, statistics on `t_known` and `t_event`. Small tables stay as single files.
