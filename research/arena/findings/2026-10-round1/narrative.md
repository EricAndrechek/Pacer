## The short version

The first round of the forecast arena (October 2026) asked how well models can forecast Claude Code rate-limit meters and spend. It tested what Pacer ships against 45 ported models and 89 models written by two generations of Claude agents.

**Models from this round beat what Pacer ships on every meter.** They were judged on the most recent three weeks of one real usage history, which no model and no agent ever saw.

- **5-hour meter:** about **35% more accurate** than Pacer's shipping rule (CRPS skill). The typical miss at reset is about a third smaller, and the miss at the next reading about two-thirds smaller.
- **Weekly meter:** about **48% more accurate**.
- **Hourly spend:** about **40% more accurate** than assuming the current rate continues.

**The winners are simple, not giant.**
- The smallest pretrained model, **Timestral 5M**, matched or beat the 123M and 209M versions on both meters.
- The 5-hour leader is a **nearest-moments ("analog") forecaster written from scratch by a Fable 5.1 agent**, with no pretrained weights at all. It looks for past moments like now and replays what followed.

## How the round ran

**Step 1: a test bench that can't be fooled.** A frozen, pseudonymised snapshot of the usage history, with two clocks on every row (when it happened, when Pacer could have known it), checked row for row against the raw transcripts. The harness hands each model only what was known at the forecast moment and scores the whole forecast path, including how honest its ranges are.

The proof it holds:

- a model handed the answers scores perfectly;
- models that try to cheat gain nothing;
- the Python port of Pacer's engine reproduces every prediction the current app recorded.

**Step 2: everything that existed, ported and ranked (45 models).**

- Pacer's 7 engine methods and the rule it ships.
- The live meter and spend models.
- Timestral in 4 sizes, plus Chronos-2, TimesFM 2.5, TiRex, Toto and Moirai.
- Machine-learning models and model combiners.

**Step 3: two generations of Claude agents, 18 in all.** Haiku 4.5 up to Fable 5.1, at low up to extra-high effort, each in a sandbox that could not reach the hidden data, together wrote 89 models. The second generation started from the first generation's models and scores.

## What the agents showed

- **Fable 5.1 and Opus 5.5 wrote the standouts:** the 5-hour analog model, the weekly ensembles, and the best account-split and next-cycle-start forecasts.
- **The leaderboard flattered some models.** The first generation's leaderboard winner on the 5-hour meter (Sonnet 4.6 at low effort, calibrating Timestral) fell back to about the shipping rule's level on the hidden final weeks. Catching that is what the held-back weeks are for.
- **The second generation added small, real gains.** On the weekly meter, a Haiku 4.5 agent's long-context Timestral 209M and an Opus 5.5 agent's gated ensemble now lead, just ahead of generation 1's best. Opus 5.5's ensemble also became the best next-cycle-start forecast. On the 5-hour meter, nothing in generation 2 beat generation 1's analog model.
- **Effort and model size mattered less than expected.** A Haiku agent wrote the weekly leader.

## What's next

1. **Run a winner in shadow mode inside Pacer,** beside the shipping rule.
2. **Fix the ranges.** The winners' 80% ranges are now too wide, where the rule's were too narrow. A calibration layer is the cheapest remaining gain.
3. **Score these frozen models again on data that didn't exist yet** (`arena run --tier prospective`; see RUNBOOK.md). That is the honest test of generalisation. This round used one person's data and four accounts.

## Caveats

- **The final, held-back ranking scored a selection, not all 89 agent models.** It covers the 15 strongest ports, generation 1's 9 strongest on the leaderboard runs, and each generation-2 agent's own submission(s): 33 models on identical test cases. Agent models not in that selection show "-" in the agents tables below.
- **The 5-hour ranking rests on few scored points.** Read it as "these few clearly beat the rule", not as an exact order.
- **The per-model (Fable) weekly cap couldn't be judged.** It barely moved in the final weeks, so a flat forecast wins.
- **Some agents' models fail some forecasts** (a missing key, a crash); those count as misses for that forecast only.
- **The last three generation-1 agents had a better setup than the first seven,** fixed mid-run, which confounds comparing Claude models within generation 1.
- **Ported models ran on ordinary workers, agent models in sealed Docker containers.** Tests show the two paths give identical scores.
