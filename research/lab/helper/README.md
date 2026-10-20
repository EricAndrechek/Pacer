# Prediction-lab helper

Serves forecasters written in Python to a **dev build** of Pacer, so a model
from the lab can compete in the app next to the built-in roster. In the app it
gets a record, it can be selected, it gets a calibrated band, and it shows in
the compare sheet, all against the live data.

The helper is a small loopback HTTP server (standard library only). It reads
Pacer's live store **read-only** (`?mode=ro`, WAL-safe, short connections)
and calls the predictors in `predictors/`. A predictor only sees readings at
or before the cut it is asked about. The helper does that slicing itself and
does not rely on the predictor to filter.

## Start it

```sh
make lab-helper            # background, 127.0.0.1:7231, log ~/Library/Logs/Pacer/lab-helper.log
make lab-helper-status     # is it up, what does it serve, per-model call/error counts
make lab-helper-stop
make lab-helper-test       # its own tests (a throwaway store, never the live one)
```

or in the foreground:

```sh
cd research/lab/helper
uv run server.py                          # --port 7231 --store <pacer.sqlite> --predictors predictors/ -v
```

`PACER_LAB_PORT=7299 make lab-helper` runs a second helper on another port.
Its log and pid files are kept per port, so it never collides with the one on
7231.

## Turn it on in the dev build

The app looks for the helper only when this App Group default is set (or the
process environment has `PACER_LAB_HELPER`). Without it the engine behaves
exactly like the shipping build.

```sh
# on
defaults write "$HOME/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/Library/Preferences/YZXWMJ5VBY.com.ericandrechek.pacer.plist" \
    PacerLabHelperURL "http://127.0.0.1:7231"

# off
defaults delete "$HOME/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/Library/Preferences/YZXWMJ5VBY.com.ericandrechek.pacer.plist" \
    PacerLabHelperURL
```

Use the full plist path. The app reads its App Group suite from the group
container, so `defaults write YZXWMJ5VBY.com.ericandrechek.pacer …` would
write a different file (`~/Library/Preferences/…`) that the app never reads.
The setting is read on every refit. A shell write can take a moment to reach a
running app, so relaunch Pacer if you need it to apply right away. Use
`127.0.0.1` rather than `localhost`.

The installed app needs the build from this branch (`make install`), because
the Swift side of the integration is in it. Check the log (`make logs-tail`)
for:

```
[Lab] helper serves 1 model(s): lab-recent-rate-py
[Engine] record backfill 8c95: +… outcome(s) …, lab +… for 1 model(s)
```

`[Lab] helper not reachable (…)` is logged once when the helper stops
answering, and `[Lab] helper reachable` once when it comes back.

## What the app does with it

* **Each refit** (≥ 300 s apart) the engine sends one `POST /v1/forecast` per
  window the helper serves. The request carries the live cycle (one cut: now)
  plus up to two recently completed cycles that model has no record for yet
  (all their scored cuts). It is sent after the features are built and before
  the fit, with a 1.5 s timeout (`deadlineMs` 1200 tells the helper to answer
  with what it has by then). `GET /v1/models` is asked at most once a minute.
  The requests run off the main actor and never on a scan tick.
* **A helper model is a roster member.** Its line runs straight from the live
  reading to the final it predicts at the reset. The value shown is that final
  clamped to [meter, 100], which is also the value its record scores. Like
  every model, its band comes from conformal calibration on its own record.
  The helper's own `q10`/`q90` are carried but not shown, so bands stay
  comparable across models.
* **Record.** Live refits score cycles as they finish. The full-history pass
  (the archive included) scores each model over every completed cycle, at the
  same eight cuts the built-ins use. The pass's marker lists the models it has
  covered, so **registering a predictor re-runs the pass for that model
  alone**, either on the next launch or while the app is running, the next
  refit after the helper starts serving it. If a model's batch fails, the
  model is retried no sooner than 30 minutes later.
* **Selection** is the record's usual rule, with two extra conditions for a
  lab model. It can take a window only once the full-history pass has covered
  it, and only on a refit where the helper answered for the live cycle. Until
  then it draws its line and shows its record, but does not compete. Without
  the first condition, a model whose record was the two cycles of its first
  refit beat models with hundreds of cycles on the real store. On a near-tie
  (within 5%) the simpler model wins, and a helper model's default complexity
  (6) is above every built-in. So a lab model is shown only when it is
  actually better.
* **Failure costs only its own models.** If the helper is down from the start,
  there are no lab models. If it stops answering, its models stay listed in
  the compare sheet as "lab helper not reachable", without a line. If the
  helper answers but a model declines, it says "no forecast from the lab
  model". Everything else is unchanged.
* **Turned off**, lab rows already in the record are ignored, so selection
  matches a store that never had them. They are not deleted.
* **Ids** must start with `lab-`. The app rejects anything else, so a helper
  can never write into a built-in model's record.

## Add a predictor

Drop a file in `predictors/` (names starting with `_` are skipped):

```python
# predictors/my_model.py
ID = "lab-my-model-v1"              # lab-…; letters, digits . _ -
DISPLAY_NAME = "My model"           # the compare sheet's row
SUMMARY = "One line for the hover."
HOW_IT_WORKS = "The info popover: what it does, with its numbers."
WINDOWS = ("five_hour", "seven_day")   # or a scoped identity, or ("*",)
COMPLEXITY = 6                       # optional; tie-break rank (built-ins are 1–5)

def predict(window, account, t_cut, cycle_start, resets_at, history):
    """The final usage (percentage points) expected at `resets_at`, seen from
    `t_cut`. Return (final, q10, q90), with q10/q90 optional (None), or None to
    decline. A plain number also works."""
    cycle = history.cycle()              # this cycle's readings up to the cut
    if len(cycle) < 3:
        return None
    ...
    return final, None, None
```

Then either `curl -X POST http://127.0.0.1:7231/v1/reload` or `make
lab-helper-stop lab-helper`. The app picks the new model up on its next refit
and backfills its record.

`history` (`lab_history.History`) holds **only readings with `t <= t_cut`**:

| | |
| --- | --- |
| `history.readings` | every reading of this window and account up to the cut, all cycles: `Reading(t, pct, resets_at)` |
| `history.cycle()` | this cycle's readings (after `cycle_start`, with this cycle's reset) |
| `history.used_now()` | the meter at the cut (0 before the first reading) |
| `history.since(t0)` | readings from `t0` to the cut |
| `history.completed_cycles()` | cycles that had **reset** by the cut: `Cycle(cycle_start, resets_at, readings, final)`, the only legitimate training targets |
| `history.window_readings("seven_day")` | another window of the same account, up to the cut |
| `history.duration`, `.t_cut`, `.cycle_start`, `.resets_at` | the cycle's frame (unix seconds) |

Rules:

* **No peeking.** Use only `history` and the arguments. Don't open the store
  or the lab's parquet snapshot from inside a predictor; they hold the future.
* **Fast.** A live request has ~1.2 s for every model together. The
  full-history pass asks for up to 8 cycles × 8 cuts per request, with a 20 s
  budget. Train once and cache. If the cache is keyed on a bucket of the cut,
  floor that bucket: a model fitted on cycles that reset before
  `floor(t_cut to the day)` uses strictly less than it is allowed to.
* **A changed model gets a new ID** (`-v2`). The record is keyed by id, so an
  edited model under an old id would mix two models' scores. The old id's rows
  stay in the store and are harmless.
* **Dependencies:** `uv add numpy` (etc.) in this directory.
* A predictor that raises returns null for that cut. The error is logged and
  counted in `/healthz`, and the helper keeps running.

`predictors/lab_recent_rate_py.py` is the plumbing check: the built-in
`recent-rate` rule ported to Python. Its record in the app should track
`recent-rate`'s. A gap points at the plumbing (cuts, cycle bounds, slicing),
not at the model.

## Check the plumbing

Two opt-in Swift tests run the real client against a real helper. Both are
skipped unless their variables are set.

```sh
# wire format: the Swift client against a helper on a spare port
PACER_LAB_PORT=7299 make lab-helper
cd PacerCore && PACER_LAB_E2E_URL=http://127.0.0.1:7299 swift test --filter LabHelperEndToEnd

# the engine and the helper over one frozen copy of the real store
mkdir /tmp/pacer-lab-e2e && for s in "" -wal -shm; do
  cp -c "$HOME/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite$s" /tmp/pacer-lab-e2e/ 2>/dev/null; done
PACER_LAB_PORT=7299 PACER_LAB_STORE=/tmp/pacer-lab-e2e/pacer.sqlite make lab-helper
cd PacerCore && PACER_LAB_E2E_STORE=/tmp/pacer-lab-e2e/pacer.sqlite PACER_LAB_E2E_URL=http://127.0.0.1:7299 \
  swift test --filter LabRealStoreTests          # prints the comparison; optional PACER_LAB_E2E_ACCOUNT
PACER_LAB_PORT=7299 make lab-helper-stop          # then delete /tmp/pacer-lab-e2e
```

The second test writes outcomes into the copy, never into the live store.
On the owner's store on 2026-10-20, `lab-recent-rate-py` matched the
built-in `recent-rate` on 100% of 2,805 scored 5-hour (cycle, cut) pairs and on
183 of 184 7-day pairs. The odd 7-day pair is an older built-in row: the pass
never re-scores existing rows. Once its record was complete, its typical error
on the compare sheet was the built-in's to the hundredth (8.90 pp).

## API

```
GET  /healthz       {"ok", "store", "storeExists", "uptimeS", "pid", "predictors": {id: {calls, declined, errors, meanMs, lastError}}}
GET  /v1/models     {"models": [{"id", "displayName", "summary", "howItWorks", "windows", "complexity"}]}
POST /v1/reload     re-scan predictors/; answers like /v1/models
POST /v1/forecast
```

`/v1/forecast` request (the app always sends the batch form):

```json
{"window": "five_hour", "duration": 18000, "account": "<account uuid>",
 "cycles": [{"cycleStart": 1760000000.0, "resetsAt": 1760018000.0, "cuts": [1760009000.0]}],
 "models": ["lab-recent-rate-py"], "deadlineMs": 1200}
```

The single-cycle form puts `cycleStart`, `resetsAt` and `cuts` at the top
level instead of `cycles`. `models` (default: every model serving the window),
`deadlineMs` and `duration` (needed only for a window the helper doesn't know,
i.e. a scoped identity) are optional. A missing or null `account` reads every
account's live rows and no archive, which is how the app reads with no account.

Response: per cycle in request order, per model, one entry per cut in request
order, `null` where the model declined or the deadline passed:

```json
{"window": "five_hour", "account": "…", "truncated": false, "elapsedMs": 3.1,
 "cycles": [{"cycleStart": …, "resetsAt": …, "cuts": […],
             "predictions": {"lab-recent-rate-py": [{"final": 63.2, "q10": null, "q90": null}]}}],
 "predictions": {…}}
```

The top-level `predictions` field is present only for the single-cycle form.

## Data it reads

The same rows the app's engine and `research/harness/pacer_replay.py` read:
`ZRATELIMITSAMPLE` (fixed windows) or `ZUSAGELIMITSAMPLE` (scoped identities),
plus the account's `ZACCOUNTUSAGEARCHIVE` rows of kind `rate_limit` /
`usage_limit`. Live and archived rows are merged on the sample instant and
the live copy wins. Each series is loaded once (every account's fixed windows
at startup), topped up with new live rows per request, and fully reloaded in
the background every 15 minutes.
