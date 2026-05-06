# Real-Time Claude Code Usage Data: Four Candidate Mechanisms

**Pacer Research Report**  
**Date:** May 6, 2026  
**Objective:** Evaluate push-style alternatives to disk polling for live Claude Code token usage tracking

## Executive Summary

This report evaluates four officially documented mechanisms for receiving real-time Claude Code usage data. The statusline mechanism emerges as the strongest choice for Pacer v1, offering push updates via JSON with cumulative session cost/token data, 1-second refresh cadence, and zero configuration burden. OpenTelemetry is the best long-term foundation but requires more orchestration. Hooks provide deterministic execution at specific lifecycle events but lack usage payloads. MCP is one-directional and unsuitable for usage monitoring.

---

## 1. Hooks: Shell Commands at Lifecycle Events

### What It Is

Hooks are user-defined shell commands that execute at specific points in Claude Code's lifecycle (PreToolUse, PostToolUse, Stop, SessionStart, SessionEnd, etc.). They receive event-specific JSON on stdin and can modify Claude's behavior or integrate with external systems.

**Official Documentation:**  
https://code.claude.com/docs/en/hooks-guide.md  
https://code.claude.com/docs/en/hooks.md

### Data Available

Hook events receive:
- **Common fields:** `session_id`, `cwd`, `transcript_path`, `hook_event_name`, `permission_mode`
- **Event-specific fields:** tool name, tool input, error details, configuration changes, etc.

**Critical limitation:** Hook payloads do **not include token usage, costs, or API response data**. The `Stop` event fires when Claude finishes responding but receives no `usage` object. Hooks cannot access cumulative session costs or token counts—that data simply isn't passed to the hook script via stdin.

The only way to correlate hook events to token usage is indirectly: by having a hook read the transcript JSONL file (`transcript_path`) and parse it to extract the latest message containing usage metadata.

### Latency

- **Type:** Event-driven push (no polling)
- **Timing:** Pre-tool, post-tool, session lifecycle events
- **Cadence:** Fires only when events occur (latency ~0ms relative to the event)
- **For usage tracking:** Would need to run on `Stop` event and synchronously parse JSONL, adding 50-200ms latency

### Stability

- **Officially documented:** Yes, comprehensive with detailed event schemas
- **Stable:** Core hook framework is stable; event schema has matured
- **Version fragility:** Low risk; core events unlikely to change
- **Status:** Fully released, not beta

### Config Burden

- Add `hooks` block to `~/.claude/settings.json` or `.claude/settings.json`
- Point to a shell script or inline command
- Script must handle JSON parsing (requires `jq` or similar)
- **Example:**
  ```json
  {
    "hooks": {
      "Stop": [
        {
          "matcher": "",
          "hooks": [
            {
              "type": "command",
              "command": "~/.claude/hooks/pacer-stop-hook.sh"
            }
          ]
        }
      ]
    }
  }
  ```

### Verdict for Pacer's Use Case

**Not suitable as primary mechanism.** Hooks are deterministic and reliable but:
- Do not include usage data in the event payload
- Would require parsing the transcript JSONL on every `Stop` event (wasteful, adds latency)
- No way to get incremental updates (would have to wait for `Stop` to fire)
- Better suited for triggering actions than for real-time data collection

**Possible secondary role:** Use a `Stop` hook to trigger Pacer to read the latest JSONL and POST usage to the local socket, rather than relying on Pacer to poll. This converts disk polling into event-driven reads, but still requires JSONL parsing.

---

## 2. OpenTelemetry / Metrics Export

### What It Is

Claude Code exports structured telemetry via OpenTelemetry (OTel), the industry standard for observability. Metrics (time series: token counts, costs, session lifecycle) and events (discrete records: API requests, tool calls, permissions) flow to a configurable OTLP (OpenTelemetry Protocol) endpoint.

**Official Documentation:**  
https://code.claude.com/docs/en/monitoring-usage.md

### Data Available

**Metrics** (cumulative counters and gauges):
- `claude_code.token.usage` — token count (input, output, cache_read, cache_creation)
- `claude_code.cost.usage` — session cost in USD
- `claude_code.session.count` — session start counter
- `claude_code.lines_of_code.count` — lines added/removed
- Attributes: `session.id`, `model`, `query_source`, `speed`, `effort`, `type` (input/output/cache)

**Events** (individual occurrences):
- `claude_code.api_request` — per-API call: model, cost_usd, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, request_id
- `claude_code.tool_result` — per-tool execution: tool_name, success, duration_ms, decision (accept/reject)
- `claude_code.user_prompt` — per-user-submitted prompt
- **Event correlation:** `prompt.id` UUID links all events (API calls, tool calls) triggered by a single prompt

**Traces (beta, requires `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`):**
- Distributed spans linking user prompts → API calls → tool executions
- Span attributes: `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `duration_ms`

**Most useful for Pacer:** `claude_code.api_request` events include `cost_usd` and all token types. Events are emitted **within ~5-10 seconds** of API calls (controlled by `OTEL_LOGS_EXPORT_INTERVAL`).

### Latency

- **Type:** Push (Claude Code exports to OTel backend)
- **Metric export interval:** 60 seconds by default; configurable down to 5 seconds (via `OTEL_METRIC_EXPORT_INTERVAL`)
- **Event export interval:** 5 seconds by default; configurable down to 1 second (via `OTEL_LOGS_EXPORT_INTERVAL`)
- **Practical latency:** 5-60 seconds depending on interval config
- **Batch behavior:** Metrics/events batch at intervals; high-frequency updates are aggregated

### Stability

- **Officially documented:** Yes, comprehensive reference
- **Stable:** Yes, fully released (not beta)
- **Traces (optional):** Beta feature, may change
- **Version fragility:** Low risk; OTel spec is upstream standard
- **Maturity:** Used in production by organizations shipping Claude Code internally

### Config Burden

Requires environment variables set **before** launching Claude Code:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_METRIC_EXPORT_INTERVAL=5000  # 5 seconds
export OTEL_LOGS_EXPORT_INTERVAL=5000    # 5 seconds

claude
```

Can also set via `.claude/settings.json` `env` block (for managed settings).

**Pacer's orchestration burden:**
- Run an embedded OTel collector (OpenTelemetry Collector or similar) listening on localhost:4317
- Configure the collector to receive OTLP/gRPC and forward events to Pacer's backend
- OR: Have Pacer run an OTLP sink that collects events and writes to local storage

### Verdict for Pacer's Use Case

**Excellent long-term choice, moderate setup complexity.** Strengths:
- Push-based (no polling)
- Industry-standard protocol; integrates with monitoring stacks (Datadog, New Relic, Grafana Loki)
- Rich schema: cost, tokens, model, effort level, cache metrics, request IDs
- Event correlation via `prompt.id` lets Pacer tie token usage to user prompts
- Latency tuneable down to 1 second (impractical but possible)
- Officially stable and documented

Weaknesses:
- Requires external OTel collector or Pacer-provided sink
- More complex than statusline for simple cost tracking
- Environment variables must be set before session starts (not discoverable after launch)
- Batch export means sub-5-second latency requires custom configuration

**Recommendation:** Ideal for Pacer v2 or enterprise deployments. Requires significant engineering to wire up collector infrastructure. Best paired with a time-series database (InfluxDB, Prometheus) for long-term trend analysis.

---

## 3. Statusline: Script-Driven Status Bar

### What It Is

The statusline is a persistent status bar at the bottom of the Claude Code terminal UI. Claude Code runs a user-provided shell script and pipes JSON session data to it on stdin. The script outputs formatted text, which Claude Code displays. Updates fire after each assistant message, after `/compact`, and on permission-mode changes.

**Official Documentation:**  
https://code.claude.com/docs/en/statusline.md

### Data Available

Statusline scripts receive comprehensive JSON via stdin:

```json
{
  "session_id": "...",
  "cwd": "/current/dir",
  "model": { "id": "...", "display_name": "Opus" },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_api_duration_ms": 2300,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "context_window": {
    "total_input_tokens": 15234,
    "total_output_tokens": 4521,
    "context_window_size": 200000,
    "used_percentage": 8.0,
    "remaining_percentage": 92.0,
    "current_usage": {
      "input_tokens": 8500,
      "output_tokens": 1200,
      "cache_creation_input_tokens": 5000,
      "cache_read_input_tokens": 2000
    }
  },
  "rate_limits": {
    "five_hour": {
      "used_percentage": 23.5,
      "resets_at": 1738425600
    },
    "seven_day": {
      "used_percentage": 41.2,
      "resets_at": 1738857600
    }
  },
  "effort": { "level": "high" },
  "thinking": { "enabled": true },
  "transcript_path": "/path/to/transcript.jsonl",
  "version": "2.1.90"
}
```

**Critical fields for Pacer:**
- `cost.total_cost_usd` — cumulative session cost
- `context_window.total_input_tokens`, `total_output_tokens` — cumulative usage
- `context_window.current_usage.*` — per-API-call breakdown (input, cache creation, cache read)
- `rate_limits` — subscription rate limit window usage (5-hour and 7-day)

**Note:** All fields are client-side calculated and available **immediately** after each API call.

### Latency

- **Type:** Push (script runs on event)
- **Update triggers:** After each assistant message, after `/compact`, on permission-mode change, on vim-mode toggle
- **Debounce:** Rapid changes batch; script runs once per ~300ms when settled
- **Refresh interval:** Optional fixed timer (configurable, minimum 1 second) for time-based data
- **Practical latency:** 0-300ms from API response to statusline update
- **Cadence:** Can achieve ~1-second updates if `refreshInterval: 1` is set

### Stability

- **Officially documented:** Yes, extensive guide with examples
- **Stable:** Fully released (not beta); schema is documented and stable
- **Version fragility:** Low risk; statusline has been stable for many releases
- **Maturity:** Used by thousands; widely adopted for cost tracking

### Config Burden

**Minimal for end user.** Two options:

**Option 1: Auto-generate (easiest)**
```
/statusline show token usage and costs
```
Claude Code generates a script and updates settings automatically.

**Option 2: Manual configuration**
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "refreshInterval": 1
  }
}
```

Script reads JSON from stdin, parses with `jq` or language-native JSON (Python/Node), outputs formatted text.

**Pacer's burden:** Supply a statusline script that:
1. Parses the JSON
2. POSTs to a Unix domain socket (or HTTP endpoint) that Pacer listens on
3. Outputs a user-friendly summary to stdout

Example (pseudocode):
```bash
#!/bin/bash
input=$(cat)
cost=$(echo "$input" | jq '.cost.total_cost_usd')
input_tokens=$(echo "$input" | jq '.context_window.total_input_tokens')
output_tokens=$(echo "$input" | jq '.context_window.total_output_tokens')

# POST to Pacer
echo "{\"cost\": $cost, \"input_tokens\": $input_tokens, \"output_tokens\": $output_tokens}" | \
  curl -X POST --unix-socket /tmp/pacer.sock http://localhost/usage -d @-

# Display to user
echo "Pacer: \$$cost | $input_tokens in / $output_tokens out"
```

### Verdict for Pacer's Use Case

**Excellent choice for Pacer v1.** Strengths:
- **Push-based:** No polling required
- **Rich data:** All cumulative session metrics included
- **Low latency:** 0-300ms, with 1-second refresh optional
- **Dead simple config:** Just point to a script
- **Official and stable:** Documented, widely used, no risk of deprecation
- **Zero setup for users:** Script is shipped with Pacer
- **Portable:** Works on macOS, Linux, Windows (Git Bash / PowerShell)
- **Correlation:** Includes `transcript_path` and `session_id` if Pacer wants to cross-reference JSONL

Weaknesses:
- Only updates during Claude Code activity (idle sessions get stale data; mitigated by `refreshInterval`)
- Limited to single Claude Code session per terminal (statusline is per-session)
- User must add one setting to their config (minor friction)

**Recommendation:** **Primary choice for Pacer v1.** Ship a statusline script with Pacer that:
1. Parses the JSON statusline input
2. POSTs usage snapshots to Pacer's local API (Unix socket or HTTP)
3. Displays a short summary ("Pacer: tracking…") to the user
4. User adds one line to settings: `"statusLine": { "type": "command", "command": "/path/to/pacer-statusline.sh", "refreshInterval": 1 }`

Achieves real-time (1-second) cost and token tracking with near-zero friction.

---

## 4. MCP Server: Model Context Protocol

### What It Is

The Model Context Protocol (MCP) is a bidirectional communication standard between Claude and external servers. Claude can invoke tools on an MCP server, and the server can push updates to Claude. Pacer could expose itself as an MCP server and receive per-message context from Claude Code.

**Official Documentation:**  
https://code.claude.com/docs/en/mcp.md

### Data Available

**MCP server capabilities:**
- Tools: Server defines named tools that Claude invokes (e.g., "get_session_usage")
- Resources: Server exposes static data (file contents, database records) that Claude reads
- Prompts: Server defines templates that Claude can invoke
- Channels: Server can push unsolicited messages back to Claude (experimental)

**Critical limitation:** MCP is primarily **tool-call-based**. Claude invokes a tool on Pacer (e.g., "get_current_session_cost"), Pacer returns the result. This is pull-based (Claude asks), not push-based (Pacer broadcasts).

**Push mechanism (channels, experimental):**
- MCP supports "channels" for server-to-client messages, but these are gated behind organization allowlists and not documented for real-time usage data
- No built-in mechanism for servers to receive token usage or cost data from Claude Code
- Claude Code does not expose usage/cost hooks to MCP servers; MCP servers cannot observe when API calls happen or what they cost

**Result:** MCP is unsuitable for Pacer's use case. It cannot receive push updates about usage; it can only provide tools for Claude to call (backwards from what Pacer needs).

### Latency

- **Type:** Pull-based (Claude invokes tools on Pacer)
- **Latency:** Only when Claude chooses to call the tool; no automatic updates
- **Cadence:** Entirely user-determined or Claude-determined via prompt ("check my usage")

### Stability

- **Officially documented:** Yes, comprehensive MCP reference
- **Stable:** Core protocol is stable; channels are experimental
- **Channels (push):** Undocumented publicly, requires internal allowlist, may change
- **Version fragility:** Protocol evolves; servers may need updates

### Config Burden

Add to `.claude/settings.json`:
```json
{
  "mcp": {
    "servers": {
      "pacer": {
        "transport": "stdio",
        "command": "/path/to/pacer-mcp-server"
      }
    }
  }
}
```

Pacer would need to implement MCP server protocol (JSON-RPC 2.0 over stdio/HTTP/SSE). Significant engineering.

### Verdict for Pacer's Use Case

**Not suitable.** While MCP is a standard and stable protocol:
- Fundamentally pull-based; Claude must ask for data
- No mechanism for Pacer to receive usage notifications from Claude Code
- Would require Pacer to expose a "get_current_session_usage" tool that Claude never calls
- Adds complexity without the push-based benefit Pacer needs
- Better suited for integrations (Claude querying Pacer for past session data) than real-time tracking

**Possible secondary role:** Pacer could expose an MCP server to let Claude query historical session data or budgets for cost management prompts ("should I continue or do I have budget?"). Not for real-time monitoring.

---

## Ranked Recommendation

### For Pacer v1: Use Statusline

**Recommended primary mechanism:**

1. **Ship a statusline script** with Pacer (in `~/.pacer/statusline.sh`)
2. **User runs one command** (or Pacer guides them):
   ```bash
   /statusline use ~/.pacer/statusline.sh with 1-second refresh
   ```
3. **Script receives JSON every ~1 second**, extracts:
   - `cost.total_cost_usd`
   - `context_window.total_input_tokens` / `total_output_tokens`
   - `rate_limits` (5-hour and 7-day windows)
4. **Script POSTs to local Unix socket/HTTP** that Pacer listens on
5. **Pacer stores time series** and updates the macOS app UI

**Advantages:**
- Zero polling; push-driven updates at 1-second cadence
- Official, stable, widely documented
- Minimal user friction (one `/statusline` command)
- Includes all metrics Pacer needs (costs, tokens, rate limits)
- Works across all platforms (macOS, Linux, Windows)
- No external dependencies (collector, agents)

**Implementation effort:** Medium (script + HTTP endpoint in Pacer)

---

### For Pacer v1.5+: Add OpenTelemetry Support

**Secondary mechanism for power users / Enterprise:**

1. **Ship OTel collector config** (standalone or embedded)
2. **Advanced users configure:**
   ```bash
   export CLAUDE_CODE_ENABLE_TELEMETRY=1
   export OTEL_LOGS_EXPORTER=otlp
   export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
   export OTEL_METRIC_EXPORT_INTERVAL=5000
   ```
3. **Pacer receives OTel events** with rich attributes (model, effort, cache, request IDs)
4. **Integrate with Datadog/New Relic/Grafana** for organization-wide dashboards

**Advantages:**
- Industry standard; integrates with existing monitoring
- Rich context (model, effort, cache metrics, request IDs, request-id for cost reconciliation)
- Event correlation via `prompt.id`
- Scales to multiple users / teams

**Implementation effort:** High (OTel collector integration)

---

### Hooks: Not Primary, Possible Helper

**Tertiary role (future optimization):**

- Use `Stop` hook to trigger Pacer to read the latest JSONL transcript entry (rather than polling)
- Converts disk polling to event-driven JSONL reads
- Still requires parsing JSONL but eliminates the 60-second polling interval
- **Only if:** Statusline latency is insufficient or JSONL cross-reference is critical

---

### MCP: Defer or Skip

**Not recommended for real-time usage tracking.** Reconsider if:
- Pacer needs to be a passive resource that Claude Code queries
- Use case evolves to "Claude asks Pacer for budget before continuing"

Otherwise, statusline + OpenTelemetry cover all needs.

---

## Summary Table

| Mechanism      | Latency      | Push vs Pull | Data Quality | Config Burden | Stability | Verdict           |
|----------------|--------------|--------------|--------------|---------------|-----------|-------------------|
| **Statusline** | 0-300ms (1s) | Push         | Excellent    | Minimal       | Stable    | **Use for v1**    |
| **OTel**       | 5-60s        | Push         | Excellent    | Moderate      | Stable    | Use for v1.5+     |
| **Hooks**      | Event-driven | Push (event) | Poor (JSONL) | Moderate      | Stable    | Helper only       |
| **MCP**        | On-demand    | Pull         | N/A          | High          | Beta      | Skip              |

---

## Implementation Roadmap

### Pacer v1.0 (MVP: Statusline)
- Statusline script shipped with Pacer
- Listens on Unix socket for status updates
- MacOS app displays real-time cost/token counters
- 1-second refresh cadence

### Pacer v1.5+ (OpenTelemetry)
- Embed OpenTelemetry Collector (or HTTP receiver)
- Instructions for users to enable OTEL env vars
- Pacer dashboard integrates OTel events
- Optional Datadog / New Relic export

### Pacer v2.0+ (Advanced)
- Hooks-based JSONL event stream (for users who prefer no statusline script)
- Rate limit window visualization from OTel
- Multi-session aggregation
- Historical trend analysis

---

## Conclusion

**Statusline is the clear winner for Pacer v1:** it offers push-based real-time updates (1-second cadence), requires minimal configuration, is officially stable, and delivers all metrics Pacer needs. OpenTelemetry is the strategic long-term choice for organizations and trend analysis. Hooks and MCP are unsuitable for the primary use case but may serve secondary roles in future versions.

**Recommended action:** Prototype with statusline immediately. The engineering effort is low, the user experience is seamless, and the foundation scales to OpenTelemetry once that layer is built.
