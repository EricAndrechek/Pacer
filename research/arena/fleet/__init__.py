"""The agent fleet: template repos, sandboxed Claude Code agents, the one
command that may reach hidden data (`arena-eval`), and the collection and
review of what agents hand back.

Security model, in one paragraph (details in docs/fleet-verification.md):
every agent is a headless `claude -p` in a fresh clone of the generation's
template, with Bash inside the macOS sandbox. The sandbox denies reading the
whole home directory and re-allows only the agent's own folder, the visible
tier of the snapshot and what tools need to run. The only command exempt from
the sandbox is the agent's own `arena-eval` wrapper, matched by absolute path;
it validates its single argument, charges a budget kept outside the agent's
reach, and scores the model in a Docker container with no network, returning
rounded scores and nothing else. Attribution is recorded by the launcher,
never taken from the agent.
"""
