"""`arena fleet launch --gen N --plan plan.toml`: prepare and run a generation.

For each agent: a fresh clone of the template, its arena home, its brief, its
settings (checked before use), its `arena-eval` wrapper and budget; then a
headless `claude -p` started with the recipe verified in
docs/fleet-verification.md. At most `max_parallel` run at once; the rest
queue. Each wave of starts is gated on Pacer, and a pause waits for the
window to reset. `fleet.json` records attribution as the launcher knows it:
the agent's own output is never a source for it.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import re
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from fleet import install, template as tmpl
from fleet.image import build_image, image_tag
from fleet.paths import FleetPaths
from fleet.plan import AgentSpec, Plan
from fleet.sandbox import AgentSandbox, check_settings, sensitive_paths
from fleet.visible import link_agent_home, publish_visible_view

TOOLS = "Bash,Read,Write,Edit,WebFetch,WebSearch"
PERMISSION_MODE = "dontAsk"   # confirmed by the self-test (docs/fleet-verification.md §8)
PROMPT = ("Read AGENTS.md and BRIEF.md in your working folder, then carry out the task in "
          "BRIEF.md. Work until your model is as good as you can make it, keeping models/, "
          "REPORT.md and UPSTREAM.md current as you go.")
# Pacer's pacing CLI (the `pacer` skill), if installed: gates each wave on the
# usage windows. Optional: without it every wave proceeds. $ARENA_PACER overrides.
PACER = Path(os.environ.get("ARENA_PACER") or Path.home() / ".claude" / "skills" / "pacer" / "pacer")
BRIEF_TEXT = Path(__file__).parent / "templates" / "BRIEF.md"
SANE_PATH = ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def repo_roots(src: Path = tmpl.ARENA_SRC) -> tuple[Path, ...]:
    """The Pacer checkout this code runs from, and its main worktree."""
    out = []
    r = tmpl.git("rev-parse", "--show-toplevel", "--git-common-dir", cwd=src, check=False)
    if r.returncode == 0:
        top, common = r.stdout.strip().splitlines()[:2]
        out.append(Path(top))
        common_path = (Path(top) / common).resolve() if not os.path.isabs(common) else Path(common)
        out.append(common_path.parent)
    return tuple(dict.fromkeys(out))


def presync_cmd(uv_python: str | None) -> list[str]:
    """The per-agent `uv sync`. `--extra fm` puts torch, Timestral and the other
    pretrained time-series packages in the agent's .venv: gen 1's first agents
    had no torch, so every model built on them failed in the sandbox."""
    return ["uv", "sync", "--frozen", "--quiet", "--extra", "fm"] + (["--python", uv_python] if uv_python else [])


def real_home() -> Path:
    """The account's home from the user database, not $HOME (which a caller may have changed)."""
    import pwd
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except KeyError:
        return Path.home()


def hf_hub_source() -> Path:
    return real_home() / ".cache" / "huggingface" / "hub"


def clone_hf_cache(agent_dir: Path, src: Path | None = None, log=print) -> str | None:
    """Give the agent the coordinator's Hugging Face weights, offline.

    The sandbox denies the real cache, so an agent's pretrained models could
    not load their weights (gen 1). `cp -c` is an APFS clone: no extra disk.
    A normal copy is the fallback where cloning is unsupported, with a warning.
    Returns "clone", "copy", or None when there is no source cache."""
    src = src if src is not None else hf_hub_source()
    if not src.is_dir():
        log(f"  warning: no Hugging Face cache at {src}; pretrained weights will not be available offline")
        return None
    dest = agent_dir / ".hf-cache" / "hub"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    r = subprocess.run(["cp", "-c", "-R", str(src), str(dest)], capture_output=True, text=True)
    if r.returncode == 0:
        return "clone"
    shutil.rmtree(dest, ignore_errors=True)
    log(f"  warning: APFS clone of {src} failed ({r.stderr.strip()[:120]}); doing a full copy")
    shutil.copytree(src, dest, symlinks=True)
    return "copy"


def find_uv_python(version: str = "3.12") -> str | None:
    r = subprocess.run(["uv", "python", "find", version], capture_output=True, text=True)
    p = r.stdout.strip()
    return p if r.returncode == 0 and p and ".venv" not in p else None


# --------------------------------------------------------------------------
# fleet.json


@dataclass
class FleetState:
    path: Path
    data: dict = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> "FleetState":
        return cls(path, json.loads(path.read_text()) if path.exists() else {})

    def save(self) -> None:
        self.data["updated_at"] = now_iso()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.data, indent=2, sort_keys=False) + "\n")
        os.replace(tmp, self.path)

    def agent(self, name: str) -> dict:
        return self.data.setdefault("agents", {}).setdefault(name, {})


SPEC_FIELDS = ("niche", "model", "effort", "max_turns", "budget_usd", "eval_budget")


def check_resume(state: FleetState, plan: Plan) -> None:
    for a in plan.agents:
        rec = state.data.get("agents", {}).get(a.name)
        if not rec:
            continue
        for f in SPEC_FIELDS:
            if f in rec and rec[f] != getattr(a, f):
                raise ValueError(f"agent {a.name}: plan says {f}={getattr(a, f)!r} but it already ran "
                                 f"with {rec[f]!r}; use a new name or a new generation")


# --------------------------------------------------------------------------
# preparing one agent


@dataclass
class Prepared:
    spec: AgentSpec
    dir: Path
    settings: Path
    brief: Path
    wrapper: Path
    session_id: str
    argv: list[str]
    env: dict[str, str]
    run_log: Path
    err_log: Path


def brief_text(spec: AgentSpec, gen: int, agent_dir: Path, wrapper: Path) -> str:
    task = spec.task.strip() or ""
    return tmpl._fill(BRIEF_TEXT.read_text(), {
        "NAME": spec.name, "GEN": str(gen), "NICHE": spec.niche, "TASK": task,
        "AGENT_DIR": str(agent_dir), "EVAL": str(wrapper), "BUDGET": str(spec.eval_budget),
    })


def launch_env(paths: FleetPaths, agent_dir: Path, claude: str) -> dict[str, str]:
    """`env -i` plus the basics (docs/fleet-verification.md §1): no job
    folder, no secrets, no parent session id reach the agent."""
    path = [str(Path(claude).parent)] + [p for p in SANE_PATH if p != str(Path(claude).parent)]
    return {
        "HOME": str(Path.home()),
        "USER": os.environ.get("USER", Path.home().name),
        "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", Path.home().name)),
        "PATH": ":".join(path),
        "SHELL": "/bin/zsh",
        "TMPDIR": str(agent_dir / ".tmp") + "/",
        "LANG": "en_US.UTF-8",
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
        "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": "1",
    }


def low_priority() -> list[str]:
    """Run the agent (and everything it starts) below the owner's work:
    macOS's utility QoS, inherited by every child process (verified,
    docs/fleet-verification.md §7); `nice` where taskpolicy doesn't exist."""
    if Path("/usr/sbin/taskpolicy").exists():
        return ["/usr/sbin/taskpolicy", "-c", "utility"]
    nice = shutil.which("nice")
    return [nice, "-n", "10"] if nice else []


def agent_argv(spec: AgentSpec, *, claude: str, settings: Path, brief: Path, session_id: str,
               prompt: str = PROMPT, env: dict[str, str]) -> list[str]:
    return [
        "/usr/bin/env", "-i", *[f"{k}={v}" for k, v in env.items()],
        *low_priority(),
        claude, "-p", prompt,
        "--model", spec.model, "--effort", spec.effort,
        "--max-turns", str(spec.max_turns), "--max-budget-usd", f"{spec.budget_usd:g}",
        "--restricted", "--tools", TOOLS,
        "--strict-mcp-config", "--disable-slash-commands",
        "--settings", str(settings), "--permission-mode", PERMISSION_MODE,
        "--append-system-prompt-file", str(brief),
        "--session-id", session_id,
        "--output-format", "stream-json", "--verbose",
    ]


def agent_gitconfig(gen: int, name: str) -> str:
    """The agent's stand-in for ~/.gitconfig ($GIT_CONFIG_GLOBAL)."""
    return (f"[user]\n\tname = arena-gen{gen}-{name}\n\temail = {name}.gen{gen}@arena.invalid\n"
            "[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[core]\n\tfsmonitor = false\n"
            "[init]\n\tdefaultBranch = main\n")


HANDBACK_PATHS = ("models", "REPORT.md", "UPSTREAM.md")


def handback_commit(paths: FleetPaths, gen: int, name: str, rec: dict) -> str | None:
    """Commit what an agent left uncommitted in models/, REPORT.md and
    UPSTREAM.md, as the agent, once its run has ended. A safety net for an
    agent that could not (or did not) commit: nothing it wrote is lost.

    Runs git outside the sandbox in a folder the agent controlled, so: no
    global or system config, no hooks, no fsmonitor, and not at all if the
    repo's config changed since launch (the sandbox forbids that write)."""
    from fleet.collect import tamper_checks
    d = paths.agent_dir(gen, name)
    if not (d / ".git").is_dir() or tamper_checks(d, rec):
        return None
    present = [p for p in HANDBACK_PATHS if (d / p).exists()]
    if not present:
        return None
    tmpl.git("add", "-A", "--", *present, cwd=d, check=False)
    if tmpl.git("diff", "--cached", "--quiet", cwd=d, check=False).returncode == 0:
        return None
    who = {"GIT_AUTHOR_NAME": f"arena-gen{gen}-{name}", "GIT_AUTHOR_EMAIL": f"{name}.gen{gen}@arena.invalid"}
    r = tmpl.git("commit", "-q", "--no-verify", "-m",
                 "hand-back: work left uncommitted when the run ended\n\nCommitted by the fleet launcher.",
                 cwd=d, check=False, env=who)
    if r.returncode != 0:
        return None
    return tmpl.git("rev-parse", "HEAD", cwd=d).stdout.strip()


def _write_ro(path: Path, text: str) -> None:
    if path.exists():
        path.chmod(0o644)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o444)


def prepare_agent(paths: FleetPaths, gen: int, spec: AgentSpec, *, plan: Plan, snapshot: str,
                  template: Path, earlier_models: list[str], claude: str, uv_python: str | None,
                  presync: bool, roots: tuple[Path, ...], session_id: str | None = None,
                  prompt: str = PROMPT, extra_allow_read: tuple[Path, ...] = (),
                  brief_override: str | None = None, log=print) -> Prepared:
    d = paths.agent_dir(gen, spec.name)
    if not d.exists():
        d.parent.mkdir(parents=True, exist_ok=True)
        tmpl.git("clone", "-q", "--no-hardlinks", str(template), str(d), cwd=d.parent)
        for k, v in (("user.name", f"arena-gen{gen}-{spec.name}"),
                     ("user.email", f"{spec.name}.gen{gen}@arena.invalid"),
                     ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
                     ("core.fsmonitor", "false")):
            tmpl.git("config", k, v, cwd=d)
        with (d / ".git" / "info" / "exclude").open("a") as fh:
            fh.write("BRIEF.md\n.tmp/\n.arena-home/\n.gitconfig\n")
        (d / ".gitconfig").write_text(agent_gitconfig(gen, spec.name))
        if presync:
            log(f"  {spec.name}: uv sync (pre-building .venv)")
            env = {**os.environ, "UV_CACHE_DIR": str(paths.uv_cache), "UV_LINK_MODE": "clone",
                   "UV_NO_CONFIG": "1"}
            env.pop("VIRTUAL_ENV", None)
            subprocess.run(presync_cmd(uv_python), cwd=d, env=env, check=True)
        clone_hf_cache(d, log=log)
        tmpl.protect_clone(d, earlier_models)
    (d / ".tmp").mkdir(exist_ok=True)
    link_agent_home(d, paths.visible_view(snapshot), snapshot)

    wrapper = install.write_wrapper(paths, gen, spec.name)
    install.init_budget(paths, gen, spec.name, spec.eval_budget)
    brief = d / "BRIEF.md"
    _write_ro(brief, brief_override or brief_text(spec, gen, d, wrapper))

    sid = session_id or str(uuid.uuid4())
    # Claude Code saves a large tool output under the session's own project
    # folder and tells the agent to read it there; ~/.claude/projects is denied
    # (every other transcript), so re-open exactly this session's tool-results
    # (gen 1: agents' `cat` of their own saved output was refused).
    own_results = Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(d)) / sid / "tool-results"
    sb = AgentSandbox(paths=paths, gen=gen, name=spec.name, snapshot_id=snapshot,
                      other_agents=tuple(a.name for a in plan.agents), earlier_models=tuple(earlier_models),
                      repo_roots=roots, uv_python=uv_python,
                      extra_allow_read=tuple(extra_allow_read) + (own_results,))
    settings = sb.settings()
    must_deny = [s.path for s in sensitive_paths(paths, repo_roots=roots)] + [
        paths.home / "snapshots" / snapshot / "holdout", paths.home / "snapshots" / snapshot / "labels",
        paths.home / "snapshots" / snapshot / "manifest.json", paths.home / "salt",
        paths.train_dir(snapshot),   # raw: late columns hold values from after T_train
        *[paths.agent_dir(gen, o.name) for o in plan.agents if o.name != spec.name],
    ]
    problems = check_settings(settings, agent_dir=d, wrapper=wrapper, train=paths.visible_view(snapshot),
                              must_deny=must_deny)
    if problems:
        raise RuntimeError(f"agent {spec.name}: unsafe settings:\n  " + "\n  ".join(problems))
    settings_path = paths.settings_file(gen, spec.name)
    _write_ro(settings_path, json.dumps(settings, indent=2) + "\n")

    env = launch_env(paths, d, claude)
    argv = agent_argv(spec, claude=claude, settings=settings_path, brief=brief, session_id=sid,
                      prompt=prompt, env=env)
    run = paths.run_dir(gen, spec.name)
    run.mkdir(parents=True, exist_ok=True)
    return Prepared(spec, d, settings_path, brief, wrapper, sid, argv, env,
                    run / "run.jsonl", run / "run.err")


# --------------------------------------------------------------------------
# pacing


def pace(family: str, gen: int, *, pacer: Path = PACER, wait: bool, log=print) -> str:
    """'go', 'paused' or 'stop'. No Pacer (2), misconfigured (4) or an unknown
    verdict proceed: no signal is not no budget."""
    if not pacer.exists():
        return "go"
    env = {**os.environ, "PACE_RUN": f"arena-fleet-gen{gen}"}
    r = subprocess.run([str(pacer), "gate", "--model", family], capture_output=True, text=True, env=env)
    log(f"  pacer gate --model {family}: exit {r.returncode} {r.stdout.strip()[:120]}")
    if r.returncode != 10:
        return "go"
    if not wait:
        return "paused"
    log(f"  paused on {family}; waiting for the window to reset")
    w = subprocess.run([str(pacer), "wait", "--model", family], text=True, env=env)
    if w.returncode == 20:
        return "stop"
    return "go"


# --------------------------------------------------------------------------
# running


def read_stream(run_log: Path) -> dict:
    """What Claude Code itself reported: the init event (model, tools,
    permission mode, session id) and the final result (turns, cost).

    `result.num_turns` is not trusted: gen 1 showed turns=3 for an agent that
    spent $13.90 and turns=1 for one stopped by its budget cap. The assistant
    turns are counted from the stream itself (one per distinct message id; an
    event without an id counts as one) and `num_turns` is the larger of the two.
    A run stopped by --max-turns or --max-budget-usd gets `capped_by`."""
    out: dict = {}
    if not run_log.exists():
        return out
    seen_ids: set[str] = set()
    anon = 0
    with run_log.open() as fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            if ev.get("type") == "system" and ev.get("subtype") == "init" and "init" not in out:
                out["init"] = {k: ev.get(k) for k in ("model", "session_id", "permissionMode", "tools",
                                                     "claude_code_version", "cwd")}
            elif ev.get("type") == "assistant":
                msg = ev.get("message")
                mid = msg.get("id") if isinstance(msg, dict) else None
                if mid:
                    seen_ids.add(str(mid))
                else:
                    anon += 1
            elif ev.get("type") == "result":
                out["result"] = {k: ev.get(k) for k in ("subtype", "is_error", "num_turns",
                                                       "total_cost_usd", "duration_ms")}
                if isinstance(ev.get("modelUsage"), dict):
                    out["result"]["models_used"] = sorted(ev["modelUsage"])
    counted = len(seen_ids) + anon
    if counted or "result" in out:
        res = out.setdefault("result", {})
        reported = res.get("num_turns")
        res["assistant_turns"] = counted
        res["num_turns"] = max(counted, reported) if isinstance(reported, int) else counted
        cap = capped_by(res.get("subtype"))
        if cap:
            res["capped_by"] = cap
    return out


def capped_by(subtype: str | None) -> str | None:
    """'turns' or 'budget' when Claude Code stopped the run at one of its caps."""
    st = (subtype or "").lower()
    if "max_turns" in st:
        return "turns"
    if "budget" in st:
        return "budget"
    return None


def final_status(rc: int, stream: dict) -> str:
    """finished, capped (stopped by --max-turns or --max-budget-usd: not a failure), or failed."""
    cap = (stream.get("result") or {}).get("capped_by")
    if cap:
        return f"capped ({cap})"
    return "finished" if rc == 0 else "failed"


def start(p: Prepared) -> subprocess.Popen:
    out = p.run_log.open("ab")
    err = p.err_log.open("ab")
    try:
        return subprocess.Popen(p.argv, cwd=p.dir, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                start_new_session=True)
    finally:
        out.close()
        err.close()


def _alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def launch(paths: FleetPaths, gen: int, plan: Plan, *, claude: str | None = None, pacer: Path = PACER,
           presync: bool = True, dry_run: bool = False, build: bool = True, backend: str = "docker",
           poll_s: float = 10.0, prompt: str = PROMPT, extra_allow_read: tuple[Path, ...] = (),
           log=print) -> int:
    claude = claude or shutil.which("claude")
    if not claude:
        raise RuntimeError("claude not found on PATH")
    template = paths.template(gen)
    if not (template / "TEMPLATE.json").is_file():
        raise FileNotFoundError(f"no template at {template}; run `arena template gen{gen}` first")
    info = tmpl.template_info(template)
    snapshot = plan.snapshot or info["snapshot"]
    earlier = [m for m in info["models"]]
    for w in plan.warnings:
        log(f"warning: {w}")

    publish_visible_view(paths, snapshot)
    image = runner_python = None
    if backend == "docker":
        image = build_image(template) if build else image_tag(template)
        runner_python = install.build_runner_env(paths, gen, template)
    install.install_gate(paths, backend=backend)
    install.write_gen_eval_config(paths, gen, snapshot=snapshot, image=image, episodes=plan.eval_episodes,
                                  harness=template, runner_python=runner_python)

    state = FleetState.load(paths.fleet_json(gen))
    check_resume(state, plan)
    version = subprocess.run([claude, "--version"], capture_output=True, text=True).stdout.strip()
    state.data.update({"generation": gen, "template": str(template), "template_commit": info["commit"],
                       "snapshot": snapshot, "image": image, "harness_hash": info.get("harness_hash"),
                       "claude_version": version, "permission_mode": PERMISSION_MODE})
    state.data.setdefault("created_at", now_iso())
    state.data.setdefault("plans", [])
    if plan.sha256 not in [p.get("sha256") for p in state.data["plans"]]:
        state.data["plans"].append({"sha256": plan.sha256, "at": now_iso()})
    paths.gen_dir(gen).mkdir(parents=True, exist_ok=True)
    (paths.gen_dir(gen) / f"plan-{plan.sha256[:12]}.json").write_text(_plan_text_or_empty(plan))

    roots = repo_roots()
    uv_python = find_uv_python()
    queue: list[Prepared] = []
    for spec in plan.agents:
        rec = state.agent(spec.name)
        if rec.get("status") in ("finished", "failed") or str(rec.get("status", "")).startswith("capped"):
            log(f"  {spec.name}: already {rec['status']}, skipped")
            continue
        if rec.get("status") == "running":
            if _alive(rec.get("pid")):
                log(f"  {spec.name}: still running (pid {rec['pid']}), skipped")
                continue
            rec["status"] = "lost"
            log(f"  {spec.name}: was running, process gone: marked lost, skipped")
            continue
        if rec.get("status") == "lost":
            continue
        p = prepare_agent(paths, gen, spec, plan=plan, snapshot=snapshot, template=template,
                          earlier_models=earlier, claude=claude, uv_python=uv_python, presync=presync,
                          roots=roots, session_id=rec.get("session_id"), prompt=prompt,
                          extra_allow_read=extra_allow_read, log=log)
        rec.update({
            "name": spec.name, "generation": gen, "niche": spec.niche, "model": spec.model,
            "effort": spec.effort, "max_turns": spec.max_turns, "budget_usd": spec.budget_usd,
            "eval_budget": spec.eval_budget, "session_id": p.session_id, "cwd": str(p.dir),
            "settings": str(p.settings), "settings_sha256": tmpl.sha256_file(p.settings),
            "brief_sha256": tmpl.sha256_file(p.brief), "wrapper": str(p.wrapper),
            "git_config_sha256": tmpl.sha256_file(p.dir / ".git" / "config"),
            "run_log": str(p.run_log), "stderr_log": str(p.err_log), "status": "prepared",
            "argv": p.argv[p.argv.index(claude):],
        })
        queue.append(p)
    state.save()

    if dry_run:
        for p in queue:
            log(f"  {p.spec.name}: would run in {p.dir}:\n    " + " ".join(p.argv[p.argv.index(claude):]))
        return 0

    running: dict[str, tuple[Prepared, subprocess.Popen]] = {}
    while queue or running:
        for name, (p, proc) in list(running.items()):
            rc = proc.poll()
            if rc is None:
                continue
            rec = state.agent(name)
            stream = read_stream(p.run_log)
            rec.update({"end": now_iso(), "exit_code": rc, "status": final_status(rc, stream), **stream})
            rec["handback_commit"] = handback_commit(paths, gen, name, rec)
            state.save()
            log(f"  {name}: exited {rc}")
            del running[name]
        free = plan.max_parallel - len(running)
        if queue and free > 0:
            wave = queue[:free]
            verdicts: dict[str, str] = {}
            for fam in dict.fromkeys(p.spec.family for p in wave):
                verdicts[fam] = pace(fam, gen, pacer=pacer, wait=not running, log=log)
                state.data.setdefault("gates", []).append({"at": now_iso(), "family": fam, "verdict": verdicts[fam]})
            if "stop" in verdicts.values():
                state.save()
                log("pacer: the window will not reset soon; stopping here. Re-run the same command to resume.")
                return 20
            started = False
            for p in wave:
                if verdicts[p.spec.family] != "go":
                    continue
                proc = start(p)
                queue.remove(p)
                running[p.spec.name] = (p, proc)
                state.agent(p.spec.name).update({"status": "running", "pid": proc.pid, "start": now_iso()})
                state.save()
                log(f"  {p.spec.name}: started ({p.spec.model}, effort {p.spec.effort}, session {p.session_id})")
                started = True
            if not started and running:
                # Paused while others run: look again when one of them ends.
                _wait_for_change(running, poll_s)
                continue
        time.sleep(poll_s if running else 0)
    return 0


def _wait_for_change(running: dict, poll_s: float) -> None:
    while all(proc.poll() is None for _, proc in running.values()):
        time.sleep(poll_s)


def _plan_text_or_empty(plan: Plan) -> str:
    return json.dumps({"sha256": plan.sha256, "max_parallel": plan.max_parallel,
                       "eval_episodes": plan.eval_episodes, "snapshot": plan.snapshot,
                       "agents": [asdict(a) for a in plan.agents]}, indent=2) + "\n"


if __name__ == "__main__":  # pragma: no cover
    sys.exit("use `arena fleet launch`")
