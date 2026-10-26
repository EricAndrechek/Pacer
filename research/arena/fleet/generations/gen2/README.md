# Generation 2

Eight agents, five at a time, each given one focus (the seven-day meter, deep
ensembles, spend and tokens, the Fable weekly cap, honest ranges, a wildcard,
limit calls, the five-hour meter). Their template held every generation-1
model, the ports, and the scores of both on the leaderboard tier, and they were
told to copy or call earlier models freely but never modify them.

| file | holds |
|---|---|
| [`plan.toml`](plan.toml) | the plan the launcher ran, with each agent's focus in its `task` |
| [`agents.toml`](agents.toml) | turns, the run's API-equivalent cost, arena-eval calls, how it ended, the models it handed back (read by `arena.provenance.agents(2)`) |
| [`SUMMARIES.md`](SUMMARIES.md) | one paragraph per agent: approach and findings, in relative terms |

The 46 models are in [`../../../models/`](../../../models) as `g2-*`, attributed
in `models/PROVENANCE.toml`.

Every agent had the setup generation 1's last three got mid-way (long Bash
timeouts, the `fm` extra and offline weights in its folder, the no-git
hand-back). All eight finished on their own, none at a cap. The collector
flagged every agent for "modifying" an earlier model; each flag was a file-mode
change only (the template's read-only copy round-tripped through the hand-back
commit), not an edit: see `docs/known-issues.md`.
