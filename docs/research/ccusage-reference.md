# ccusage Technical Reference for Pacer Swift Port

**Source commit:** `1a4bd69b9214ff55f3745d4d864108d662e4dea0` (main, fetched 2026-05-06)
**Package version:** ccusage `18.0.11` (`apps/ccusage/package.json`)
**Note:** ccusage is an pnpm/Turborepo monorepo. The Claude Code CLI lives at `apps/ccusage/`; the MCP server is now a separate package at `apps/mcp/`; pricing helpers used by both are in `packages/internal/`.

---

## 1. Claude Code data paths ccusage checks

The single source of truth is `getClaudePaths()` in `apps/ccusage/src/data-loader.ts:78-143`. The constants it relies on live in `apps/ccusage/src/_consts.ts`.

**Resolution algorithm (exact order):**

1. **`CLAUDE_CONFIG_DIR` env var** (`_consts.ts:63`, `data-loader.ts:83-111`).
   Comma-separated, trimmed. Each path is `path.resolve()`-normalized, then ccusage requires that the directory itself exists *and* that a `projects/` subdirectory exists within it. Duplicates are filtered via a Set. **If the env var is set but no provided path is valid, ccusage throws** rather than falling back. This matters: a Swift port should treat env-var presence as opt-in exclusivity.

2. **`~/.config/claude/`** (XDG config dir; `_consts.ts:45-57`). The base is `xdgConfig ?? path.join(homedir(), '.config')` — i.e. `XDG_CONFIG_HOME` is honored if set, else `~/.config`. ccusage docs (`docs/guide/directory-detection.md:9`) call this the "new default" introduced when Claude Code 1.0.30 made an undocumented breaking change.

3. **`~/.claude/`** (`_consts.ts:51`, `DEFAULT_CLAUDE_CODE_PATH = '.claude'`). Documented as "legacy" in `directory-detection.md:11`, but in practice **Claude Code 2.1.x still writes here on macOS** — the README's "legacy" framing is misleading. ccusage handles this by *aggregating both directories when both exist* rather than picking one.

For each candidate, ccusage requires `<root>/projects/` to also exist (`data-loader.ts:92`, `122`). The `projects/` dir name is hardcoded in `_consts.ts:69` as `CLAUDE_PROJECTS_DIR_NAME = 'projects'`.

**Cross-platform notes:**
- ccusage uses `node:os.homedir()` and `node:path` so paths normalize correctly on Windows (backslashes). `extractProjectFromPath` (`data-loader.ts:150-162`) explicitly normalizes both `/` and `\` separators.
- For `loadSessionUsageById` (`data-loader.ts:1136-1138`), ccusage forces forward-slash glob patterns even on Windows because tinyglobby requires that.
- There is **no Windows-specific path** like `%APPDATA%/Claude` — ccusage assumes Claude Code uses the Unix-style locations on every platform.

**Glob:** Files are discovered via `tinyglobby` with pattern `**/*.jsonl` (constants in `_consts.ts:75`). All paths are globbed in parallel (`globUsageFiles`, `data-loader.ts:716-728`) and errors per-path are swallowed (`.catch(() => [])`).

For a Swift port: replicate (1) → (2) → (3), validate the `projects/` subdir exists, and aggregate union (don't pick first match).

---

## 2. JSONL parsing and Claude Code version handling

**Schema:** `usageDataSchema` at `data-loader.ts:167-193` (Valibot). Fields parsed:

| Field | Required | Notes |
|---|---|---|
| `timestamp` | yes | ISO 8601, validated by regex `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$` (`_types.ts:34`) |
| `message.usage.input_tokens` | yes | number |
| `message.usage.output_tokens` | yes | number |
| `message.usage.cache_creation_input_tokens` | optional | number |
| `message.usage.cache_read_input_tokens` | optional | number |
| `message.usage.speed` | optional | `'standard' \| 'fast'` — used as a multiplier from LiteLLM's `provider_specific_entry.fast` |
| `message.model` | optional | model name; appended with `-fast` suffix in display when speed is fast (`data-loader.ts:352-358`) |
| `message.id` | optional | deduplication key |
| `message.content[].text` | optional | only used to parse the "Claude AI usage limit reached \|<unix-ts>" sentinel |
| `costUSD` | optional | pre-calculated cost from Claude Code |
| `requestId` | optional | deduplication key |
| `version` | optional | Claude Code version (semver-prefix regex `^\d+\.\d+\.\d+`, `_types.ts:81`) |
| `sessionId` | optional | branded string |
| `cwd` | optional | accepted but unused at parse time |
| `isApiErrorMessage` | optional | when `true`, ccusage scrapes the rate-limit reset timestamp |

**Cache 5m/1h ephemeral tiers:** ccusage **does NOT split** `cache_creation_input_tokens` into 5-minute vs 1-hour ephemeral tiers. The schema treats it as a single number (`data-loader.ts:176`). If your Pacer port needs that breakdown (which Anthropic's API exposes as `cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`), you'll have to extend the schema yourself — there is no precedent in ccusage. Confirmed by grep across the entire repo: zero references to "5m"/"1h"/"ephemeral" in parsing code.

**Synthetic-message sentinel:** Claude Code emits entries with model `<synthetic>` for non-billable internal messages. ccusage skips these in three places:
- `aggregateByModel` (`data-loader.ts:381-383`) — `if (modelName === '<synthetic>') continue;`
- `aggregateModelBreakdowns` (`data-loader.ts:417-419`)
- `extractUniqueModels` (`data-loader.ts:524`)
The token counts on synthetic entries are still read but never aggregated into a model bucket — they effectively vanish. Important to mirror this exactly.

**Version skew tolerance:** ccusage uses `safeParse` everywhere (e.g. `data-loader.ts:807`, `973`, `1159`, `1400`). When the schema fails, the entry is silently dropped (no log, no error). Unknown fields are ignored by Valibot's default object behavior. New optional fields don't break parsing. The pattern is "best-effort, defensive" — when in doubt, skip the line. Malformed JSON is caught by an outer `try/catch` (`data-loader.ts:831-833`, etc.) and silently dropped — no log on JSON-parse failure in the daily/session paths, though `loadSessionBlockData` (line 1437) does emit a `logger.debug`.

**Streaming:** Files are read line-by-line via `node:readline` over a `createReadStream` (`processJSONLFileByLine`, `data-loader.ts:547-565`) with `crlfDelay: Number.POSITIVE_INFINITY` for CRLF tolerance. This avoids loading whole files into memory — important for large sessions. Empty lines are skipped. Partial last-line writes get caught by JSON.parse and dropped.

**Deduplication:** `createUniqueHash` (`data-loader.ts:530-540`) builds the key as `${message.id}:${requestId}`. **If either is missing, no dedup happens** (returns null). A `processedHashes: Set<string>` is maintained across the entire load (across files), and duplicate hashes are silently skipped.
The "why": Claude Code resumes sessions by spawning new JSONL files that replay prior turns — without dedup, those entries would be double-counted. To make dedup deterministic, files are sorted by their earliest timestamp first via `sortFilesByTimestamp` (`data-loader.ts:605-629`); chronological order ensures the earliest occurrence wins. **This is the single biggest correctness fix a naive port would miss.** (Tests at `data-loader.ts:4218-4259` and `4428-4477` cover it.)

---

## 3. Cost calculation

### Modes

The user's expected names (`auto`, `calculate`, `exact`, `both`) are **wrong**. The real names from `_types.ts:140`:

```ts
export const CostModes = ['auto', 'calculate', 'display'] as const;
```

Defined in `calculateCostForEntry` (`data-loader.ts:638-678`):

- **`auto`** (default): use `data.costUSD` if present; otherwise compute from tokens. This is what most users get.
- **`calculate`**: always compute from tokens; ignore `costUSD` entirely. Used to get consistent methodology across time and to avoid drift when Claude's pricing changes mid-history.
- **`display`**: always use `data.costUSD`; default to 0 if missing. The fastest mode (no pricing fetch needed at all — `using fetcher = mode === 'display' ? null : new PricingFetcher(...)` at `data-loader.ts:786`).

There is no `exact` or `both` mode for the main cost computation. However, the **statusline** command (`apps/ccusage/src/commands/statusline.ts:82`) has its own `--cost-source` flag with choices `['auto', 'ccusage', 'cc', 'both']` — that's purely for displaying CC's own session cost (from the statusline hook JSON's `cost.total_cost_usd`) alongside ccusage's calculation. Easy to confuse with the global cost mode; they are distinct.

### Pricing source

- **URL:** `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` (`packages/internal/src/pricing.ts:4-5`, constant `LITELLM_PRICING_URL`).
- **Schema:** `liteLLMModelPricingSchema` at `packages/internal/src/pricing.ts:31-53`. Per-token costs in USD: `input_cost_per_token`, `output_cost_per_token`, `cache_creation_input_token_cost`, `cache_read_input_token_cost`. Plus `max_tokens` / `max_input_tokens` / `max_output_tokens` for context-window detection.
- **Tiered pricing for 1M-context Claude models:** there are `_above_200k_tokens` variants for each cost field. `calculateTieredCost` (`pricing.ts:290-316`) splits totals at 200k and applies the higher rate above. Important corner case: if `tiered_price` is set but `base_price` is missing, only above-threshold tokens are charged (test at `pricing.ts:533-571`). Gemini's 128k threshold fields exist in the schema but **are not implemented** — flagged with a TODO comment at `pricing.ts:44-46`.
- **Fast multiplier:** `provider_specific_entry.fast` is multiplied into the cost when `usage.speed === 'fast'` (`pricing.ts:366-368`).
- **Model matching:** `createMatchingCandidates` (`pricing.ts:210-219`) tries the literal name plus prefixes from `CLAUDE_PROVIDER_PREFIXES` (`_pricing-fetcher.ts:6-12`): `anthropic/`, `claude-3-5-`, `claude-3-`, `claude-`, `openrouter/openai/`. If no exact prefix-match, falls back to substring match (`pricing.ts:232-238`) — matches in either direction (key ⊂ model or model ⊂ key). Returns null if nothing matches; `calculateCostFromTokens` then yields `Result.fail` and the cost defaults to 0 (unwrap default at `data-loader.ts:653,668`).

### Caching/offline

- ccusage prefetches the Claude-only subset of LiteLLM at **build time** via a tsdown macro (`apps/ccusage/src/_macro.ts`, used in `_pricing-fetcher.ts:14`) and embeds it in the bundled CLI. So `--offline` uses an embedded snapshot, not the network.
- At runtime: in-memory cache (`cachedPricing: Map<string, LiteLLMModelPricing>` at `pricing.ts:96`); single fetch per process. Uses `Symbol.dispose` so `using fetcher = ...` cleans up automatically.
- On fetch failure, falls back to the embedded offline snapshot (`pricing.ts:132-149`).

### Where `costUSD` lives

`costUSD` is a **top-level field on each JSONL line** (not in a sub-cache). See schema at `data-loader.ts:190` and the test fixture at `data-loader.ts:1551-1577`. Path: `<line>.costUSD` (number, USD). Claude Code populates it for some but not all entries — older lines often lack it, which is why `auto` mode exists as a hybrid.

---

## 4. Full feature surface

### Subcommands (registered in `apps/ccusage/src/commands/index.ts:24-31`)

| Subcommand | Source | Purpose |
|---|---|---|
| `daily` (default) | `commands/daily.ts` | Token usage and cost grouped by date |
| `monthly` | `commands/monthly.ts` | Aggregates daily into months |
| `weekly` | `commands/weekly.ts` | Aggregates daily into ISO weeks; `--start-of-week` flag (sunday default) |
| `session` | `commands/session.ts` | One row per `projectPath/sessionId` |
| `blocks` | `commands/blocks.ts` | Claude's 5-hour billing windows; supports `--active`, `--recent`, `--token-limit` (number or `max`), `--session-length` |
| `statusline` | `commands/statusline.ts` | Single-line output for Claude Code's `statusLine` hook |

There is no `mcp` subcommand in the main CLI — the MCP server moved to a separate `@ccusage/mcp` package (`apps/mcp/`) that is run as `bunx @ccusage/mcp`. Source: `docs/guide/mcp-server.md:1-15`.

### Filtering / shared flags

From `_shared-args.ts:19-113`. All commands share:
- `--since`/`-s`, `--until`/`-u` — `YYYYMMDD` format (validated by `filterDateSchema`, `_types.ts:67-72`)
- `--mode`/`-m` — `auto`/`calculate`/`display`
- `--order`/`-o` — `desc`/`asc` (default `asc`)
- `--breakdown`/`-b` — show per-model cost rows
- `--offline`/`-O` — use embedded pricing
- `--timezone`/`-z` and `--locale`/`-l` (default `en-CA` which gives ISO YYYY-MM-DD)
- `--json`/`-j` — JSON output
- `--jq`/`-q` — pipe JSON through jq (implies `--json`)
- `--debug`/`-d` plus `--debug-samples` — dump pricing-mismatch report
- `--color`/`--no-color`, `--compact`, `--config`

`daily`/`monthly`/`weekly` add `--instances`/`-i` (group by project) and `--project`/`-p` (filter to one project). When `--project` is set, project grouping is automatically enabled (`data-loader.ts:839`).

### Output formats

- **Table** (default, via `@ccusage/terminal/table`'s `ResponsiveTable`). Auto-switches to compact mode below ~120 columns; `--compact` forces it.
- **JSON** via `--json` or `--jq`. Each command emits a different shape — e.g. daily returns `{daily: [...], totals: {...}}` or `{projects: {...}, totals: {...}}` when `--instances`. Blocks return `{blocks: [...]}`.
- **CSV: there is none.** ccusage does not have CSV output. The user's question implied it might — for a Swift port, plan to add CSV ourselves if needed.

### Live/watch mode

**Removed in v18.0.0.** The old `blocks --live` is gone (`docs/guide/live-monitoring.md:5-7`). Recommended replacement is statusline integration. So a Swift port doesn't need to replicate live polling — but you may want it for Pacer's UI. Note: statusline uses a *file-based semaphore* in `tmpdir()/ccusage-semaphore/` (`commands/statusline.ts:47-79`) to avoid concurrent updates and to cache outputs by transcript-mtime. Useful pattern.

### MCP server

Lives in `apps/mcp/`. Entry: `apps/mcp/src/index.ts` → `command.ts` → `mcp.ts`. The server registers **6 tools** (`mcp.ts:58-181`):
- `daily`, `session`, `monthly`, `blocks` — each accepting `since/until/mode/timezone/locale` (Zod schema at `mcp/src/ccusage.ts:10-18`)
- `codex-daily`, `codex-monthly` — for OpenAI Codex sibling tool

Implementation note: each MCP tool **shells out to the ccusage binary** (`mcp/src/ccusage.ts:32-65`, `executeCliCommand`) with `--json` and parses the result. It does NOT call the data-loader library directly. So the MCP server is just a JSON-RPC wrapper around the CLI. For a Swift port, this means you can implement MCP separately later; the data loader is the core.

Transports: `stdio` (default) and `http` via Hono (`mcp.ts:206-218`, default port 8080).

### Statusline

Single-line output designed for Claude Code's `statusLine` hook. Reads a JSON blob on stdin (the schema is `statuslineHookJsonSchema` at `_types.ts:160-189`) containing `session_id`, `transcript_path`, `model.id`, `cost.total_cost_usd`, `context_window.total_input_tokens`, etc. Outputs:

```
🤖 Opus | 💰 $0.23 session / $1.23 today / $0.45 block (2h 45m left) | 🔥 $0.12/hr | 🧠 25,000 (12%)
```

Key behavior:
- Defaults to **offline mode** for speed.
- Caches output in a tmpdir semaphore keyed by `session_id`, invalidated on transcript-file mtime change.
- Has its own `--cost-source` flag (`auto/ccusage/cc/both`) — only relevant inside the statusline.
- Visual burn-rate indicators: `--visual-burn-rate` choices `off/emoji/text/emoji-text`.
- Context-tokens calculation reads the *last* assistant message in the transcript (`data-loader.ts:1264-1347`), iterating from end-of-file to first-match, computing `input_tokens + cache_creation + cache_read` and dividing by the model's `max_input_tokens` from LiteLLM (fallback 200,000).

---

## 5. Robustness/correctness lessons worth porting

These are the non-obvious correctness fixes a naive port WILL miss:

1. **Cross-file deduplication by `${messageId}:${requestId}`** (`data-loader.ts:530-540`). Resumed sessions create multiple JSONL files that replay turns. Without this, your daily costs will be inflated (sometimes 2-3x) for active users. The dedup set is global across all files in a single load. **Files must be sorted by earliest timestamp first** so the original (not the resumed copy) is processed first.

2. **`<synthetic>` model exclusion** in three aggregation paths (`data-loader.ts:381, 417, 524`). Internal Claude Code messages have a `<synthetic>` model and must not be billed. Tokens on those entries are silently dropped from rollups.

3. **Streaming line-by-line reads** with `crlfDelay: Infinity` (`data-loader.ts:547-565`). Don't read whole JSONL files into memory; large sessions (10MB+) are real.

4. **Sort files by earliest timestamp** before processing (`sortFilesByTimestamp`, `data-loader.ts:605-629`). This is what makes dedup deterministic. The function streams just enough of each file to find the first valid timestamp.

5. **Defensive parse-or-skip everywhere.** Every `JSON.parse` is in a try/catch; every Valibot `safeParse` failure becomes a silent drop. **Never throw on a single bad line.**

6. **Aggregate from BOTH `~/.config/claude` AND `~/.claude` when both exist** (`data-loader.ts:113-131`). Claude Code 1.0.30+ uses the new path but old data may still live in the legacy one. Don't pick one — union them. Use a Set of resolved paths to avoid double-counting symlinks.

7. **5-hour blocks float to UTC hour** (`floorToHour`, `_session-blocks.ts:15-19`). Block start time is `setUTCMinutes(0,0,0)` of the first entry. Critically: a new block starts when *either* (a) time since block-start exceeds 5h *or* (b) time since last entry exceeds 5h (`_session-blocks.ts:122`). Gap blocks are inserted between blocks separated by more than 5h of inactivity (`createGapBlock`, line 220+). Block durations are configurable via `--session-length`.

8. **Date grouping locale must be `en-CA`** (`_consts.ts:130`). The DEFAULT_LOCALE is intentionally en-CA because it formats as `YYYY-MM-DD` which sorts lexicographically. For Swift, just format with `yyyy-MM-dd` directly.

9. **Timezone handling.** Date grouping uses the user-specified `--timezone` (or system) but storage is always normalized to YYYY-MM-DD via `formatDate(timestamp, options?.timezone, DEFAULT_LOCALE)` (e.g. `data-loader.ts:824`). The block-date filter explicitly strips dashes to compare with YYYYMMDD args (`data-loader.ts:1457`). Tests at `data-loader.ts:1480-1499` cover Asia/Tokyo and America/New_York day-boundary crossings.

10. **Pricing model match is fuzzy.** `createMatchingCandidates` plus substring fallback (`pricing.ts:210-242`) means `claude-sonnet-4-20250514` matches LiteLLM keys like `anthropic/claude-sonnet-4-20250514` and even partial overlaps. For a Swift port, replicate the candidate-prefix list and then substring-fallback both directions (key.contains(model) OR model.contains(key)). Don't expect exact-key matches.

11. **Tiered pricing at 200k for 1M context Claude models** (`pricing.ts:290-316`). When input/output tokens exceed 200,000, the upper tokens use the `_above_200k_tokens` rate. Crucially: if base_price missing but tiered_price set, only over-threshold tokens are charged (test at `pricing.ts:533-571`). Don't assume both are present.

12. **`CLAUDE_CONFIG_DIR` is exclusive** when set. If a user sets it to a bad path, ccusage **throws** rather than falling back to defaults (`data-loader.ts:107-110`). Surface this as an error in Pacer's UI rather than silently scanning `~/.claude`.

13. **Pricing fetch is cached per-process** with `using` disposable (`pricing.ts:111-117`). For an always-running app like Pacer, a longer-lived cache (with TTL or manual refresh) makes more sense than fetching every analysis. ccusage assumes short-lived CLI runs.

14. **Partial JSONL writes:** ccusage swallows JSON.parse errors silently in daily/session paths (`data-loader.ts:831`). If the active Claude Code session is mid-write, the last line may be truncated — drop it, don't error. This is implicitly handled but worth being explicit about in Swift.

15. **No CSV / no live mode.** Don't waste time porting these — they don't exist in v18.

---

## Things I could not determine definitively from the source

- **Cache 5m/1h ephemeral split:** ccusage doesn't parse this at all, so I can't tell you the exact field path Claude Code 2.1.x uses on disk for the breakdown. The Anthropic API returns `cache_creation: { ephemeral_5m_input_tokens, ephemeral_1h_input_tokens }` (an object), but ccusage only reads the flat `cache_creation_input_tokens` (a number). Whether Claude Code's JSONL contains the structured object or just the flat sum, you'll have to inspect a real JSONL to confirm. The schema has `v.optional` on the sum, so adding `cache_creation: { ephemeral_5m: ..., ephemeral_1h: ... }` to your Swift model is safe.
- **Claude Code 2.1.x path discovery:** the docs claim `~/.config/claude/` is the post-1.0.30 default, but Claude Code 2.1 macOS installs typically still write to `~/.claude/`. The docs do not commit to which CC version uses which path — the behavior is "check both, union the data." Replicate that.
- **`cwd` field semantics:** schema accepts it but ccusage never uses it. It's likely the working directory of the Claude Code session at the time of the message — useful for richer per-project filtering than just the path-segment-based `extractProjectFromPath`, but ccusage doesn't take advantage of it.
