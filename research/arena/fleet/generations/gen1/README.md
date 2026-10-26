# Generation 1

Ten agents, five at a time, each a headless Claude Code run in its own clone of
the generation's template (the harness, the kit, the ported models and their
leaderboard scores, the visible tier of the frozen snapshot). The Claude model,
effort and niche were spread across the agents at random so the effect of the
model is not confounded with the niche.

| file | holds |
|---|---|
| [`plan.toml`](plan.toml) | the plan the launcher ran (`arena fleet launch --gen gen1 --plan …`): agents, models, effort, turn and budget caps, eval budget |
| [`agents.toml`](agents.toml) | what each agent did: turns, the run's API-equivalent cost, arena-eval calls, how it ended, the models it handed back (read by `arena.provenance.agents(1)`) |
| [`SUMMARIES.md`](SUMMARIES.md) | one paragraph per agent: approach and findings, from its own notes, in relative terms |

The 43 models are in [`../../../models/`](../../../models) as `g1-*`, attributed
in `models/PROVENANCE.toml`.

## The setup changed mid-generation

The first seven agents (g1-01 … g1-07) ran with the launcher as built. Their
runs showed three kinds of friction that had nothing to do with forecasting:

- **Short commands.** Claude Code's Bash timeout (2 minutes by default, 10 at most) killed
  visible-tier runs of a realistic size and most arena-eval calls of heavy
  models, and long waits were awkward.
- **No offline weights.** The pretrained forecasters' weights live in the
  owner's Hugging Face cache, which the sandbox denies, and the agent's venv
  lacked the `fm` extra, so structural and foundation-model children failed.
- **No working git.** The sandbox refuses writes under the agent's `.git`, so
  agents could not commit; the launcher's end-of-run hand-back commit picked
  their work up instead.

Before the last three agents started, the coordinator changed their setup:
longer Bash timeouts (30 minutes default, 60 maximum) in their settings, the
`fm` extra pre-synced into their venvs, the weights cloned into a cache inside
each agent's folder, and a few lines in the brief (don't run git, use
`--episodes 8` for quick tests, `chmod` after `cp -r`, the pretrained models
are ready, keep going until the cap). **g1-08, g1-09 and g1-10 therefore had a
better setup than g1-01 … g1-07**, and comparisons across the two groups are
not purely about the Claude model. Generation 2 had all of it from the start
(the launcher and template now do it; `docs/fleet-verification.md` §11).

Three runs (g1-01, g1-04, g1-05) stopped at their budget cap; the others
finished on their own. g1-02 made no arena-eval calls, so its models were
scored for the first time in the tournaments.
