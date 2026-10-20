# session-wakes

This builds a DuckDB dataset of Claude Code "wakes" and GitHub/CI activity from every local transcript, so
watcher changes can be measured before and after they land. It only reads the transcripts. It is local and
git-excluded.

## Run

```sh
cd ~/Code/public-projects/Pacer/.claude/skills/account-rotation/analysis
uv run --no-project --with duckdb --with pyarrow python3 -I extract.py          # incremental, ~3 s
uv run --no-project --with duckdb --with pyarrow python3 -I extract.py --full   # rebuild everything, ~20 s
uv run --no-project --with duckdb --with pyarrow python3 -I verify.py [sid] [day]  # self-checks
duckdb -readonly ~/.cache/session-wakes/wakes.duckdb -f queries.sql             # or paste one section
```

Always open the database with `-readonly`, so readers never block each other or `extract.py`. `extract.py`
only opens `wakes.duckdb` when its view definitions change. A run otherwise rewrites the parquet files that
the views read.

## Optional inputs (environment)

The extractor reads only transcripts unless these are set. Each has no default, and an unset one leaves its
table empty.

| variable | meaning |
|---|---|
| `WAKES_CI_WAIT_POLLS` | JSONL of CI-wait poll requests (`ts`, `pid`, `url`, `code`, `remaining`, `resource`) |
| `WAKES_ROLLOUT_LOG` | JSONL of watcher-engine rollout events (`ts`, `change`, `version`, `event`, `session`, ...) |
| `WAKES_EXCLUDE` | `;`-separated rules flagging requests to leave out of totals: `cwd:<LIKE pattern>` or `window:<ISO start>/<ISO end>` |
| `WAKES_WATCH_EXTRA` | regex alternation naming extra watcher launch commands |
| `WAKES_PILOT_RE` | regex with one group capturing a watcher-engine version in a command |
| `WAKES_AWS_MARK` | substring marking an AWS-support event line |

## What is scanned

- `~/.claude/projects` and `~/.config/claude/projects`, plus `~/.claude-swap-backup/sessions/*/projects` if
  present.
- Files are deduplicated by realpath. A project dir that is a symlink to another is read once.
- A main session is `<proj>/<sid>.jsonl`.
- A lane is `<proj>/<sid>/subagents/**/agent-<id>.jsonl`, workflow agents included. Its `agent-*.meta.json`
  supplies the type and description.

Lines are streamed, and malformed lines are skipped. A partial last line is left for the next run.

On an incremental run, an appended file is re-parsed from the start of its last turn, and that file's rows
from that turn on are replaced. A file that shrank or changed inode is re-parsed whole. Rows of transcripts
that Claude Code has since deleted are kept.

## Tables (views in wakes.duckdb, files in ~/.cache/session-wakes/*.parquet)

| table | one row per | notes |
|---|---|---|
| `api_calls` | assistant API response | Deduplicated globally on `message.id:requestId`. A streamed message is written several times; the kept copy has a non-null `stop_reason`, else the largest `output_tokens`. `<synthetic>` records are excluded and their errors go to `api_errors`. Cache writes come from `cache_creation.ephemeral_5m/1h`, else `cache_creation_input_tokens` as 5m. Each row has `weight` and `context_tokens` (input + cache_read + cache_write). |
| `tool_calls` | tool_use block | `category` is one of `watcher_launch`, `outbound`, `write`, `read_only`, `other`. Bash `command` is kept to 2k chars, plus `run_in_background`; SendMessage keeps `to` and `message`; Agent keeps `agent_model`, `subagent_type`, `effort`. Also `script_*` for watchers, `n_gh`, and `result_head` (300 chars of the result). |
| `gh_calls` | `gh` invocation inside a Bash/Monitor command | Several per compound command. Columns: `sub`, `verb`, `endpoint` (normalised `gh api` path), `method`, `is_write`. `polling` is `watch_mode` (`run watch`, `pr checks --watch`) or `poll_loop` (`run list/view` or `pr checks` inside a while/until/for loop with sleep). `in_loop_cmd` is ghscan's command-level loop flag. `ci_wait_target` names the ci-wait subcommand that should replace the call. |
| `turns` | turn | Described below. |
| `watcher_events` | watcher launch | Monitor, or a background Bash that runs idle-watch, repo-watch, watch-repos, `*watch*.sh`, `tail -F`, an `idle.sh` wrapper, or an engine path named in `WAKES_WATCH_EXTRA`. Columns: `script_path`, `script_name`, `pilot_version`, `engine_version` (from the command, else from a rollout `cutover` row), `watch_marker`, `first_of_path_in_session`, `n_wakes_caused`. |
| `lanes` | subagent file | Turns, calls, weight; first, median and max `first_call_cache_read`; `max_context`. `call_n_/turn_200k` and `call_n_/turn_400k` give the call and turn at which context first crossed each size. `turn_fc_*` is the same measured on each turn's first call. |
| `ci_wait_calls` | Bash/Monitor command containing `/ci-wait` | `subcommand` is `wait`, `status`, `log`, `stats` or `mention` (the command names the file without running it). The n_* columns count invocations. |
| `ci_wait_polls` | line of the JSONL named by `WAKES_CI_WAIT_POLLS` (empty if unset) | `kind` is `poll` or `job-log` (a 302 log fetch). `is_free` means code 304. Each pid is attributed to a session and lane with `attributed_by` = `ids`, `shared-ids` or `repo`. `is_excluded` marks pids traced to a session matching a `WAKES_EXCLUDE` `cwd:` rule; `in_excluded_window` marks a `window:` rule. |
| `rollout` | line of the JSONL named by `WAKES_ROLLOUT_LOG` (empty if unset) | `session_id` is resolved from `session` by title or project suffix, choosing the nearest activity. |
| `peer_names`, `session_markers` | | `peer_names` holds the name other sessions see for a session, learned by matching its SendMessage text to their peer wakes. `session_markers` holds its `agent:X` markers. |
| `api_errors` | synthetic error record | For example `rate_limit`, with the limit text. |
| `cutovers` | table you fill | A real table in `wakes.duckdb`. Fill it with `cutovers_for(change, regex)` or `watcher_cutovers(regex, change)`; see queries.sql (c). |

## Turns and triggers

A turn runs from a record that starts model activity to the next one. Records that carry only tool results
continue the current turn. So do notifications injected mid-turn: attachments in a main session, isMeta user
records in a lane that is busy.

`trigger` is one of the following.

- `human`: typed text.
- `bg-task`: a background command finished.
- `monitor-event`.
- `peer-sendmessage`: a cross-session message.
- `subagent-handback`: a peer message starting `[Subagent hand-back]`.
- `subagent-done`: an Agent completion notification.
- `scheduled`: a cron or scheduled prompt, detected from `scheduledTaskId` / `turnOrigin`.
- `compact-resume`.
- `auto-continuation`: the usage limit reset.
- `coordinator`: the parent messaging an idle lane. This is lanes only.
- `lane-start`: a lane's first prompt.
- `other`: interrupts and anything unrecognised.

`trigger_raw` is the exact label wakes.py would give, kept for cross-checks.

Turn columns:

- `first_call_cache_read`: the context at the wake.
- `weight`: Opus-relative. Input counts 1, output 5, a 5m cache write 1.25, a 1h cache write 2, a cache
  read 0.1. Multiply by 0.6 for sonnet, 0.2 for haiku, 2.0 for fable.

Flags:

- `is_wake`: the trigger is not `human` or `lane-start`.
- `is_wake_wakespy`: the wakes.py definition.
- `zero_tool`.
- `light`: at most 3 tool calls.
- `relaunch_only`: at most 3 tool calls, at least 1 `watcher_launch`, no `write` and no `outbound`.
- `relaunch_only_wakespy`.
- `digest_able`: a watcher wake whose only content lines are digest kinds: `[other]` items, "all emitting
  loops are registered again", `Terminated: 15`, a watcher source exiting, REAPPEARED self-checks, or
  `✅ RESOLVED` transitions. `digest_resolved` is the sub-flag for RESOLVED, which is batched rather than
  digested. The content is the notification's `<event>`, or the session's first read of the task's
  `.output` file or of an `idle-watch-last.*` copy. `content_class` gives the reason for every other wake.
- `spurious`: `is_wake`, not a peer, hand-back or coordinator message, and `zero_tool`, `relaunch_only` or
  `digest_able`.
- `rate_limited`.
- `has_calls`: left out of every query when false.

## Known caveats

- **wakes.py comparability.** wakes.py's line filter (`"type":"assistant"` within the first 3,000 chars,
  `"type":"user"` within the first 600) skips 20–27% of assistant records in today's transcripts. It
  therefore misses some turns, calls and tool uses. With that filter removed, a copy of wakes.py reproduces
  this dataset's per-trigger n, cache_read and calls/turn exactly.
- **Turns wakes.py folds away.** wakes.py also folds scheduled prompts (isMeta) into the previous turn. They
  are their own `scheduled` turns here.
- **gh counts.** Heredoc bodies, `--body`/`-m`/`--title` strings and grep/pgrep patterns are stripped before
  matching. A gh call quoted inside some other string is still counted. Loop iterations and `--watch`
  internals are invisible, and so is a watcher's own background polling.
- **ci-wait cutover.** The cutover is the first command containing `/ci-wait`, as the brief defines it. A
  helper script that runs ci-wait internally (a merge script, say) is invisible. Its pids are
  attributed by repo.
- **Poll log.** If the tool truncates its log, nothing earlier survives; use `WAKES_EXCLUDE` windows for known test runs.
- **Tier-engine cutover.** A project that launches the engine through a wrapper such as `idle.sh`, means the engine path never appears in
  a transcript. Its engine version comes from the rollout `cutover` row.
- **Dedup.** 2,063 message keys appear in more than one file (fork or resume replays). Each is counted once.
- **Lanes.** About 63% of all 7-day weight sits in lanes. Sessions on the old Monitor era make up most
  `monitor-event` turns.
- **Context normalisation.** `weight_per_wake_per_100k_ctx` divides by `first_call_context`, so wakes on a
  growing context compare fairly.
