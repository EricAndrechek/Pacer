# Contributing to Pacer

Thanks for your interest! Pacer is a native macOS menu-bar app for tracking
Claude Code usage. Bug reports, feature ideas, and PRs are all welcome.

> **Heads up:** day-to-day maintenance of this repo — triage, PR review, and
> merges — is largely handled by an AI agent (Claude Code) acting on the
> owner's behalf. Comments and commits attributed that way are from the agent,
> not Eric personally. You're still talking to a real project; just know who's
> on the other end.

## Reporting bugs / requesting features

Open an issue — the templates ask for the few things that make a report
actionable (Pacer version, macOS version, a screenshot for visual bugs). A
screenshot is worth a thousand words for UI issues.

## Development setup

Requirements: macOS 15+, Xcode 16+, and [`xcodegen`](https://github.com/yonsm/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml`, so
you never edit `.xcodeproj` directly.

```sh
make verify     # fast compile-only check (no signing, no install)
make test       # PacerCore unit + ground-truth tests
make install    # build + sign + notarize + install to /Applications, relaunch
make help       # all targets
```

Architecture, invariants, and the non-negotiable correctness/performance rules
live in [`agents.md`](agents.md) — worth a skim before a non-trivial change.

## Pull requests

1. Branch off `main`, make your change, and make sure `make verify` and
   `make test` pass.
2. Open a PR. CI (PacerCore tests + a verify build) runs automatically; for
   first-time contributors a maintainer approves the run.
3. PRs are **squash-merged** to `main`, so your branch history doesn't need to
   be tidy — a clear PR description does more good.
4. Comments explain *why*, not *what* — especially where Pacer deliberately
   deviates from `ccusage` or upstream defaults.

By contributing you agree your contributions are licensed under the repository's
[MIT License](LICENSE).
