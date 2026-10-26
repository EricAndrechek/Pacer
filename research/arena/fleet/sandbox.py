"""The `--settings` file each agent runs under.

Two layers, because each covers what the other does not
(docs/fleet-verification.md §3):

- **The Bash sandbox** (`sandbox.filesystem.denyRead` / `allowRead`) covers
  every process an agent's shell starts: `cat`, Python, uv, git. It is a deny
  list, so it denies the **whole home directory** and re-allows only what an
  agent needs: its own folder, the visible tier, the shell snapshot Claude Code
  sources before each command, and uv's interpreters. Everything the hidden
  targets could be rebuilt from (Pacer's store and logs, every transcript, the
  session-wakes cache, the Pacer repo, the rotation controller's state, Claude
  Desktop's sessions, ARENA_HOME's holdout and labels, other agents' folders)
  lives under the home directory; it is also listed explicitly below, so the
  deny survives if any of it ever moves out, and so the tests can check each one.
- **Permission rules** (`Read(...)`/`Edit(...)` deny) cover the Read, Write and
  Edit tools, which the sandbox does not (§3 row a'). `--restricted` already
  confines those tools to the working directory; the rules are the second lock.

`arena-eval` is the one command exempt from the sandbox, by the exact absolute
path of the agent's own wrapper. Chained commands, `$()`, redirects and shell
functions stay sandboxed (§4). The wrapper bakes in the agent's identity, so an
agent cannot spend another agent's budget or score another agent's folder.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from fleet.paths import FleetPaths

PACER_TEAM_GROUP = "YZXWMJ5VBY.com.ericandrechek.pacer"

# Hosts an agent's shell may reach: package and model hosts only. WebSearch and
# WebFetch are tools, not sandboxed, and stay open for research (DESIGN.md,
# decision 2). A bare "*" opens everything (§3) and must never appear here.
ALLOWED_DOMAINS = (
    "pypi.org",
    "files.pythonhosted.org",
    "github.com",
    "codeload.github.com",
    "*.githubusercontent.com",
    "huggingface.co",
    "*.huggingface.co",
    "*.hf.co",
)


@dataclass(frozen=True)
class SensitivePath:
    path: Path
    why: str


def sensitive_paths(paths: FleetPaths, *, repo_roots: tuple[Path, ...] = ()) -> list[SensitivePath]:
    """Every place an agent must not read, whatever else the settings say.

    The home directory as a whole is denied too (see `agent_settings`); this
    list is what that blanket deny is *for*, kept explicit so a test can check
    each entry and so nothing depends on everything living under $HOME."""
    h = Path.home()
    out = [
        SensitivePath(paths.home, "ARENA_HOME: holdout, labels, salt, results, envs"),
        SensitivePath(paths.root, "the fleet root: other agents, settings, budgets, staged models, inbox"),
        SensitivePath(h / ".claude", "every transcript, job folder, prompt history and credential"),
        SensitivePath(h / ".claude.json", "Claude Code global state (accounts)"),
        SensitivePath(h / ".config" / "claude", "XDG transcripts (Pacer reads both locations)"),
        SensitivePath(h / "Library" / "Group Containers" / PACER_TEAM_GROUP, "Pacer's store"),
        SensitivePath(h / "Library" / "Group Containers" / "group.com.ericandrechek.pacer", "Pacer's legacy store"),
        SensitivePath(h / "Library" / "Logs" / "Pacer", "Pacer's logs: every poll's meter reading"),
        SensitivePath(h / "Library" / "Application Support" / "Claude", "Claude Desktop sessions (counted by Pacer)"),
        SensitivePath(h / ".cache" / "session-wakes", "the session-wakes dataset"),
        SensitivePath(h / ".local" / "state" / "pacer-account-rotation", "rotation controller state and burn logs"),
        SensitivePath(h / ".local" / "share" / "pacer-arena", "the default ARENA_HOME"),
        SensitivePath(h / "Code", "every repository on this Mac, the Pacer repo included"),
    ]
    out += [SensitivePath(r, "the Pacer repo (holds the snapshot on disk and every branch)") for r in repo_roots]
    seen, unique = set(), []
    for s in out:
        key = str(s.path)
        if key not in seen:
            seen.add(key)
            unique.append(s)
    return unique


@dataclass
class AgentSandbox:
    """Everything that varies per agent. Paths are absolute."""

    paths: FleetPaths
    gen: int
    name: str
    snapshot_id: str
    other_agents: tuple[str, ...] = ()
    # Paths inside the agent folder the Edit tool may not change: the harness,
    # the kit, the synthetic generator, every earlier model. Copy, don't modify.
    protected: tuple[str, ...] = ("arena", "kit", "synth", "pyproject.toml", "uv.lock", "AGENTS.md")
    earlier_models: tuple[str, ...] = ()
    repo_roots: tuple[Path, ...] = ()
    uv_python: str | None = None
    extra_allow_read: tuple[Path, ...] = ()
    extra_env: dict[str, str] = field(default_factory=dict)
    # Re-open the owner's git config to the sandbox (what Claude Code's own
    # blockReadsOutsideWorkingDirectories does). Off: it names the owner. The
    # fallback if git still cannot commit (docs/fleet-verification.md §8).
    allow_git_global_config: bool = False

    @property
    def agent_dir(self) -> Path:
        return self.paths.agent_dir(self.gen, self.name)

    @property
    def wrapper(self) -> Path:
        return self.paths.eval_wrapper(self.gen, self.name)

    @property
    def agent_arena_home(self) -> Path:
        return self.agent_dir / ".arena-home"

    def allow_read(self) -> list[Path]:
        h = Path.home()
        out = [
            self.agent_dir,
            # The visible tier, as fleet/visible.py publishes it. Never the raw
            # train/: some of its columns hold values known only after T_train.
            self.paths.visible_view(self.snapshot_id),
            # Claude Code sources a snapshot of the user's shell before every
            # Bash command; without it every command fails.
            h / ".claude" / "shell-snapshots",
            # uv-managed interpreters (read-only); a venv's python may link here.
            h / ".local" / "share" / "uv" / "python",
        ]
        if self.allow_git_global_config:
            out += [h / ".gitconfig", h / ".config" / "git"]
        return out + list(self.extra_allow_read)

    def deny_read(self) -> list[Path]:
        return [Path.home()] + [s.path for s in sensitive_paths(self.paths, repo_roots=self.repo_roots)]

    def env(self) -> dict[str, str]:
        a = self.agent_dir
        env = {
            # Agent-local caches: the sandbox lets an agent write only its own
            # folder (and TMPDIR), and a shared cache would be a channel between agents.
            "UV_CACHE_DIR": str(a / ".uv-cache"),
            "UV_NO_CONFIG": "1",
            "UV_LINK_MODE": "copy",
            "XDG_CACHE_HOME": str(a / ".cache"),
            "HF_HOME": str(a / ".hf-cache"),
            "MPLCONFIGDIR": str(a / ".cache" / "matplotlib"),
            # The owner's ~/.gitconfig signs commits with his GPG key and names
            # him as author, and the sandbox cannot read it: git dies on an
            # unreadable global config. A regular file in the agent's own folder
            # (Claude Code write-protects <cwd>/.gitconfig) stands in for it.
            # /dev/null was the first choice; `git commit` failed in the sandbox
            # with it (docs/fleet-verification.md §8).
            "GIT_CONFIG_GLOBAL": str(a / ".gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
            # The agent's arena home: the visible tier only (fleet/visible.py),
            # with writable cache/ and results/ of its own.
            "ARENA_HOME": str(self.agent_arena_home),
            "ARENA_SNAPSHOT": self.snapshot_id,
            "ARENA_EVAL": str(self.wrapper),
            # Claude Code's Bash tool stops a command at 2 minutes by default
            # (10 at most). A visible-tier `arena test` can run much longer
            # (gen 1: 30-episode runs hit the limit).
            "BASH_DEFAULT_TIMEOUT_MS": "1800000",
            "BASH_MAX_TIMEOUT_MS": "3600000",
        }
        if self.uv_python:
            env["UV_PYTHON"] = self.uv_python
        env.update(self.extra_env)
        return env

    def permissions(self) -> dict:
        a = self.agent_dir
        w = str(self.wrapper)
        allow = [
            # Every Bash command runs sandboxed; the sandbox is the boundary.
            "Bash",
            f"Bash({w})",
            f"Bash({w} *)",
            f"Read(/{a}/**)",
            f"Edit(/{a}/**)",
            "Edit(./**)",
            "WebFetch",
            "WebSearch",
        ]
        deny: list[str] = []
        for p in self.deny_rule_paths():
            # The bare form covers a file (or the directory entry), /** what is under it.
            deny += [f"Read(/{p})", f"Read(/{p}/**)", f"Edit(/{p})", f"Edit(/{p}/**)"]
        for rel in self.protected + tuple(f"models/{m}" for m in self.earlier_models):
            target = a / rel
            deny.append(f"Edit(/{target}/**)" if not rel.endswith((".toml", ".lock", ".md")) else f"Edit(/{target})")
        deny += [f"Edit(/{a}/.git/**)", f"Edit(/{a}/BRIEF.md)"]
        return {
            "defaultMode": "dontAsk",
            "disableBypassPermissionsMode": "disable",
            "allow": allow,
            "deny": deny,
        }

    def deny_rule_paths(self) -> list[Path]:
        """Read()/Edit() deny targets. Not the home directory as a whole (a
        deny beats an allow, so that would lock the agent out of its own
        folder), and not the fleet root as a whole for the same reason: its
        parts are listed instead."""
        out = [s.path for s in sensitive_paths(self.paths, repo_roots=self.repo_roots)
               if s.path not in (self.paths.root,) and not _is_within(self.agent_dir, s.path)]
        p = self.paths
        out += [p.bin, p.templates, p.settings, p.state, p.inbox, p.reviews, p.root / "cache",
                p.gen_dir(self.gen) / ".runs", p.gen_dir(self.gen) / "collect.git",
                p.gen_dir(self.gen) / "collected", p.fleet_json(self.gen)]
        out += [p.agent_dir(self.gen, o) for o in self.other_agents if o != self.name]
        if p.root.is_dir():
            # Other generations, and anything else at the root at launch time.
            for child in sorted(p.root.iterdir()):
                if child.name.startswith("gen") and child != p.gen_dir(self.gen):
                    out.append(child)
        return _dedupe(out)

    def settings(self) -> dict:
        w = str(self.wrapper)
        return {
            "sandbox": {
                "enabled": True,
                "failIfUnavailable": True,
                "allowUnsandboxedCommands": False,
                "autoAllowBashIfSandboxed": True,
                "excludedCommands": [w, f"{w} *"],
                "filesystem": {
                    "denyRead": [str(p) for p in _dedupe(self.deny_read())],
                    "allowRead": [str(p) for p in _dedupe(self.allow_read())],
                },
                "network": {"allowedDomains": list(ALLOWED_DOMAINS)},
            },
            "permissions": self.permissions(),
            "env": self.env(),
            "includeCoAuthoredBy": False,
        }


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def _dedupe(items: list[Path]) -> list[Path]:
    seen, out = set(), []
    for p in items:
        if str(p) not in seen:
            seen.add(str(p))
            out.append(p)
    return out


def check_settings(settings: dict, *, agent_dir: Path, wrapper: Path, train: Path,
                   must_deny: list[Path]) -> list[str]:
    """Problems with a generated settings dict, empty when it is safe to run.
    The launcher refuses to start an agent whose settings fail this; the
    tests run it on every variant."""
    problems: list[str] = []
    sb = settings.get("sandbox", {})
    if sb.get("enabled") is not True or sb.get("failIfUnavailable") is not True:
        problems.append("sandbox must be enabled with failIfUnavailable")
    if sb.get("allowUnsandboxedCommands") is not False:
        problems.append("allowUnsandboxedCommands must be false")
    if sorted(sb.get("excludedCommands", [])) != sorted([str(wrapper), f"{wrapper} *"]):
        problems.append("the only excluded command must be the agent's own arena-eval, by absolute path")
    for cmd in sb.get("excludedCommands", []):
        if not cmd.startswith("/"):
            problems.append(f"excluded command not absolute: {cmd}")
    fs = sb.get("filesystem", {})
    deny = [Path(p) for p in fs.get("denyRead", [])]
    allow = [Path(p) for p in fs.get("allowRead", [])]
    for target in must_deny:
        if not any(_is_within(target, d) for d in deny):
            problems.append(f"not denied: {target}")
        for a in allow:
            if _is_within(target, a):
                problems.append(f"re-opened by allowRead {a}: {target}")
    if not any(_is_within(train, a) for a in allow):
        problems.append(f"the visible tier is not readable: {train}")
    if not any(_is_within(agent_dir, a) for a in allow):
        problems.append("agent folder not readable")
    for a in allow:
        if any(ch in str(a) for ch in "*?[]"):
            problems.append(f"allowRead with a glob is ignored by Claude Code: {a}")
    domains = sb.get("network", {}).get("allowedDomains", [])
    if "*" in domains:
        problems.append("allowedDomains '*' opens every host")
    perms = settings.get("permissions", {})
    if perms.get("defaultMode") not in ("dontAsk",):
        problems.append("permission mode must be dontAsk")
    for rule in perms.get("allow", []):
        if rule.startswith("Bash(") and rule not in (f"Bash({wrapper})", f"Bash({wrapper} *)"):
            problems.append(f"unexpected Bash allow rule: {rule}")
    return problems
