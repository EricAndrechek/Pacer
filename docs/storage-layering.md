# Where data should live: SwiftData, SQLite, DuckDB

Written because the layering stopped making sense and somebody asked the
obvious question: if the hot analytical reads bypass SwiftData to hit its own
SQLite file directly, what is SwiftData still for?

This is a decision record, not a plan of record. Nothing here is scheduled.

## What is actually stored, today

421 MB, 562,422 rows.

| table | rows | shape |
|---|---:|---|
| `ZTOKENSAMPLE` | 297,775 | append-only observation |
| `ZACCOUNTUSAGEARCHIVE` | 82,329 | append-only observation |
| `ZUSAGELIMITSAMPLE` | 71,010 | append-only observation |
| `ZRATELIMITSAMPLE` | 47,340 | append-only observation |
| `ZPREDICTIONSNAPSHOT` | 33,591 | append-only derived |
| `ZENGINEEVALOUTCOME` | 20,340 | append-only derived |
| hourly / daily / project / session rollups | ~7,000 | derived, rewritten |
| `Account`, `AlertRule`, `ProjectBudget`, `ProjectCollection`, aliases, meta | ~2,000 | **mutable state** |

98% of the rows are observations or things computed from them. The genuinely
stateful, user-edited object graph — the part an ORM is for — is about two
thousand rows.

The DuckDB archive (`raw-archive.duckdb`, 34 MB) holds exactly one table,
`turn`: raw token samples. It does **not** hold the rollups, the prediction
snapshots, or the limit samples. SwiftData remains the system of record;
`make verify-data` checks the archive against it and SwiftData wins any
disagreement.

## The proposal

Split by shape rather than by history:

- **SwiftData** — `Account`, `AlertRule`, `ProjectBudget`, `ProjectCollection`,
  path aliases, `ClaudeCodeMeta`. Small, mutable, edited by a person, wants an
  object graph and migrations. Roughly 2,000 rows.
- **DuckDB** — every sample table, every rollup, the prediction trail, the eval
  scoreboard. Append-only or fully derived, read in bulk ranges, never edited
  in place.

That is the right shape. Columnar storage is built for "scan 32 days of a
column", which is what the forecast does, and row-store object materialisation
is precisely what made it slow.

## What stops it being a free win

**1. The widget extension is a different process.** DuckDB takes an exclusive
per-process file lock — `RawArchive` says so in its own doc comment, and the
CLI refuses to open the file while Pacer is running. SQLite allows concurrent
readers across processes, which is how the widgets read usage at all today.
Moving usage data to DuckDB means the widgets can no longer read it directly;
the app would have to publish a snapshot for them. That is a real feature to
build, not a detail.

**2. It removes the independent verifier.** The archive is a *second copy*, and
`make verify-data` cross-checks it against SwiftData. That check has already
earned its keep — it is how the streaming-dedup bug was caught, which was
under-counting output tokens by 63%. Make DuckDB primary and there is no second
opinion to check against. Whatever replaces it has to be designed, not assumed.

**3. Reactivity — but this argument is nearly spent.** `@Query` updating the UI
when rows land is SwiftData's headline feature. This branch has spent most of
its performance work *removing* `@Query` from hot paths — the menu bar, the
notification host, the toolbar pill and the pace card are all now signal-gated
`@State` loads, because a query that re-runs on every context change was the
single most expensive pattern in the app. What is left mostly needs "something
changed, reload" rather than row-level observation, and that already exists as
`.pacerScanCycleDidComplete`.

**4. DuckDB is not free to hold open.** It sizes a worker pool to the core count
and parks every thread in `ExecuteForever`. Shipped unconfigured it cost a full
core continuously — measured at 100.3% average CPU over 22 hours. Configurable,
and configured now, but a caution for widening its footprint.

## Recommendation

Right target, wrong moment, and the urgency is gone.

The performance case for it evaporated when `RawLimitReader` took the two
expensive fetches from 5,103 ms to 150 ms for about two hundred lines. What
remains of a refit is modelling, not I/O; DuckDB would now be competing for
~150 ms out of ~2,700 ms.

What is left is an *architecture* argument, and a good one: the current layering
has a row-store ORM in the middle of an analytical workload with a hand-written
SQLite bypass around it. That is worth fixing on its own merits — but it is a
migration touching every read path, a new widget data path, and a replacement
for the cross-check that catches data bugs. That is a release of its own, not an
addendum to one.

If it is taken up, the order that de-risks it:

1. Move the **derived** tables first — rollups, prediction snapshots, eval
   outcomes. Nothing outside the app reads them, they can be rebuilt from
   samples, and a wrong answer is recoverable.
2. Keep `verify-data` meaningful by rebuilding rollups from DuckDB and
   comparing against a SwiftData rebuild, until confidence is earned.
3. Move samples last, and only once the widgets have a snapshot path.
4. `Account` and friends never move.
