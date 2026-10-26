"""The agent's --settings: every sensitive place denied to the shell and to
the file tools, the visible tier readable, the eval gate the one exemption."""
import copy
from pathlib import Path

from fleet.sandbox import ALLOWED_DOMAINS, AgentSandbox, check_settings, sensitive_paths


def _sb(paths, **kw):
    return AgentSandbox(paths=paths, gen=1, name="alice", snapshot_id="snap1",
                        other_agents=("alice", "bob", "carol"), earlier_models=("example-linear", "port-x"),
                        repo_roots=(Path("/Users/someone/Code/Pacer"),), **kw)


def _within(p: Path, root: Path) -> bool:
    try:
        p.relative_to(root)
        return True
    except ValueError:
        return False


def _must_deny(paths, sb):
    snap = paths.home / "snapshots" / "snap1"
    return [s.path for s in sensitive_paths(paths, repo_roots=sb.repo_roots)] + [
        snap / "holdout", snap / "labels", snap / "manifest.json", snap / "validation", paths.home / "salt",
        snap / "train",   # the raw copy: late columns
        paths.home / "results", paths.home / "envs", paths.agent_dir(1, "bob"), paths.agent_dir(1, "carol"),
        paths.state, paths.settings, paths.bin, paths.templates, paths.fleet_json(1),
        Path.home() / ".claude" / "projects", Path.home() / ".claude" / "jobs",
        Path.home() / "Library" / "Group Containers" / "YZXWMJ5VBY.com.ericandrechek.pacer",
        Path.home() / ".cache" / "session-wakes", Path.home() / ".gitconfig", Path.home() / ".ssh",
        Path("/Users/someone/Code/Pacer"),
    ]


def test_generated_settings_pass_the_checker(paths):
    sb = _sb(paths)
    s = sb.settings()
    assert check_settings(s, agent_dir=sb.agent_dir, wrapper=sb.wrapper, train=paths.visible_view("snap1"),
                          must_deny=_must_deny(paths, sb)) == []


def test_every_sensitive_path_denied_to_the_shell(paths):
    sb = _sb(paths)
    fs = sb.settings()["sandbox"]["filesystem"]
    deny = [Path(p) for p in fs["denyRead"]]
    allow = [Path(p) for p in fs["allowRead"]]
    assert Path.home() in deny                         # the blanket deny
    for target in _must_deny(paths, sb):
        assert any(_within(target, d) for d in deny), target
        assert not any(_within(target, a) for a in allow), target
    for s in sensitive_paths(paths, repo_roots=sb.repo_roots):  # also listed one by one
        assert s.path in deny, s


def test_visible_view_and_own_folder_readable(paths):
    sb = _sb(paths)
    allow = [Path(p) for p in sb.settings()["sandbox"]["filesystem"]["allowRead"]]
    assert paths.train_dir("snap1") not in allow          # raw train/ holds late values
    assert paths.visible_view("snap1") in allow
    assert sb.agent_dir in allow
    assert not any(a == paths.home or a == paths.home / "snapshots" / "snap1" for a in allow)
    assert all(not any(c in str(a) for c in "*?[") for a in allow)


def test_file_tools_denied_too(paths):
    sb = _sb(paths)
    deny = sb.settings()["permissions"]["deny"]
    for p in (paths.home, Path.home() / ".claude", paths.agent_dir(1, "bob"), paths.agent_dir(1, "carol"),
              paths.state, paths.settings, paths.bin, Path("/Users/someone/Code/Pacer"),
              Path.home() / "Library" / "Group Containers" / "YZXWMJ5VBY.com.ericandrechek.pacer"):
        assert f"Read(/{p}/**)" in deny, p
        assert f"Edit(/{p}/**)" in deny, p
    # never a deny that would lock the agent out of its own folder
    for rule in deny:
        if rule.startswith("Read("):
            target = Path(rule[len("Read(/"):-1].removesuffix("/**"))
            assert not _within(sb.agent_dir, target), rule
    assert f"Read(/{Path.home() / '.claude.json'})" in deny             # files need the bare form
    # copy, don't modify
    assert f"Edit(/{sb.agent_dir / 'arena'}/**)" in deny
    assert f"Edit(/{sb.agent_dir / 'models' / 'port-x'}/**)" in deny
    assert f"Edit(/{sb.agent_dir / '.git'}/**)" in deny


def test_eval_gate_exempt_only_by_absolute_path(paths):
    sb = _sb(paths)
    s = sb.settings()
    w = str(paths.eval_wrapper(1, "alice"))
    assert w.startswith("/") and "/gen1/alice/" in w
    assert s["sandbox"]["excludedCommands"] == [w, f"{w} *"]
    assert f"Bash({w})" in s["permissions"]["allow"] and f"Bash({w} *)" in s["permissions"]["allow"]
    bash_rules = [r for r in s["permissions"]["allow"] if r.startswith("Bash(")]
    assert bash_rules == [f"Bash({w})", f"Bash({w} *)"]
    assert s["sandbox"]["allowUnsandboxedCommands"] is False
    assert s["sandbox"]["failIfUnavailable"] is True
    assert s["permissions"]["defaultMode"] == "dontAsk"
    assert s["permissions"]["disableBypassPermissionsMode"] == "disable"


def test_network_allowlist(paths):
    domains = _sb(paths).settings()["sandbox"]["network"]["allowedDomains"]
    assert "*" not in domains
    for d in ("pypi.org", "files.pythonhosted.org", "github.com", "huggingface.co"):
        assert d in domains
    assert tuple(domains) == ALLOWED_DOMAINS


def test_env_keeps_caches_and_git_local(paths):
    sb = _sb(paths, uv_python="/opt/homebrew/bin/python3.12")
    env = sb.settings()["env"]
    a = str(sb.agent_dir)
    for k in ("UV_CACHE_DIR", "XDG_CACHE_HOME", "HF_HOME", "ARENA_HOME"):
        assert env[k].startswith(a + "/"), k
    assert env["GIT_CONFIG_GLOBAL"] == f"{a}/.gitconfig" and env["GIT_CONFIG_NOSYSTEM"] == "1"
    assert env["ARENA_EVAL"] == str(sb.wrapper)
    assert env["UV_PYTHON"] == "/opt/homebrew/bin/python3.12"


def test_checker_catches_unsafe_variants(paths):
    sb = _sb(paths)
    base = sb.settings()
    args = dict(agent_dir=sb.agent_dir, wrapper=sb.wrapper, train=paths.visible_view("snap1"),
                must_deny=_must_deny(paths, sb))

    def broken(mutate):
        s = copy.deepcopy(base)
        mutate(s)
        return check_settings(s, **args)

    assert broken(lambda s: s["sandbox"]["filesystem"]["allowRead"].append(str(paths.home)))
    assert broken(lambda s: s["sandbox"]["filesystem"]["allowRead"].append(str(paths.agent_dir(1, "bob"))))
    assert broken(lambda s: s["sandbox"]["filesystem"]["denyRead"].clear())
    assert broken(lambda s: s["sandbox"].update(allowUnsandboxedCommands=True))
    assert broken(lambda s: s["sandbox"].update(enabled=False))
    assert broken(lambda s: s["sandbox"]["excludedCommands"].append("python3 *"))
    assert broken(lambda s: s["sandbox"].update(excludedCommands=["arena-eval", "arena-eval *"]))
    assert broken(lambda s: s["sandbox"]["network"]["allowedDomains"].append("*"))
    assert broken(lambda s: s["permissions"].update(defaultMode="bypassPermissions"))
    assert broken(lambda s: s["permissions"]["allow"].append("Bash(python3 *)"))
    assert broken(lambda s: s["sandbox"]["filesystem"]["allowRead"].append(str(paths.home / "snapshots" / "*")))


def test_owner_git_config_reopened_only_on_request(paths):
    allow = [Path(p) for p in _sb(paths).settings()["sandbox"]["filesystem"]["allowRead"]]
    assert Path.home() / ".gitconfig" not in allow
    allow = [Path(p) for p in _sb(paths, allow_git_global_config=True).settings()["sandbox"]["filesystem"]["allowRead"]]
    assert Path.home() / ".gitconfig" in allow and Path.home() / ".config" / "git" in allow
