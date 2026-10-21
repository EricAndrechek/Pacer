-- Session-wakes queries. Open the db read-only so extract.py and other readers never block:
--   duckdb -readonly ~/.cache/session-wakes/wakes.duckdb -f queries.sql      (whole file)
--   or paste one section. All timestamps are UTC (TIMESTAMPTZ); run `SET TimeZone='UTC';` first.
-- Window parameters are DuckDB variables; change them with SET VARIABLE before a section.
SET TimeZone = 'UTC';
SET VARIABLE data_end = (SELECT max(ts) FROM tool_calls);        -- end of the transcripts we have

-- =====================================================================================
-- A. GitHub (gh) invocations, ci-wait cutover, ci-wait polls
-- =====================================================================================

-- A0. gh per session and lane per hour. One row per (session, lane, hour). `lane` = 'main' or the
--     subagent's agent id. polling = `gh run watch`, `gh pr checks --watch`, or `gh run list|view` /
--     `gh pr checks` inside a while/until/for loop with sleep (gh_calls.poll_loop) -- the "before" markers.
--     poll_loop_cmds counts COMMANDS that loop+sleep around any gh call (a common 'polling loop' definition).
CREATE OR REPLACE TEMP VIEW gh_hourly AS
SELECT g.session_id, any_value(t.title) AS title, any_value(t.project) AS project, g.lane, g.is_subagent,
       date_trunc('hour', g.ts) AS hour,
       count(*) AS gh,
       count(*) FILTER (sub = 'api') AS api,
       count(*) FILTER (sub = 'run' AND verb = 'watch') AS run_watch,
       count(*) FILTER (sub = 'run' AND verb = 'list') AS run_list,
       count(*) FILTER (sub = 'run' AND verb = 'view') AS run_view,
       count(*) FILTER (sub = 'pr' AND verb = 'checks') AS pr_checks,
       count(*) FILTER (sub = 'pr' AND verb IN ('view', 'list')) AS pr_view_list,
       count(*) FILTER (sub = 'issue' AND verb IN ('view', 'list')) AS issue_view_list,
       count(*) FILTER (sub = 'search') AS search,
       count(*) FILTER (is_write) AS writes,
       count(*) FILTER (polling) AS polling,
       count(DISTINCT tool_use_id) FILTER (in_loop_cmd) AS poll_loop_cmds,
       -- ci-wait v3 targets: job logs -> `ci-wait log`; single run view/list (+ pr checks) -> `ci-wait status`
       count(*) FILTER (sub = 'api' AND endpoint LIKE '%actions/jobs/%/logs%') AS api_job_logs,
       count(*) FILTER (sub = 'api' AND endpoint LIKE '%actions/runs/%/jobs%') AS api_run_jobs,
       count(*) FILTER (ci_wait_target = 'ci-wait log') AS to_ci_wait_log,
       count(*) FILTER (sub = 'run' AND verb IN ('view', 'list') AND NOT polling) AS single_run_view_list,
       count(*) FILTER (ci_wait_target = 'ci-wait status') AS to_ci_wait_status
FROM gh_calls g
LEFT JOIN (SELECT DISTINCT session_id, title, project FROM turns) t USING (session_id)
GROUP BY g.session_id, g.lane, g.is_subagent, hour;

-- A0 example: the last 6 hours, busiest first
SELECT hour, session_id[1:8] AS sid, coalesce(title, regexp_replace(project, '^-Users-[^-]+-Code-', '')) AS who,
       lane, gh, api, run_watch, run_list, run_view, pr_checks, writes, polling, poll_loop_cmds,
       to_ci_wait_log, single_run_view_list, to_ci_wait_status
FROM gh_hourly WHERE hour >= getvariable('data_end') - INTERVAL 6 HOUR
ORDER BY hour DESC, gh DESC LIMIT 60;

-- A1. ci-wait cutover per session = its first Bash/Monitor call containing '/ci-wait' (main or any lane),
--     with the version deployed at that moment (v1 2a757f0 20:30:46Z, v2 e61ab4d 20:34:16Z, v3 853fb7f 21:02:03Z).
--     waits/statuses/logs count invocations (`/ci-wait <ids>|--pr|--sha`, `/ci-wait status`, `/ci-wait log`);
--     mentions = commands that only name the file (git add cli/ci-wait). The cutover itself follows the brief:
--     the first command CONTAINING /ci-wait.
CREATE OR REPLACE TEMP VIEW ci_wait_cutover AS
SELECT c.session_id, any_value(t.title) AS title, any_value(t.project) AS project,
       min(c.ts) AS cutover_ts,
       arg_min(coalesce(c.agent_id, 'main'), c.ts) AS first_lane,
       CASE WHEN min(c.ts) >= TIMESTAMPTZ '2026-10-19 21:02:03+00' THEN '853fb7f'
            WHEN min(c.ts) >= TIMESTAMPTZ '2026-10-19 20:34:16+00' THEN 'e61ab4d'
            WHEN min(c.ts) >= TIMESTAMPTZ '2026-10-19 20:30:46+00' THEN '2a757f0'
            ELSE 'pre-deploy (dev build)' END AS version_at_cutover,
       count(*) AS ci_wait_calls, count(DISTINCT coalesce(c.agent_id, 'main')) AS lanes_using,
       sum(c.n_wait) AS waits, sum(c.n_status) AS statuses, sum(c.n_log) AS logs,
       count(*) FILTER (c.subcommand = 'mention') AS mentions
FROM ci_wait_calls c LEFT JOIN (SELECT DISTINCT session_id, title, project FROM turns) t USING (session_id)
GROUP BY c.session_id;
SELECT session_id[1:8] AS sid, coalesce(title, project) AS who, cutover_ts, first_lane, version_at_cutover, ci_wait_calls,
       lanes_using, waits, statuses, logs, mentions
FROM ci_wait_cutover ORDER BY cutover_ts;

-- A2. ci-wait polls (the JSONL named by WAKES_CI_WAIT_POLLS; empty when unset). A 304 costs no rate-limit budget.
--     is_excluded = requests from pids traced to a session matching a WAKES_EXCLUDE `cwd:` rule (e.g. the
--     tooling's own test runs); in_excluded_window = requests inside a `window:` rule. attributed_by: ids (run id/sha/PR in the command), shared-ids
--     (shares a run/sha with an attributed pid), repo (a helper script ran it; latest ci-wait caller in that repo).
--     kind: poll = run/PR/sha polls (200 billed, 304 free); job-log = failed-job log fetch (302 redirect, v3 `log`).
SELECT kind, code, count(*) AS n, count(*) FILTER (NOT is_excluded) AS n_excl FROM ci_wait_polls GROUP BY ALL ORDER BY kind, code;
SELECT date_trunc('hour', ts) AS hour, count(*) FILTER (kind = 'poll') AS polls, count(*) FILTER (is_free) AS free_304,
       count(*) FILTER (kind = 'poll' AND NOT is_free) AS billed, count(*) FILTER (kind = 'job-log') AS job_log_302,
       round(100.0 * count(*) FILTER (is_free) / count(*) FILTER (kind = 'poll'), 1) AS pct_free,
       count(DISTINCT pid) AS processes, min(remaining) AS min_remaining
FROM ci_wait_polls WHERE NOT is_excluded GROUP BY 1 ORDER BY 1;
SELECT session_id[1:8] AS sid, coalesce(agent_id, 'main') AS lane, attributed_by, count(DISTINCT pid) AS pids,
       count(*) AS requests, count(*) FILTER (is_free) AS free_304, bool_or(is_excluded) AS excluded
FROM ci_wait_polls GROUP BY ALL ORDER BY requests DESC;

-- A3. BEFORE vs AFTER each session's ci-wait cutover, gh invocations and polling. Equal windows:
--     after = [cutover, data_end); before = the same length immediately before the cutover.
--     Rates are per hour; raw counts and the window length are shown because the after window is short.
--     The `ALL (machine, deploy 20:30:46Z)` row uses the v1 deploy time as the cutover for every session.
SET VARIABLE max_window = INTERVAL 24 HOUR;   -- cap on each window
CREATE OR REPLACE TEMP VIEW ci_wait_before_after AS
WITH c AS (SELECT session_id, cutover_ts,
                  least(getvariable('data_end') - cutover_ts, getvariable('max_window')) AS win
           FROM ci_wait_cutover
           UNION ALL
           SELECT '(ALL machine, deploy 20:30:46Z)', TIMESTAMPTZ '2026-10-19 20:30:46+00',
                  least(getvariable('data_end') - TIMESTAMPTZ '2026-10-19 20:30:46+00', getvariable('max_window'))),
g AS (SELECT c.session_id AS cut_sid, c.cutover_ts, c.win, g.*,
             CASE WHEN g.ts >= c.cutover_ts THEN 'after' ELSE 'before' END AS side
      FROM c JOIN gh_calls g
        ON (g.session_id = c.session_id OR c.session_id LIKE '(ALL%')
       AND g.ts >= c.cutover_ts - c.win AND g.ts < c.cutover_ts + c.win)
SELECT c.session_id AS cut_sid, c.cutover_ts, c.win AS window_each,
       epoch(c.win) / 3600.0 AS window_h,
       s.side,
       count(g.ts) AS gh, count(g.ts) FILTER (g.polling) AS polling,
       count(g.ts) FILTER (g.sub = 'run' AND g.verb = 'watch') AS run_watch,
       count(g.ts) FILTER (g.sub = 'run' AND g.verb IN ('list', 'view')) AS run_list_view,
       count(g.ts) FILTER (g.sub = 'api') AS api,
       count(DISTINCT g.tool_use_id) FILTER (g.in_loop_cmd) AS poll_loop_cmds,
       count(g.ts) FILTER (g.is_subagent) AS gh_lanes, count(g.ts) FILTER (NOT g.is_subagent) AS gh_main,
       round(count(g.ts) / (epoch(c.win) / 3600.0), 1) AS gh_per_h,
       round(count(g.ts) FILTER (g.polling) / (epoch(c.win) / 3600.0), 1) AS polling_per_h
FROM c CROSS JOIN (VALUES ('before'), ('after')) s(side)
LEFT JOIN g ON g.cut_sid = c.session_id AND g.side = s.side
GROUP BY c.session_id, c.cutover_ts, c.win, s.side;
SELECT b.cut_sid[1:12] AS sid, coalesce(x.title, x.project) AS who, b.cutover_ts, round(b.window_h, 2) AS window_h,
       b.gh AS gh_before, a.gh AS gh_after, b.gh_per_h AS gh_h_before, a.gh_per_h AS gh_h_after,
       b.polling AS poll_before, a.polling AS poll_after, b.run_watch AS watch_before, a.run_watch AS watch_after,
       b.poll_loop_cmds AS loopcmd_before, a.poll_loop_cmds AS loopcmd_after,
       b.gh_lanes AS lanes_before, a.gh_lanes AS lanes_after
FROM ci_wait_before_after b JOIN ci_wait_before_after a ON a.cut_sid = b.cut_sid AND a.side = 'after'
LEFT JOIN ci_wait_cutover x ON x.session_id = b.cut_sid
WHERE b.side = 'before' ORDER BY b.gh + a.gh DESC;

-- A4. Cross-check against an external gh-call baseline: per-project gh counts over a window of your choice.
SELECT regexp_replace(t.project, '^-Users-[^-]+-Code-', '') AS proj,
       count(*) AS gh, count(*) FILTER (g.is_subagent) AS in_lanes, count(*) FILTER (g.polling) AS polling,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM gh_calls g JOIN (SELECT DISTINCT file, project FROM turns) t USING (file)
WHERE g.ts >= TIMESTAMPTZ '2026-10-19 19:38:00+00' AND g.ts < TIMESTAMPTZ '2026-10-19 20:38:00+00'
GROUP BY 1 ORDER BY gh DESC;

-- =====================================================================================
-- Wakes. A turn = from a record that starts model activity (human text, a task notification, a
-- peer/cross-session message, a hand-back, a scheduled prompt, compact resume, a subagent lane's prompt)
-- to the next one. is_wake = trigger not in (human, lane-start). spurious = a wake (never a peer message,
-- hand-back or coordinator message) that is zero_tool, relaunch_only or digest_able. Weight is
-- Opus-relative (input 1, output 5, cache write 5m 1.25 / 1h 2, cache read 0.1; x0.6 sonnet, x0.2 haiku,
-- x2 fable). Turns with has_calls = false (replayed or empty) are left out everywhere below.
-- =====================================================================================

-- (a) per session per hour: wakes, spurious share, cache_read per wake, weight/h
CREATE OR REPLACE TEMP VIEW wake_hourly AS
SELECT session_id, any_value(title) AS title, any_value(project) AS project, date_trunc('hour', start_ts) AS hour,
       count(*) FILTER (is_wake) AS wakes,
       count(*) FILTER (spurious) AS spurious,
       count(*) FILTER (is_wake AND zero_tool) AS zero_tool_wakes,
       count(*) FILTER (is_wake AND relaunch_only) AS relaunch_only_wakes,
       count(*) FILTER (is_wake AND digest_able) AS digest_able_wakes,
       round(count(*) FILTER (spurious) / nullif(count(*) FILTER (is_wake), 0), 3) AS spurious_share,
       round(avg(cache_read) FILTER (is_wake)) AS cache_read_per_wake,
       round(sum(weight)) AS weight_h,
       round(sum(weight) FILTER (is_wake)) AS wake_weight_h,
       round(sum(weight) FILTER (spurious)) AS spurious_weight_h
FROM turns WHERE has_calls GROUP BY session_id, hour;
SELECT hour, session_id[1:8] AS sid, coalesce(title, project) AS who, wakes, spurious, spurious_share,
       cache_read_per_wake, weight_h, spurious_weight_h
FROM wake_hourly WHERE hour >= getvariable('data_end') - INTERVAL 12 HOUR AND wakes > 0
ORDER BY hour DESC, weight_h DESC LIMIT 60;

-- (b) per session x trigger (last 7 days): n, median/p90 context at wake (first_call_cache_read), weight
SELECT session_id[1:8] AS sid, any_value(coalesce(title, project)) AS who, trigger, count(*) AS n,
       round(median(first_call_cache_read)) AS fc_cache_read_med, round(quantile_cont(first_call_cache_read, 0.9)) AS fc_cache_read_p90,
       round(sum(weight)) AS weight, round(avg(weight)) AS weight_per_turn,
       count(*) FILTER (spurious) AS spurious, count(*) FILTER (digest_able) AS digest_able
FROM turns WHERE has_calls AND start_ts >= getvariable('data_end') - INTERVAL 7 DAY
GROUP BY session_id, trigger HAVING count(*) >= 5 ORDER BY sum(weight) DESC LIMIT 60;

-- (c) BEFORE/AFTER template. `cutovers` (session_id, cutover_ts, change, source, note) is a persistent table
--     in wakes.duckdb; fill it with a read-write connection, e.g.
--       DELETE FROM cutovers WHERE change = 'ci-wait';
--       INSERT INTO cutovers SELECT *, NULL FROM ... ;   -- or simply:
--       INSERT INTO cutovers SELECT * FROM cutovers_for('ci-wait', '/ci-wait');
--       INSERT INTO cutovers SELECT * FROM cutovers_for('idle-watch-tiers', '<engine dir>/[^/ ]+/idle-watch');
--     cutovers_for(change, regex) takes rollout `cutover` rows (session resolved from the name) first, and for
--     every other session the first Bash/Monitor call matching the regex at/after the change's first `deployed`
--     row. watcher_cutovers(regex, change) = first watcher launch matching a script-path regex.
--     Read-only alternative used below: a TEMP table built from cutovers + cutovers_for(...).
CREATE OR REPLACE TEMP TABLE cuts AS
SELECT * FROM cutovers
UNION ALL SELECT * FROM cutovers_for('ci-wait', '/ci-wait') WHERE (SELECT count(*) FROM cutovers WHERE change = 'ci-wait') = 0
UNION ALL SELECT * FROM cutovers_for('idle-watch-tiers', '<engine dir>/[^/ ]+/idle-watch')
          WHERE (SELECT count(*) FROM cutovers WHERE change = 'idle-watch-tiers') = 0;
-- equal windows: L = least(cutover - session's first turn, data_end - cutover, max_window);
-- before = [cutover - L, cutover), after = [cutover, cutover + L). Context normalisation: a session's
-- context grows, so weight per wake is also shown per 100k tokens of context at the wake.
CREATE OR REPLACE TEMP VIEW wake_before_after AS
WITH s AS (SELECT session_id, min(start_ts) AS first_ts FROM turns GROUP BY 1),
c AS (SELECT k.change, k.session_id, k.cutover_ts,
             least(k.cutover_ts - s.first_ts, getvariable('data_end') - k.cutover_ts, getvariable('max_window')) AS win
      FROM cuts k JOIN s USING (session_id)),
w AS (SELECT c.change, c.session_id, c.cutover_ts, c.win, t.*,
             CASE WHEN t.start_ts >= c.cutover_ts THEN 'after' ELSE 'before' END AS side
      FROM c JOIN turns t ON t.session_id = c.session_id AND t.has_calls
       AND t.start_ts >= c.cutover_ts - c.win AND t.start_ts < c.cutover_ts + c.win)
SELECT change, session_id, any_value(title) AS title, cutover_ts, win, round(epoch(win) / 3600.0, 2) AS window_h, side,
       CASE WHEN is_subagent THEN 'lanes' ELSE 'main' END AS part,
       count(*) FILTER (is_wake) AS wakes, count(*) FILTER (spurious) AS spurious,
       count(*) FILTER (digest_able) AS digest_able, count(*) FILTER (digest_resolved) AS resolved_batchable,
       round(count(*) FILTER (is_wake) / (epoch(win) / 3600.0), 2) AS wakes_per_h,
       round(count(*) FILTER (spurious) / nullif(count(*) FILTER (is_wake), 0), 3) AS spurious_share,
       round(sum(weight) / (epoch(win) / 3600.0)) AS weight_per_h,
       round(avg(cache_read) FILTER (is_wake)) AS cache_read_per_wake,
       round(avg(first_call_context) FILTER (is_wake)) AS context_at_wake,
       round(avg(weight / greatest(first_call_context, 1) * 1e5) FILTER (is_wake), 1) AS weight_per_wake_per_100k_ctx
FROM w GROUP BY change, session_id, cutover_ts, win, side, part;
SET VARIABLE max_window = INTERVAL 24 HOUR;
SELECT change, session_id[1:8] AS sid, title, part, cutover_ts, window_h, side, wakes, wakes_per_h, spurious_share,
       digest_able, weight_per_h, cache_read_per_wake, weight_per_wake_per_100k_ctx
FROM wake_before_after ORDER BY change, sid, part, side DESC;

-- (d) top 20 most expensive spurious wakes (last 7 days)
SELECT start_ts, session_id[1:8] AS sid, coalesce(title, project) AS who, lane, trigger, content_class,
       n_tool_calls, round(weight) AS weight, first_call_cache_read, left(trigger_detail, 140) AS trigger_detail
FROM turns WHERE spurious AND start_ts >= getvariable('data_end') - INTERVAL 7 DAY
ORDER BY weight DESC LIMIT 20;

-- (e) self-generated wakes: a watcher wake whose content carries the session's OWN `<!-- agent:X` marker
--     (its own comment echoing back), or a peer message whose sender name is this session's own (names learned
--     in peer_names: from-name on another session's wake whose body starts with a SendMessage we sent).
SELECT 'own-marker' AS kind, w.session_id[1:8] AS sid, w.trigger, count(*) AS n, round(sum(w.weight)) AS weight,
       any_value(left(w.trigger_detail, 120)) AS example
FROM turns w JOIN session_markers m USING (session_id)
WHERE w.is_wake AND w.has_calls AND w.trigger IN ('bg-task', 'monitor-event', 'scheduled')
  AND strpos(coalesce(w.trigger_text, '') || coalesce(w.wake_output, ''), '<!-- ' || m.marker) > 0
GROUP BY ALL
UNION ALL
SELECT 'peer-from-self', w.session_id[1:8], w.trigger, count(*), round(sum(w.weight)), any_value(left(w.trigger_detail, 120))
FROM turns w JOIN peer_names p ON p.session_id = w.session_id AND p.peer_name = w.peer_name
WHERE w.is_wake AND w.has_calls GROUP BY ALL
ORDER BY weight DESC;

-- =====================================================================================
-- B. Rollout log (the JSONL named by WAKES_ROLLOUT_LOG; empty when unset). session_id = the main session resolved from `session`.
-- =====================================================================================
SELECT line, ts, change, version, event, session, session_id[1:8] AS sid, left(note, 100) AS note FROM rollout ORDER BY ts NULLS LAST;

-- =====================================================================================
-- C. Watcher launches. engine_version = pilot sha in the command, else (a wrapper such as an
--    idle.sh) the latest rollout `cutover` row for that session. First launch per session per engine:
-- =====================================================================================
SELECT session_id[1:8] AS sid, coalesce(engine_version, '(legacy)') AS engine, script_name, script_path,
       min(ts) AS first_launch, max(ts) AS last_launch, count(*) AS launches, sum(n_wakes_caused) AS wakes_caused
FROM watcher_events WHERE ts >= getvariable('data_end') - INTERVAL 2 DAY
GROUP BY ALL ORDER BY sid, first_launch;

-- =====================================================================================
-- D. digest_able: watcher wakes whose only content is [other] items, "loops registered again",
--    REAPPEARED self-checks, Terminated: 15 sleep, a watcher source exiting, or (sub-flag digest_resolved,
--    batched rather than digested) ✅ RESOLVED transitions. content_class gives the reason for the others:
--    items (something actionable), heartbeat, startup, empty, unread (output never read),
--    command-output (a non-watcher background command).
-- =====================================================================================
SELECT date_trunc('day', start_ts) AS day, session_id[1:8] AS sid, any_value(coalesce(title, project)) AS who,
       count(*) FILTER (trigger IN ('bg-task', 'monitor-event')) AS watcher_type_wakes,
       count(*) FILTER (digest_able AND NOT digest_resolved) AS digest, count(*) FILTER (digest_resolved) AS resolved_batch,
       round(sum(weight) FILTER (digest_able)) AS digest_able_weight,
       count(*) FILTER (content_class = 'items') AS items, count(*) FILTER (content_class = 'unread') AS unread
FROM turns WHERE has_calls AND start_ts >= getvariable('data_end') - INTERVAL 7 DAY
GROUP BY ALL HAVING count(*) FILTER (digest_able) > 0 ORDER BY day DESC, digest_able_weight DESC;

-- =====================================================================================
-- E. Lane (subagent file) context growth. context = input + cache_read + cache_write of a call.
--    turn_200k/400k = turn at which a call first crossed it; call_n_* = API call number;
--    turn_fc_* = first turn whose FIRST call's cache_read crossed it.
-- =====================================================================================
SELECT session_id[1:8] AS sid, agent_id, title, start_ts, n_turns, n_api_calls, round(weight) AS weight,
       first_turn_cache_read, median_turn_cache_read, max_turn_cache_read, max_context,
       call_n_200k, turn_200k, call_n_400k, turn_400k, turn_fc_200k, turn_fc_400k, triggers
FROM lanes WHERE start_ts >= getvariable('data_end') - INTERVAL 2 DAY ORDER BY max_context DESC LIMIT 40;
-- distribution: how many lanes ever pass 200k / 400k, and after how many calls
SELECT count(*) AS lanes, count(*) FILTER (call_n_200k IS NOT NULL) AS passed_200k, count(*) FILTER (call_n_400k IS NOT NULL) AS passed_400k,
       median(call_n_200k) AS med_calls_to_200k, median(call_n_400k) AS med_calls_to_400k,
       median(n_api_calls) AS med_calls_per_lane, quantile_cont(max_context, 0.9) AS p90_max_context,
       count(*) FILTER (n_turns > 1) AS lanes_rewoken
FROM lanes WHERE start_ts >= getvariable('data_end') - INTERVAL 7 DAY;
