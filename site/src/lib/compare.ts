// How Pacer compares: one data file for the /compare/ hub, the per-tool pages,
// llms.txt and the Markdown twins built from them, so none of them can say
// something another doesn't. README.md's "How Pacer compares" table is kept
// in line with it by hand.
//
// Every other tool's cell is read from that tool's own current page or repo
// (checked on CHECKED, the source on each cell; test/compare.test.ts fails on
// a cell without one). Nothing here is inferred from a tool's code or
// guessed: where its pages don't say, the cell is `unstated`, never `no`.
// Pacer's cells point at this site's own pages.

export const CHECKED = '2026-11-27';

export type Mark = 'yes' | 'no' | 'partial' | 'unstated' | 'na';

export interface Cell {
  /** Absent on a text-only row (form factor, price, licence, platforms). */
  mark?: Mark;
  /** Shown in the cell: the text row's value, or what a partial covers. */
  text?: string;
  /** Where it says so. Required for every tool but Pacer. */
  source?: string;
}

export const ROWS = [
  { key: 'form', label: 'Form factor' },
  { key: 'native', label: 'Native app (not Electron)' },
  { key: 'liveLimits', label: "Limit % read from Anthropic, not estimated" },
  { key: 'perModel', label: 'Per-model limit windows' },
  { key: 'pace', label: 'Usage paced against an even burn' },
  { key: 'projection', label: 'End-of-day spend projection' },
  { key: 'heatmap', label: 'Activity heatmap' },
  { key: 'breakdown', label: 'Per-project and per-model breakdown' },
  { key: 'beyond', label: 'Other agents (Codex, opencode, …)' },
  { key: 'widgets', label: 'Desktop widgets' },
  { key: 'notifications', label: 'Threshold alerts' },
  { key: 'csv', label: 'CSV export' },
  { key: 'roi', label: 'Cost against git commits' },
  { key: 'plugins', label: 'Claude Code plugin manager' },
  { key: 'price', label: 'Price' },
  { key: 'license', label: 'Open source' },
  { key: 'platforms', label: 'Runs on' },
] as const;

export type RowKey = (typeof ROWS)[number]['key'];

export interface Source {
  label: string;
  url: string;
}

/** A tool with a page of its own (`/compare/<slug>/`). */
export interface ToolPage {
  title: string;
  description: string;
  /** What the tool is, in a sentence or two. */
  what: string;
  /** How it gets its numbers. */
  data: string;
  /** Where it is the better pick, honestly. */
  betterPick: string[];
  /** Where Pacer differs. */
  pacerDiffers: string[];
}

export interface Tool {
  slug: string;
  name: string;
  /** Short column heading. */
  short: string;
  url: string;
  cells: Record<RowKey, Cell>;
  sources: Source[];
  page?: ToolPage;
}

const y = (source?: string, text?: string): Cell => ({ mark: 'yes', source, text });
const n = (source: string, text?: string): Cell => ({ mark: 'no', source, text });
const part = (source: string, text: string): Cell => ({ mark: 'partial', source, text });
const unstated = (source: string, text?: string): Cell => ({ mark: 'unstated', source, text });
const na = (source: string, text?: string): Cell => ({ mark: 'na', source, text });
const t = (text: string, source?: string): Cell => ({ text, source });

export const PACER: Tool = {
  slug: 'pacer',
  name: 'Pacer',
  short: 'Pacer',
  url: '/',
  sources: [
    { label: 'Features', url: '/features/' },
    { label: 'How Pacer counts', url: '/how-pacer-counts/' },
  ],
  cells: {
    form: t('Menu-bar app', '/features/'),
    native: y('/features/', 'SwiftUI'),
    liveLimits: y('/how-pacer-counts/', 'every few minutes'),
    perModel: y('/features/'),
    pace: y('/features/', 'every window'),
    projection: y('/features/'),
    heatmap: y('/features/', 'six months'),
    breakdown: y('/features/', 'with your own collections'),
    beyond: n('/faq/', 'Claude Code and Claude Desktop agent mode'),
    widgets: y('/features/', 'six'),
    notifications: y('/features/'),
    csv: y('/features/'),
    roi: n('/features/'),
    plugins: n('/features/'),
    price: t('Free', '/faq/'),
    license: t('MIT', '/faq/'),
    platforms: t('macOS 15 or newer', '/faq/'),
  },
};

const CCUSAGE_REPO = 'https://github.com/ccusage/ccusage';
const CODEXBAR = 'https://github.com/steipete/CodexBar';
const MONITOR = 'https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor';
const CLAUDEBAR = 'https://github.com/tddworks/ClaudeBar';
const COSTS_DOC = 'https://code.claude.com/docs/en/costs';
const COMMANDS_DOC = 'https://code.claude.com/docs/en/commands';
const TOKEN_PACER = 'https://tokenpacer.app';
const CLAUDE_GOD = 'https://claudegod.app';
const CLAUDE_GOD_REPO = 'https://github.com/Lcharvol/Claude-God';
const CCSEVA = 'https://github.com/Iamshankhadeep/ccseva';

export const TOOLS: Tool[] = [
  {
    slug: 'codexbar',
    name: 'CodexBar',
    short: 'CodexBar',
    url: CODEXBAR,
    sources: [
      { label: 'CodexBar on GitHub', url: CODEXBAR },
      { label: 'CodexBar releases', url: `${CODEXBAR}/releases` },
    ],
    cells: {
      form: t('Menu-bar app, Linux app, CLI', CODEXBAR),
      native: y(CODEXBAR, 'Swift; Qt on Linux'),
      liveLimits: y(CODEXBAR, 'for Claude'),
      perModel: unstated(CODEXBAR),
      pace: part(CODEXBAR, 'quota burndown with an even-use guide'),
      projection: unstated(CODEXBAR),
      heatmap: unstated(CODEXBAR),
      breakdown: part(CODEXBAR, 'project and session views'),
      beyond: y(CODEXBAR, '100+ providers'),
      widgets: y(CODEXBAR),
      notifications: y(CODEXBAR),
      csv: unstated(CODEXBAR, 'has export controls'),
      roi: unstated(CODEXBAR),
      plugins: unstated(CODEXBAR),
      price: t('Free', CODEXBAR),
      license: t('MIT', CODEXBAR),
      platforms: t('macOS 14 or newer, Linux', CODEXBAR),
    },
    page: {
      title: 'Pacer vs CodexBar',
      description:
        'CodexBar tracks Codex, Claude and 100+ AI providers from the macOS menu bar and on Linux. Pacer is Claude Code only and goes deeper on it. How they differ, and when CodexBar is the better pick.',
      what: 'CodexBar is a free, MIT-licensed menu-bar app for macOS, with a Linux desktop app and a command line, that shows usage and quota for Codex, Claude and more than a hundred other AI providers, from Cursor and Gemini to OpenRouter and Bedrock.',
      data: "For Claude it reads your limits from Anthropic's OAuth usage API, with browser cookies or the Claude CLI as fallbacks.",
      betterPick: [
        'You use Codex, Cursor, Gemini, Copilot or other providers alongside Claude and want them in one menu.',
        'You work on Linux, or want a scriptable command line as well as the menu bar.',
      ],
      pacerDiffers: [
        'Pacer covers Claude Code alone, and reads its transcripts on your Mac for tokens and cost by project, model and day, with a six-month heatmap.',
        "Every window Anthropic reports for your account, per-model caps included, gets a pace chart against an even burn and a forecast to its reset.",
        'Each request is priced at the rate in effect when it was made, from a dated price list.',
        'A Claude Code skill and a pacer command pause long agent runs before a limit and resume them after.',
      ],
    },
  },
  {
    slug: 'ccusage',
    name: 'ccusage',
    short: 'ccusage',
    url: CCUSAGE_REPO,
    sources: [
      { label: 'ccusage on GitHub', url: CCUSAGE_REPO },
      { label: 'ccusage releases', url: `${CCUSAGE_REPO}/releases` },
      { label: "Pacer's notes on ccusage's internals (version 18)", url: 'https://github.com/EricAndrechek/Pacer/blob/main/docs/research/ccusage-reference.md' },
    ],
    cells: {
      form: t('Command line', CCUSAGE_REPO),
      native: na(CCUSAGE_REPO, 'a command-line tool'),
      liveLimits: n(CCUSAGE_REPO, '5-hour blocks inferred from local logs'),
      perModel: n(CCUSAGE_REPO),
      pace: n(CCUSAGE_REPO),
      projection: unstated(CCUSAGE_REPO),
      heatmap: n(CCUSAGE_REPO),
      breakdown: y(CCUSAGE_REPO),
      beyond: y(CCUSAGE_REPO, 'about 20 agents'),
      widgets: na(CCUSAGE_REPO, 'a command-line tool'),
      notifications: unstated(CCUSAGE_REPO),
      csv: unstated(CCUSAGE_REPO, 'its README lists JSON output'),
      roi: unstated(CCUSAGE_REPO),
      plugins: unstated(CCUSAGE_REPO),
      price: t('Free', CCUSAGE_REPO),
      license: t('MIT', CCUSAGE_REPO),
      platforms: t('Any terminal with npx, bunx or Nix', CCUSAGE_REPO),
    },
    page: {
      title: 'Pacer vs ccusage',
      description:
        'ccusage is the command-line tool Pacer was ported from. How the two count Claude Code usage differently, on purpose, and when ccusage is the better pick.',
      what: 'ccusage is a free, MIT-licensed command-line tool that reports Claude Code token usage and cost by day, week, month, session and 5-hour block, from the logs on your machine. It now reads about twenty agents besides, Codex, OpenCode, Amp, Cline, Goose and Gemini CLI among them. Pacer started as a port of it.',
      data: "It reads the session logs the agents write locally. Claude Code's 5-hour windows are worked out from those logs, so the limit percentage is an estimate, not Anthropic's reading.",
      betterPick: [
        'You want numbers in a terminal or a script: ccusage prints tables or JSON, and runs wherever npx, bunx or Nix does, CI included.',
        'You use Codex or other agents too and want one report across them.',
        'You want nothing running in the background.',
      ],
      pacerDiffers: [
        "Pacer is an app that stays in the menu bar, with widgets and alerts, and reads your actual limit percentages from Anthropic for every window, per-model caps included.",
        'It paces each window against an even burn and forecasts where it will be at its reset.',
        'It counts some things differently on purpose, listed below.',
      ],
    },
  },
  {
    slug: 'claude-code-usage-monitor',
    name: 'Claude Code Usage Monitor',
    short: 'Usage Monitor',
    url: MONITOR,
    sources: [
      { label: 'Claude-Code-Usage-Monitor on GitHub', url: MONITOR },
      { label: 'Its releases', url: `${MONITOR}/releases` },
    ],
    cells: {
      form: t('Terminal view', MONITOR),
      native: na(MONITOR, 'a Python terminal app'),
      liveLimits: part(MONITOR, "Claude Code's statusline readings when fresh, else a labelled estimate"),
      perModel: n(MONITOR, 'model distribution only'),
      pace: part(MONITOR, 'reset-aware pace and burn rate'),
      projection: part(MONITOR, 'session forecasts and cost projections'),
      heatmap: unstated(MONITOR),
      breakdown: part(MONITOR, 'per-model tables'),
      beyond: unstated(MONITOR),
      widgets: n(MONITOR),
      notifications: part(MONITOR, 'exit codes and the terminal title'),
      csv: y(MONITOR),
      roi: unstated(MONITOR),
      plugins: unstated(MONITOR),
      price: t('Free', MONITOR),
      license: t('MIT', MONITOR),
      platforms: t('Linux, macOS, Windows', MONITOR),
    },
    page: {
      title: 'Pacer vs Claude Code Usage Monitor',
      description:
        'Claude Code Usage Monitor is a live terminal view of Claude Code usage for Linux, macOS and Windows. Pacer is a native Mac menu-bar app. How they compare, and when the monitor is the better pick.',
      what: 'Claude Code Usage Monitor (Claude-Code-Usage-Monitor on GitHub) is a free, MIT-licensed Python program that draws a live view of your Claude Code session in the terminal: tokens, cost, burn rate and a forecast for the session.',
      data: "It reads Claude Code's local logs. For limits it uses the rate-limit readings in Claude Code's statusline data while they are fresh, and otherwise shows a local estimate, labelled as one.",
      betterPick: [
        'You live in a terminal, or work on Linux or Windows.',
        'You want a live burn-rate view in a terminal pane, with JSON, text or CSV output.',
      ],
      pacerDiffers: [
        "Pacer runs in the menu bar and widgets on your Mac, so it is there without a terminal open, and it asks Anthropic for your limits every few minutes on its own.",
        'It keeps your whole history: cost by project, model and day, a six-month heatmap, and every window paced to its reset, per-model caps included.',
        'It can alert you at a threshold, and its skill pauses agent runs before a limit.',
      ],
    },
  },
  {
    slug: 'claudebar',
    name: 'ClaudeBar',
    short: 'ClaudeBar',
    url: CLAUDEBAR,
    sources: [
      { label: 'ClaudeBar on GitHub', url: CLAUDEBAR },
      { label: 'ClaudeBar releases', url: `${CLAUDEBAR}/releases` },
    ],
    cells: {
      form: t('Menu-bar app, notch, Touch Bar', CLAUDEBAR),
      native: y(CLAUDEBAR, 'Swift'),
      liveLimits: y(CLAUDEBAR),
      perModel: y(CLAUDEBAR, 'Opus, Sonnet, Fable'),
      pace: part(CLAUDEBAR, 'pace-aware colours and a forecast'),
      projection: part(CLAUDEBAR, 'whether a window lasts to its reset'),
      heatmap: unstated(CLAUDEBAR),
      breakdown: unstated(CLAUDEBAR),
      beyond: y(CLAUDEBAR, 'Codex, Gemini, Copilot, Cursor and more'),
      widgets: unstated(CLAUDEBAR),
      notifications: y(CLAUDEBAR, 'also webhooks and Slack'),
      csv: unstated(CLAUDEBAR),
      roi: unstated(CLAUDEBAR),
      plugins: n(CLAUDEBAR, 'extensions add quota sources'),
      price: t('Free', CLAUDEBAR),
      license: t('Apache 2.0', CLAUDEBAR),
      platforms: t('macOS 15 or newer', CLAUDEBAR),
    },
    page: {
      title: 'Pacer vs ClaudeBar',
      description:
        "ClaudeBar shows Claude, Codex, Gemini and other quotas in the menu bar, the notch and the Touch Bar. Pacer is Claude Code only, with cost history and agent pacing. How they compare.",
      what: 'ClaudeBar is a free, Apache-licensed macOS app that shows AI coding quotas in the menu bar, the notch and the Touch Bar: Claude, with its Opus, Sonnet and Fable limits, and Codex, Gemini, Copilot, Cursor and more.',
      data: "It shows each provider's remaining quota, coloured by pace, with a forecast of whether a window will last to its reset.",
      betterPick: [
        'You track Claude alongside Codex, Gemini, Copilot or Cursor and want one place for all of them.',
        'You want quotas in the notch or on the Touch Bar, or alerts sent to a webhook or Slack.',
      ],
      pacerDiffers: [
        "Pacer reads Claude Code's transcripts too, for tokens and cost by project, model and day, priced at the rate in effect when each request was made.",
        'It keeps that history (a six-month heatmap, any day in detail) and projects where today will end.',
        'Its Claude Code skill and pacer command pause long agent runs before a limit and resume them after.',
      ],
    },
  },
  {
    slug: 'claude-code-usage-command',
    name: "Claude Code's /usage",
    short: '/usage',
    url: COSTS_DOC,
    sources: [
      { label: 'Claude Code docs: costs and usage', url: COSTS_DOC },
      { label: 'Claude Code docs: commands', url: COMMANDS_DOC },
    ],
    cells: {
      form: t('In the terminal', COMMANDS_DOC),
      native: na(COMMANDS_DOC, 'part of Claude Code'),
      liveLimits: y(COSTS_DOC),
      perModel: unstated(COSTS_DOC),
      pace: n(COSTS_DOC),
      projection: n(COSTS_DOC),
      heatmap: part(COMMANDS_DOC, 'activity stats'),
      breakdown: part(COSTS_DOC, 'by model and by skill, subagent, plugin or MCP server; not by project'),
      beyond: na(COSTS_DOC, 'part of Claude Code'),
      widgets: na(COMMANDS_DOC, 'in the terminal'),
      notifications: n(COSTS_DOC, 'messages in the session at a limit'),
      csv: n(COSTS_DOC, '/insights writes an HTML report'),
      roi: n(COSTS_DOC, 'lines added and removed per session'),
      plugins: na(COMMANDS_DOC, 'part of Claude Code'),
      price: t('Included with Claude Code', COSTS_DOC),
      license: t('Part of Claude Code', COSTS_DOC),
      platforms: t('Wherever Claude Code runs', COSTS_DOC),
    },
    page: {
      title: "Pacer vs Claude Code's /usage",
      description:
        "Claude Code's built-in /usage shows your plan's limits and this session's usage. Pacer keeps the history, paces every window and stays in the menu bar. When /usage is all you need.",
      what: "/usage is Claude Code's own view of your plan usage (/cost and /stats open it too): the bars for your rate-limit windows, this session's tokens and cost by model, and activity stats.",
      data: "It reads the limits from Anthropic, the same as Pacer, and attributes your plan usage to the skills, subagents, plugins and MCP servers that used it.",
      betterPick: [
        "You are already in the terminal and want a quick look, with nothing to install.",
        'You work on Linux, Windows or over SSH.',
        'You want to know which skill, subagent, plugin or MCP server is using your plan: /usage attributes it, Pacer does not.',
      ],
      pacerDiffers: [
        "/usage is a snapshot you ask for, in one session. Pacer is in the menu bar all the time and remembers every session, across every project and account.",
        'It paces each window against an even burn, forecasts where it will be at its reset, and can alert you at a threshold.',
        'It shows cost by project, model and day, priced at the rate in effect when each request was made, with CSV export.',
      ],
    },
  },
  {
    slug: 'token-pacer',
    name: 'Token Pacer',
    short: 'Token Pacer',
    url: TOKEN_PACER,
    sources: [{ label: 'tokenpacer.app', url: TOKEN_PACER }],
    cells: {
      form: t('Menu-bar app', TOKEN_PACER),
      native: unstated(TOKEN_PACER),
      liveLimits: part(TOKEN_PACER, 'provider-reported where available, else labelled estimates'),
      perModel: unstated(TOKEN_PACER),
      pace: part(TOKEN_PACER, 'pacing recommendations (Pro)'),
      projection: part(TOKEN_PACER, 'a weekly runway projection'),
      heatmap: unstated(TOKEN_PACER),
      breakdown: y(TOKEN_PACER),
      beyond: y(TOKEN_PACER, 'Codex, opencode'),
      widgets: unstated(TOKEN_PACER),
      notifications: y(TOKEN_PACER, 'Pro'),
      csv: y(TOKEN_PACER, 'Pro'),
      roi: unstated(TOKEN_PACER),
      plugins: unstated(TOKEN_PACER),
      price: t('Free mode; Pro $29 one-time (launch price)', TOKEN_PACER),
      license: unstated(TOKEN_PACER, 'no public repository found'),
      platforms: t('macOS 13 or newer', TOKEN_PACER),
    },
  },
  {
    slug: 'claude-god',
    name: 'Claude God',
    short: 'Claude God',
    url: CLAUDE_GOD,
    sources: [
      { label: 'claudegod.app', url: CLAUDE_GOD },
      { label: 'Claude God on GitHub', url: CLAUDE_GOD_REPO },
    ],
    cells: {
      form: t('Menu-bar app', CLAUDE_GOD),
      native: y(CLAUDE_GOD, 'SwiftUI'),
      liveLimits: y(CLAUDE_GOD),
      perModel: y(CLAUDE_GOD, 'Sonnet, Opus, Fable'),
      pace: part(CLAUDE_GOD, 'a burndown against even pace for Extra Usage'),
      projection: part(CLAUDE_GOD, 'a monthly forecast'),
      heatmap: y(CLAUDE_GOD),
      breakdown: y(CLAUDE_GOD),
      beyond: n(CLAUDE_GOD),
      widgets: y(CLAUDE_GOD),
      notifications: y(CLAUDE_GOD),
      csv: y(CLAUDE_GOD),
      roi: y(CLAUDE_GOD, 'cost per commit'),
      plugins: y(CLAUDE_GOD),
      price: t('Free', CLAUDE_GOD),
      license: t('MIT', CLAUDE_GOD_REPO),
      platforms: t('macOS 13 or newer', CLAUDE_GOD),
    },
  },
  {
    slug: 'ccseva',
    name: 'ccseva',
    short: 'ccseva',
    url: CCSEVA,
    sources: [{ label: 'ccseva on GitHub', url: CCSEVA }],
    cells: {
      form: t('Menu-bar app', CCSEVA),
      native: y(CCSEVA, 'Swift; the Electron app is legacy'),
      liveLimits: y(CCSEVA, 'with a local estimate as fallback'),
      perModel: n(CCSEVA, 'per-model cost only'),
      pace: n(CCSEVA, 'a predicted cutoff time instead'),
      projection: part(CCSEVA, 'end of each 5-hour window'),
      heatmap: unstated(CCSEVA),
      breakdown: y(CCSEVA),
      beyond: n(CCSEVA),
      widgets: unstated(CCSEVA),
      notifications: y(CCSEVA, 'at 70% and 90%'),
      csv: unstated(CCSEVA),
      roi: unstated(CCSEVA),
      plugins: unstated(CCSEVA),
      price: t('Free', CCSEVA),
      license: t('MIT', CCSEVA),
      platforms: t('macOS 14 or newer', CCSEVA),
    },
  },
];

/** The hub's columns: Pacer, then the tools with pages, then the rest. */
export const HUB: Tool[] = [PACER, ...TOOLS.filter((t) => t.page), ...TOOLS.filter((t) => !t.page)];

export const toolPages = () => TOOLS.filter((t): t is Tool & { page: ToolPage } => !!t.page);

/** How a mark reads, in a table cell and in Markdown. */
export const MARK_TEXT: Record<Mark, string> = {
  yes: '✓',
  no: '–',
  partial: 'Partly',
  unstated: 'Not stated',
  na: 'n/a',
};

/** A cell as text: the mark, then what it covers. */
export const cellText = (c: Cell) => (c.mark ? [MARK_TEXT[c.mark], c.text].filter(Boolean).join(c.mark === 'yes' || c.mark === 'no' ? ' ' : ': ') : (c.text ?? ''));

/**
 * Where Pacer counts differently from ccusage, on purpose (AGENTS.md, "Where
 * Pacer differs, on purpose"; ccusage's side from
 * docs/research/ccusage-reference.md, ccusage 18). Also the table on
 * /how-pacer-counts/.
 */
export const CCUSAGE_DIFFERENCES = [
  {
    what: 'Cache writes',
    ccusage: 'One number.',
    pacer: '5-minute and 1-hour writes kept apart.',
    why: 'Anthropic prices them differently.',
  },
  {
    what: 'Streamed replies',
    ccusage: 'Keeps the first copy of a reply.',
    pacer: 'Keeps the finished copy.',
    why: 'Claude Code writes a reply to its transcript several times while it streams, and only the last copy has the full output count. Keeping the first under-counted output by about 63% in the transcripts where this was found. When Pacer shows more output than ccusage, this is usually why.',
  },
  {
    what: 'Price',
    ccusage: "Today's price, for every day.",
    pacer: 'The price in effect when the request was made.',
    why: "A price change shouldn't rewrite what you already spent.",
  },
  {
    what: 'Long prompts',
    ccusage: 'Only the tokens above 200k at the higher rate.',
    pacer: 'The whole request at the higher rate once its prompt crosses the threshold.',
    why: 'That is how Anthropic bills it.',
  },
  {
    what: 'Data residency',
    ccusage: 'Not priced.',
    pacer: 'A multiplier on the standard rate (US-only routing, for example).',
    why: 'Anthropic documents it as one.',
  },
  {
    what: 'Claude Desktop',
    ccusage: 'Not read.',
    pacer: 'Its agent-mode sessions are counted too.',
    why: 'Desktop usage draws on the same limits.',
  },
  {
    what: 'Rate limits',
    ccusage: 'Estimated from your logs.',
    pacer: "Anthropic's own reading for your account.",
    why: 'Only Anthropic knows how full a window is.',
  },
];

/** The README's columns: Pacer and the tools its table has always had. The rest are on /compare/. */
export const README_COLUMNS = ['pacer', 'token-pacer', 'claude-god', 'ccseva', 'ccusage', 'claude-code-usage-command'];

/** A mark as the README's table shows it. */
const README_MARK: Record<Mark, string> = { yes: '✓', no: '–', partial: '◐', unstated: '?', na: 'n/a' };

/**
 * README.md's "How Pacer compares" table, from the same cells as the site
 * (test/compare.test.ts checks the README carries exactly this). Marks only:
 * the notes are on the site.
 */
export function readmeTable(): string {
  const tools = README_COLUMNS.map((slug) => HUB.find((t) => t.slug === slug)!);
  const head = (t: Tool) =>
    t.slug === 'pacer' ? '**Pacer**' : t.slug === 'claude-code-usage-command' ? '**CC `/usage`**' : `**[${t.name}](${t.url})**`;
  const cell = (c: Cell) => (c.mark ? README_MARK[c.mark] : (c.text ?? ''));
  return [
    `| | ${tools.map(head).join(' | ')} |`,
    `|---|${tools.map(() => ':---:').join('|')}|`,
    ...ROWS.map((r) => `| ${r.label} | ${tools.map((t) => cell(t.cells[r.key])).join(' | ')} |`),
  ].join('\n');
}
