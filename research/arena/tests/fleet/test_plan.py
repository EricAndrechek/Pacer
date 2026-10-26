"""Plan parsing: every agent fully specified, full model ids, known efforts."""
import pytest

from fleet.plan import PlanError, parse_plan

GOOD = """
[fleet]
max_parallel = 3
eval_budget = 15
eval_episodes = 30

[[agent]]
name = "s1"
niche = "statistical"
model = "claude-sonnet-5-5"
effort = "high"
max_turns = 200
budget_usd = 20

[[agent]]
name = "f1"
niche = "pretrained"
model = "claude-fable-5-1"
effort = "xhigh"
max_turns = 300
budget_usd = 40.5
eval_budget = 25
task = "Try Chronos-2 first."
"""


def test_good_plan():
    p = parse_plan(GOOD)
    assert p.max_parallel == 3 and p.eval_episodes == 30 and len(p.sha256) == 64 and p.warnings == ()
    s1, f1 = p.agents
    assert (s1.name, s1.model, s1.effort, s1.max_turns, s1.budget_usd, s1.eval_budget) == \
        ("s1", "claude-sonnet-5-5", "high", 200, 20.0, 15)
    assert f1.eval_budget == 25 and f1.task.startswith("Try") and f1.family == "fable" and s1.family == "sonnet"
    assert p.agent("f1") is f1


def test_defaults():
    p = parse_plan('[[agent]]\nname="a"\nniche="x"\nmodel="claude-opus-5-5"\neffort="low"\nmax_turns=5\nbudget_usd=1\n')
    assert p.max_parallel == 4 and p.agents[0].eval_budget == 20 and p.snapshot is None


@pytest.mark.parametrize("change,match", [
    (('name = "s1"', 'name = "f1"'), "duplicate"),
    (('name = "s1"', 'name = "S 1"'), "bad agent name"),
    (('model = "claude-sonnet-5-5"', 'model = "haiku"'), "full id"),
    (('model = "claude-sonnet-5-5"', 'model = "gpt-5"'), "full id"),
    (('effort = "high"', 'effort = "turbo"'), "effort"),
    (("max_turns = 200\n", ""), "max_turns"),
    (("budget_usd = 20\n", "budget_usd = 0\n"), "budget_usd"),
    (("budget_usd = 20\n", 'budget_usd = "20"\n'), "budget_usd"),
    (("max_parallel = 3", "max_parallel = 50"), "max_parallel"),
    (("max_parallel = 3", "max_paralel = 3"), "unknown keys"),
    (('niche = "statistical"', 'niche = "statistical"\nsecret = 1'), "unknown keys"),
    (('niche = "statistical"', 'niche = ""'), "niche"),
])
def test_bad_plans(change, match):
    with pytest.raises(PlanError, match=match):
        parse_plan(GOOD.replace(*change, 1))


def test_no_agents_and_bad_toml():
    with pytest.raises(PlanError, match="no"):
        parse_plan("[fleet]\nmax_parallel = 2\n")
    with pytest.raises(PlanError, match="TOML"):
        parse_plan("[[agent]\n")


def test_warnings_for_unverified_ids():
    p = parse_plan(GOOD.replace("claude-sonnet-5-5", "claude-sonnet-6").replace("claude-fable-5-1", "claude-haiku-4-5"))
    assert any("claude-sonnet-6" in w for w in p.warnings)
    assert any("ignores --effort" in w for w in p.warnings)
