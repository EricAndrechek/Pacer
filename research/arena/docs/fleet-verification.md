# Fleet mechanics: verification on this Mac

Run on 2026-10-24 with Claude Code 2.1.310, macOS 27, OrbStack. All tests used dummy data under `F=<fleet-test>`. Every behavioural test used Haiku. Raw outputs are in `F/q1` to `F/q8`, and the settings files are in `F/settings`. Total spend was about $0.75.

## 1. Nested launch

- **Command:** `claude -p "reply ok" --model haiku --max-turns 1` from this shell, with `CLAUDECODE=1` set.
- **Result:** it works (exit 0, about 6 s). `env -u CLAUDECODE` is not needed. The child gets its own session id, its own messaging socket (`/tmp/cc-socks/<pid>.sock`) and its own token. It does not write to the parent's `jobs/<id>/timeline.jsonl`.
- **What leaks into the child's Bash environment:** `CLAUDE_JOB_DIR` (the parent's job dir), `CLAUDE_CODE_AGENT`, and any secret in the parent environment. a secret token from the parent shell is present here.
- **What the child overwrites with its own values:** `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT` (set to `sdk-cli`), the messaging socket and token, `CLAUDE_PID` and `CLAUDE_EFFORT`. The parent's `CLAUDE_EFFORT=xhigh` had no effect on the child.
- **Clean environment:** `env -i HOME USER LOGNAME PATH SHELL TMPDIR LANG claude …` works, and the OAuth/keychain login still succeeds.
- **What the user settings bring:** if a child loads them, it inherits:
  - `defaultMode: auto`, `effortLevel`/`modelSettings` and `remoteControlAtStartup`;
  - the SessionStart hooks (iTerm cc-status and the Stripe plugin);
  - 11 MCP servers and 105 skills, which is 40k–205k context tokens per turn.
- **Conclusion:** launch with `env -i` and do not load user settings (see 6).

## 2. Version and effort pinning

- **Command:** `claude -p "reply ok" --model <id> --max-turns 1 --output-format stream-json --verbose --setting-sources project --strict-mcp-config --disable-slash-commands --tools ""`
- **Result:** all 7 ids were accepted. The bare 4.6 ids need no `[1m]` suffix.

| id | init `model` | assistant `message.model` | default effort without user settings |
|---|---|---|---|
| claude-haiku-4-5 | claude-haiku-4-5 | claude-haiku-4-5-20251001 | none: no effort support, and `--effort` is silently ignored |
| claude-sonnet-4-6 | same | same | high |
| claude-opus-4-6 | same | same | high |
| claude-opus-5 | same | same | high |
| claude-sonnet-5-5 | same | same | medium |
| claude-opus-5-5 | same | same | medium |
| claude-fable-5-1 | same | same | high |

- **The alias `haiku` resolves to `claude-haiku-5-5`**, not 4.5.
- **Effort values:** `--effort low|high|xhigh|max` were all honoured on haiku-5-5 and opus-5-5.
- **An invalid value** (`turbo`) only prints a warning on stderr and runs at the default effort, still with exit 0.
- **`CLAUDE_CODE_EFFORT_LEVEL=low` overrides `--effort high`** (confirmed).
- **Where effort shows up:** it is **not in the stream-json output**. It is in the transcript: each assistant entry has `"effort"` and `"perTurnEffort"`, and the request snapshot has `output_config.effort`.
- **With user settings loaded,** `modelSettings` silently changes the defaults (opus-5-5 runs at xhigh, fable at high). Always pass `--effort` explicitly.
- **The `--max-turns` flag** is not in `--help`, but it is enforced. The run ends with `subtype: error_max_turns` and exit 1.

## 3. Bash sandbox on macOS

**Setup.** `--settings` with:
- `sandbox.enabled`, `failIfUnavailable: true`, `allowUnsandboxedCommands: false`;
- `filesystem.denyRead: [F/hidden]`;
- `permissions.deny: ["Read(//F/hidden/**)", "Edit(//F/hidden/**)"]`.

The agent ran Haiku with cwd `F/agent-a` and `--permission-mode dontAsk`. In dontAsk mode Bash also needs `--allowedTools Bash`; the first run without it denied every command.

| Attempt | Result |
|---|---|
| (a) Read tool on the secret | **Blocked** by the permission deny: "File is in a directory that is denied by your permission settings" |
| (a') Read tool with `denyRead` only, no `Read()` deny, and a Read allow | **Allowed: the marker was read** (deliberate negative test `a4`). `denyRead` covers Bash only. |
| Read tool with no deny and no Read allow | Blocked: dontAsk denies reads outside the cwd |
| (b) `cat <literal path>` | **Blocked.** As part of a compound command, the permission layer denied the whole command, because it matches paths against the Read deny rule. On its own, the sandbox returned `Operation not permitted`. |
| `cat hid*/…`, `ls ../hid*`, (c) `python3 open()` with the path built from strings | **Blocked:** EPERM / `PermissionError: Operation not permitted` |
| Retry with `dangerouslyDisableSandbox: true` | Ignored, so still blocked |
| (d) `docker ps` | **Blocked:** "permission denied … unix://~/.orbstack/run/docker.sock" |
| (e) `curl https://pypi.org` with no domains set | **Blocked:** proxy 403, `deny network-outbound pypi.org:443` |
| `curl` with `network.allowedDomains: [pypi.org, files.pythonhosted.org, …]` | pypi returns 200; example.com returns 403 |
| Bash tool's own `allowed_domains: ["example.org"]` parameter (dontAsk, explicit list) | **Blocked (403):** an agent cannot grant itself a domain |
| `allowedDomains: ["*"]` | **Accepted, and it opens every domain** (example.com 200) while the filesystem sandbox stays on. The binary's schema text says `*` is rejected, so this may change between versions. |
| WebFetch tool | Not sandboxed; governed by permissions. It worked when allowed. |
| (f) Write outside the cwd | **Blocked** (EPERM) |
| Write **inside** the cwd, and uv | **Also blocked, but only because this cwd is under `~/.claude/jobs`.** See below. |
| `ls ~/.claude/projects` | Readable by default. Blocked once added to `denyRead`. |

**Why writes inside the cwd failed.** The sandbox has a fixed write-deny list that includes `~/.claude/jobs`, `~/.claude/projects`, every settings file, `<cwd>/.claude/settings*.json`, `.claude/hooks` and `.claude/skills`, and the `--settings` file itself. uv also fails because its cache (`~/.cache/uv`) is not writable from the sandbox.

**Not verified:** writing files and running `uv pip install` in a cwd outside `~/.claude`. The rule to keep every file under `F` prevented that test.

**Marker check.** The marker appears only in `q3/out-a4.jsonl` and in that run's transcript, which is the deliberate negative test. It appears nowhere else.

## 4. Helper escape hatch (`lab-eval`)

`F/bin/lab-eval` reads the secret and prints a hash. `excludedCommands` **matches the literal command string**:
- An absolute-path pattern exempts only the absolute invocation.
- A bare-name pattern exempts only the bare-name invocation.
- List both `X` and `"X *"`. In dontAsk mode the command also needs an allow rule, `Bash(X *)`.

With the absolute-path pattern:
- `X run2` returned the expected hash `214e20f50d6e93f0`, so it ran unsandboxed.
- These all ran **fully sandboxed**, with the helper itself getting EPERM, so nothing escaped:
  - `X; python3 <read>`
  - `X && echo`
  - `X "$(python3 <read>)"`
  - `X > outside-file`
  - `X < hid*/secret.txt`
  - `lab-eval(){ <read>; }; lab-eval`, with the name pattern

The binary says `excludedCommands` is honoured only from user, managed or `--settings` files, and ignored from project settings.

**Recommendations:**
- Use the absolute path, and keep the helper in a directory agents cannot write to.
- The helper must treat its arguments as untrusted.
- It must never relay the model's stdout or stderr, only scores.

## 5. Docker evaluator

- **Command:** `docker run --rm --network none --cpus 2 --memory 4g -v F/hidden:/data:ro -v F/q5/model:/model:ro python:3.12-slim python /model/run.py`
- **Mounts:** reading `/data` works. Writes to `/data` and `/model` fail with EROFS. `/tmp` is writable.
- **Network:** DNS fails, TCP fails with "Network is unreachable", and `host.docker.internal` does not resolve.
- **Limits:** cgroup `cpu.max` is `200000 100000` and `memory.max` is 4 GiB. `sched_getaffinity` still reports **14 CPUs**, so set `OMP_NUM_THREADS` and similar to the CPU cap.
- **Overhead:** 0.21–0.24 s per container for `python -c pass` with the image cached, and 1.0 s for the whole probe.
- **Hardened variant also works:** `--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --user 65534:65534 --pids-limit 256 --memory-swap 4g`.
- **Clean-up:** dangling volumes were 3 before and 3 after, and no containers were left behind.
- **Note:** an agent's macOS `.venv` cannot run inside the Linux container. Bake one evaluator image with the allowed package set.

## 6. Transcripts and context

**Transcript location:** `~/.claude/projects/<cwd with / and . replaced by ->/<session-id>.jsonl`, for example `-Users-<you>--claude-jobs-<job>-tmp-fleet-agent-a/…`. Passing `--session-id <uuid>` pins the file name (verified).

| Variant | Instruction files loaded |
|---|---|
| default | `~/.claude/CLAUDE.md`, `pacing.md` and the agent's own CLAUDE.md; hooks, MCP and skills; an auto-memory dir; about 205k context tokens and $0.21 for one Haiku turn |
| `--setting-sources project` + `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` + `--strict-mcp-config --disable-slash-commands` | The user CLAUDE.md drops out as a *User* file, but it **still loads as an ancestor "Project" file because this cwd is under `~/.claude`**; plus the own CLAUDE.md; about 5k tokens |
| the above + `--settings '{"claudeMdExcludes":["~/.claude/CLAUDE.md"]}'` | **Own CLAUDE.md only** (verified). A `~/.claude/**` glob also excluded the agent's own file. |
| `--safe-mode` | No CLAUDE.md at all, own included; the user's `auto` permission mode still applies |
| `--restricted` | No CLAUDE.md, own included; ignores user, project and local settings; only the tools named in `--tools`. The brief arrived via `--append-system-prompt-file` (canary verified). |
| `CLAUDE_CONFIG_DIR=<other dir>` | **"Not logged in · Please run /login"** (exit 1): this breaks auth |

**Advisor.** Haiku transcripts carry `advisorModel: claude-opus-5-5`, even under `--restricted`. Opus was never invoked in these tests (`modelUsage` showed Haiku only). For a fleet that compares models, set `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`; that removes the advisor (verified).

## 7. taskpolicy

`taskinfo` needs root, so I used `ps` PRI instead:

| Launch | PRI |
|---|---|
| default | 31 |
| `taskpolicy -c utility` | 20 |
| `taskpolicy -b` | 4 |

The value is inherited all the way down: `timeout`, then `claude`, then the sandboxed `zsh`, then `python3` (process chain verified). Children also inherit NI=10 from this coordinator's shell.

`-b` (background QoS) confines work to efficiency cores and throttles I/O. Docker work runs in the OrbStack VM, so taskpolicy on `docker run` does not reach it; cap containers with `--cpus` instead.

## Recommended recipe for one isolated agent

This is what `arena fleet launch` does; the code is the reference (`fleet/sandbox.py` for the settings, `fleet/launch.py` for the command line). It was run end to end in §8.

**Layout.** The fleet root is `$ARENA_FLEET_ROOT` (default `~/arena-fleet/`), outside `~/.claude` and outside the Pacer repo (paths in `fleet/paths.py`). Each agent works in `gen<N>/<name>/`, a fresh clone of the generation's template. It can write only that folder and its `TMPDIR` (`<name>/.tmp/`).

**Settings** (`settings/gen<N>/<name>.json`, absolute paths, abbreviated):

```json
{
  "sandbox": {
    "enabled": true, "failIfUnavailable": true,
    "allowUnsandboxedCommands": false, "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["/ROOT/bin/gen1/<name>/arena-eval", "/ROOT/bin/gen1/<name>/arena-eval *"],
    "filesystem": {
      "denyRead": ["$HOME", "<ARENA_HOME>", "/ROOT", "~/.claude", "~/.claude.json", "~/.config/claude",
        "<Pacer group containers>", "~/Library/Logs/Pacer", "~/Library/Application Support/Claude",
        "~/.cache/session-wakes", "~/.local/state/pacer-account-rotation", "~/Code", "<the Pacer repo>"],
      "allowRead": ["/ROOT/gen1/<name>", "<ARENA_HOME>/visible/<snapshot>",
        "~/.claude/shell-snapshots", "~/.local/share/uv/python"] },
    "network": { "allowedDomains": ["pypi.org", "files.pythonhosted.org", "github.com",
      "codeload.github.com", "*.githubusercontent.com", "huggingface.co", "*.huggingface.co", "*.hf.co"] }
  },
  "permissions": {
    "defaultMode": "dontAsk", "disableBypassPermissionsMode": "disable",
    "allow": ["Bash", "Bash(<wrapper>)", "Bash(<wrapper> *)", "Read(//ROOT/gen1/<name>/**)",
      "Edit(//ROOT/gen1/<name>/**)", "Edit(./**)", "WebFetch", "WebSearch"],
    "deny": ["Read(//<each sensitive path>)", "Read(//<each sensitive path>/**)", "Edit(…)",
      "Edit(//ROOT/gen1/<name>/arena/**)", "Edit(//ROOT/gen1/<name>/models/<each earlier model>/**)", "…"]
  },
  "env": { "UV_CACHE_DIR": "<agent>/.uv-cache", "UV_NO_CONFIG": "1", "UV_PYTHON": "<host python 3.12>",
    "HF_HOME": "<agent>/.hf-cache", "XDG_CACHE_HOME": "<agent>/.cache",
    "GIT_CONFIG_GLOBAL": "<agent>/.gitconfig", "GIT_CONFIG_NOSYSTEM": "1",
    "ARENA_HOME": "<agent>/.arena-home", "ARENA_SNAPSHOT": "<id>", "ARENA_EVAL": "<wrapper>" }
}
```

- **Deny the whole home directory, then re-allow** (the sandbox supports `allowRead` inside a `denyRead` region, and Claude Code's profile allows metadata reads on every directory, so paths resolve). A deny list of named places would miss the next secret; this one also covers every token file in `~`. The named places are listed anyway, so the deny survives if one moves out of `~`, and so the tests can check each one.
- **The visible tier is a view, not the raw `train/`** (`fleet/visible.py`): a copy of `train/` with late columns masked (a value whose known time is after T_train, per core's `LATE_COLUMNS`, which includes when the store recorded a backfilled turn), the current-only columns (`ALWAYS_NULL`, e.g. `accounts.plan_current`) nulled, labels cut at T_train, and a manifest without hidden-period counts. The agent's `ARENA_HOME` is its own `.arena-home/` (writable `cache/` and `results/`), with `snapshots/<id>` linking to the view.
- **One exempt command per agent.** `bin/gen<N>/<name>/arena-eval` is a two-line wrapper that execs the gate with the agent's identity baked in. Each agent's settings exempt only its own wrapper, so the identity cannot be forged. The gate runs the runner on the host and every model worker in its own data-less container (§9).
- **Read() rules need both forms:** `Read(//p)` for a file, `Read(//p/**)` for what is under a directory. A deny never names the home directory or the fleet root as a whole, which would lock the agent out of its own folder (a deny beats an allow).

**Launch** (`fleet/launch.py`, `agent_argv`):

```sh
cd /ROOT/gen1/<name> && /usr/bin/env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" \
  PATH="<claude dir>:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL=/bin/zsh TMPDIR=/ROOT/gen1/<name>/.tmp/ LANG=en_US.UTF-8 \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
  /usr/sbin/taskpolicy -c utility claude -p "<prompt>" \
  --model <id> --effort <e> --max-turns <n> --max-budget-usd <usd> \
  --restricted --tools "Bash,Read,Write,Edit,WebFetch,WebSearch" \
  --strict-mcp-config --disable-slash-commands \
  --settings /ROOT/settings/gen1/<name>.json --permission-mode dontAsk \
  --append-system-prompt-file /ROOT/gen1/<name>/BRIEF.md \
  --session-id <uuid> --output-format stream-json --verbose \
  < /dev/null > /ROOT/gen1/.runs/<name>/run.jsonl 2> /ROOT/gen1/.runs/<name>/run.err
```

## 8. Self-test from a real fleet root (closes §3's open checks)

Run on 2026-10-24 with `arena fleet selftest`: one Haiku 4.5 agent (`claude-haiku-4-5`, `--max-turns 6`), launched by the launcher's own code with the generated settings, in `~/arena-fleet/selftest/` (generation 0, dummy data, a second agent folder `other/` that was never launched). Claude Code reported 8 turns, $0.04, exit 0. The verdict is computed from evidence on disk (files the agent made, the budget file, Claude Code's own stream and transcript), never from what the agent said. Evidence: `~/arena-fleet/selftest-evidence-2026-10-24/`.

| Check | Result |
|---|---|
| Permission mode | **dontAsk works.** The init event shows `permissionMode: dontAsk` and only the six tools; the Write tool created a file in the agent's folder and the Edit tool changed it, with `Edit(//<agent>/**)` allowed. `acceptEdits` is not needed. |
| `uv venv` + `uv pip install six` | **Works** with a per-agent `UV_CACHE_DIR` (the cache filled inside the agent folder) and `UV_PYTHON` pinned to the host interpreter. |
| Writes in the folder and in `TMPDIR` (`<agent>/.tmp/`) from Bash | Work. |
| Visible tier through the agent's `ARENA_HOME` (two links deep) | Readable: train, the sanitized manifest, the cut labels. |
| Denied to Bash, each by a real refusal (`Operation not permitted`, not just a failure) | The holdout by path, by a Python-built path and by glob; the salt; the raw manifest; the other agent's folder (absolute and `../`); the budget file; the settings file; `fleet.json`; `~/.claude/projects`; `~/.claude/.credentials.json`; the Pacer repo; Pacer's store and logs; the session-wakes cache; `~/.gitconfig`; Docker; the gate called directly; the agent's own wrapper called from inside a script. |
| Network | pypi 200; example.com refused. |
| Read tool on the holdout | Refused by the permission rule. |
| `arena-eval` by absolute path | Ran outside the sandbox and returned scores (selftest backend); budget charged exactly once. Given `../other/models/…` it refused, uncharged. |
| Hidden marker | Absent from the stream, the transcript and every file in the agent's folder. |
| Advisor | Only Haiku in `modelUsage`. |
| **`git add` / `git commit` from Bash** | **Failed.** |

**The git failure.** The probe hid git's stderr, so the cause is not pinned down. What is known:
- Offline, under a hand-written Seatbelt profile with the same deny/allow lists, git commits when `GIT_CONFIG_GLOBAL=/dev/null` is in effect, and dies with `fatal: unable to access '~/.gitconfig': Operation not permitted` when it is not.
- The settings `env` did reach the sandboxed command (`UV_CACHE_DIR` took effect).
- In Claude Code's bundle, the built-in write protection inside a repository covers `.git/hooks`, `.git/config`(`.lock`), `config.worktree`, `commondir`, alternates and `worktrees/`, not the index, objects or refs. And its own `blockReadsOutsideWorkingDirectories` mode re-opens git's global config files (`~/.gitconfig`, `~/.config/git/{config,ignore,attributes}`): git needs them readable, or an alternative.

So the likeliest causes are that `/dev/null` is not readable as a config file inside the profile, or that `GIT_CONFIG_GLOBAL` does not reach git. Changes made, **not yet verified by a run**:
1. `GIT_CONFIG_GLOBAL` now points to a regular file in the agent's folder, `<agent>/.gitconfig` (identity, no signing). Claude Code write-protects `<cwd>/.gitconfig`, so the agent cannot change it.
2. `AgentSandbox(allow_git_global_config=True)` re-opens the owner's `~/.gitconfig` and `~/.config/git` instead, as Claude Code's own mode does. It is off by default because the file names the owner.
3. **Nothing is lost either way:** when an agent's run ends, the launcher commits whatever it left uncommitted in `models/`, `REPORT.md` and `UPSTREAM.md`, as the agent, with hardened git (no global or system config, no hooks, no fsmonitor, and not at all if `.git/config` changed since launch).

**Check at the start of generation 1:** a few minutes after the first agent starts, its repo should show a commit of its own (`git -C <agent> log`, or `arena fleet status`). If not, switch on option 2 for the rest of the generation.

## 9. Scoring: the runner on the host, each worker in its own container

The first design ran the whole `arena eval` in one container with the snapshot
mounted read-only. The runner never *handed* a worker a future row, but a
model's own process could open the mounted holdout and look the answers up.
That gap is closed by construction (merge of phase 1):

- **The runner runs on the host**, inside `arena-eval` (already outside the
  agent's sandbox), from the generation's template (the pinned harness, which
  no agent can write) with an interpreter the coordinator builds at launch
  (`fleet/install.py` `build_runner_env`: a venv under `state/gen<N>/` holding
  the template's locked dependencies). It is the only process that reads the
  snapshot, and it writes nothing (`--no-cache`, no `--record`).
- **Every worker, children included, is its own container**, started by the
  runner through `ARENA_WORKER_CMD` (core's worker command,
  `fleet/evalgate.py` `worker_command`):
  `docker run -i --rm --pull never --network none --cpus 2 --memory 4g --memory-swap 4g --pids-limit 512 --read-only --tmpfs /tmp:rw,size=1g,mode=1777 --cap-drop ALL --security-opt no-new-privileges --user 65534:65534 --log-driver none`,
  with the staged models (at their resolved host path, so the runner's
  `model_dir` resolves inside) and the model's env mounted read-only, and
  **no data mounted at all**. Rows reach the model only as the runner's as-of
  batches over stdin. Thread variables are pinned to 2 (the container still
  sees 14 CPUs). `ARENA_WORKER_KILL_CMD` (`docker kill {id}`) finishes a
  worker the runner kills (timeouts), and the gate kills any container left
  under the call's name prefix.
- **The image** no longer sets `ARENA_HOME` or creates `/arena-home`.
- **Docker is reached through an endpoint pinned at install** (`docker_host`
  in `bin/arena-eval.json`), an empty `DOCKER_CONFIG` and a fixed `PATH`,
  never through the caller's environment: the runner streams hidden-tier rows
  to `docker run -i`, and a daemon the agent pointed `DOCKER_HOST` at would
  receive them.

**Verified** (`tests/fleet/test_docker_worker.py`, run on this Mac with
OrbStack): a probe model inside a Docker worker found no `ARENA_*` variable
beyond the worker's own, could not open `ARENA_HOME`, the snapshot or its
holdout by their host paths (handed to it in its config) or `/arena-home`,
found no snapshot-shaped file anywhere on the container's filesystem, ran as
uid 65534, and reached no host on the network (1.1.1.1, 8.8.8.8,
`host.docker.internal`, pypi.org). The same probe as a host subprocess worker
read the snapshot, so the empty report means there was nothing to find.

**End to end** through the real gate (a throwaway fleet root, `example-linear`,
20 leaderboard episodes of 24 checkpoints): no failures; 3.3 s per episode on
the synthetic snapshot and 3.8 s on the real one, against 2.1-2.2 s with host
subprocess workers, so a container per worker costs about 1-1.5 s per
episode. The host runner peaked at 2.6-2.9 GB. No container was left behind
and dangling volumes stayed at 1.

- `arena build` made a venv with `--system-site-packages` in the image, with
  the network on and no data mounted; a worker imports both the harness and
  the extra package from it (`/env/bin/python -m arena.worker`).
- **Docker file sharing:** OrbStack shares `/Users` and `/tmp` but not
  `/private/var/folders` or `/private/tmp`, so a mount source must be the
  path as given (the fleet root lives under `$HOME`); the mount target is the
  resolved path.

## 10. Reviewer dry-run

`fleet/review.py` on `models/example-linear`: Sonnet 5.5 (`claude-sonnet-5-5`, Read tool only, `--restricted`, a folder holding only the submission). Verdict `pass`, no findings, 5 turns, $0.03. The static scan found nothing in the example.

## 11. Generation-1 findings and the gen-2 fixes

What the first live fleet showed, and what the launcher now does about it.

- **Git does not work inside the sandbox.** `git add` / `git commit` fail with
  "Unable to create .git/index.lock: Operation not permitted": the sandbox
  denies writes under the agent's `.git/`. It is not the `GIT_CONFIG_GLOBAL`
  theory of §8 (the identity file is fine). The mechanism that saved the work
  is the launcher's end-of-run hand-back commit (`handback_commit`: it commits
  `models/`, `REPORT.md` and `UPSTREAM.md` as the agent, outside the sandbox).
  So AGENTS.md and the brief now say "don't run git; keep those files current",
  and the launch prompt no longer says "committing as you go". (The self-test's
  `git_commit` probe still tries a commit; expect it to fail for this reason.)
- **Bash time limit.** Claude Code's default is 2 minutes, at most 10; 30-episode
  `arena test` runs hit it. Every agent's settings `env` now carries
  `BASH_DEFAULT_TIMEOUT_MS=1800000` and `BASH_MAX_TIMEOUT_MS=3600000`.
- **Pretrained-model packages.** The per-agent presync is `uv sync --frozen
  --extra fm`, so torch, Timestral and the other foundation-model packages are
  in the agent's `.venv` (gen-1 agents had no torch).
- **Pretrained weights offline.** At prepare time the coordinator's
  `~/.cache/huggingface/hub` (from the account's real home) is cloned into
  `<agent>/.hf-cache/hub` with `cp -c -R` (APFS clone, no extra disk), falling
  back to a normal copy with a warning. The agent's `HF_HOME` points at
  `<agent>/.hf-cache`; the real cache is denied by the sandbox.
- **Status accounting.** `result.num_turns` under-reported (3 turns for a $13.90
  agent, 1 for a budget-capped one). `read_stream` now counts assistant turns
  (distinct message ids) from the stream and reports the larger of that and the
  result field, keeping the count as `assistant_turns`. A run that ends with
  `error_max_turns` or `error_max_budget_usd` has status `capped (turns)` or
  `capped (budget)` instead of `failed`; capped agents are not re-run on resume.
- **Attribution caveat.** Some gen-1 agents ran before these fixes; their
  results were produced with a weaker setup.
