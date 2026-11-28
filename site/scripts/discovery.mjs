// Discovery for agents (site/README.md, "Discovery for agents"): the one place
// that decides which pages have a Markdown twin, which routes run the Worker,
// and what the discovery files say: /.well-known/api-catalog, security.txt,
// the AI catalog (ai-catalog.json and ard.json), the Agent Skills index and
// the Search for Agents pointers. Used by the build (scripts/llms-full.mjs),
// the page head (src/layouts/Base.astro), robots.txt, llms.txt, the Worker and
// the tests, so the URLs in every file come from the same place. Ported from
// room-planner's scripts/discovery.mjs, without what a desktop app has no use
// for (an MCP server, a REST API, OAuth).
//
// Pure: no node: imports, because the Worker imports it too. What reads the
// repo (the skill's files) is scripts/skill.mjs.

export const REPO = 'https://github.com/EricAndrechek/Pacer';
export const BREW_COMMAND = 'brew install --cask ericandrechek/tap/pacer';

/**
 * Pages with a Markdown twin, as site paths without the leading slash. The
 * per-tool comparison pages (`compare/<tool>/`, COMPARE_TOOLS) have one too.
 */
export const MARKDOWN_PAGES = [
  '',
  'features/',
  'cli/',
  'how-pacer-counts/',
  'claude-prices/',
  'compare/',
  'privacy/',
  'faq/',
  'changelog/',
];

/** The shape of a per-tool comparison page's path: `compare/ccusage/`. */
export const COMPARE_TOOL = /^compare\/[a-z0-9]+(?:-[a-z0-9]+)*\/$/;

/**
 * The per-tool comparison pages, by slug: the pages src/lib/compare.ts gives
 * a `page` (test/compare.test.ts holds the two lists equal). Listed, not
 * matched by a pattern, so run_worker_first names each page and nothing else
 * under /compare/ runs the Worker.
 */
export const COMPARE_TOOLS = ['ccusage', 'claude-code-usage-command', 'claude-code-usage-monitor', 'claudebar', 'codexbar'];

/**
 * The Markdown twin of a page path (with or without the leading slash), or
 * null: `/faq/` -> `/faq.md`, `/` -> `/index.md`, `/compare/ccusage/` ->
 * `/compare/ccusage.md`. The same mapping as @wave-rf/cloudflare-md-router's
 * default, which serves them.
 * @param {string} path
 */
export function markdownPath(path) {
  const p = path.replace(/^\/+/, '');
  if (!MARKDOWN_PAGES.includes(p) && !COMPARE_TOOLS.some((t) => p === `compare/${t}/`)) return null;
  return p === '' ? '/index.md' : `/${p.replace(/\/$/, '')}.md`;
}

/**
 * Whether a request path is a page the Markdown router answers: a page with a
 * twin, nothing else. The update feed, the price history, /download and
 * /api/feedback never are (worker/index.ts handles them first anyway).
 * @param {string} pathname e.g. `/faq/`
 */
export function isPageRoute(pathname) {
  return pathname.startsWith('/') && markdownPath(pathname) !== null;
}

/** Discovery URLs, relative to the site. */
export const PATHS = {
  llms: '/llms.txt',
  llmsFull: '/llms-full.txt',
  apiCatalog: '/.well-known/api-catalog',
  aiCatalog: '/.well-known/ai-catalog.json',
  ard: '/.well-known/ard.json',
  agentSkills: '/.well-known/agent-skills/index.json',
  skillArchive: '/.well-known/agent-skills/pacer.tar.gz',
  /** The skill's files, one by one (SKILL.md links its siblings relatively). */
  skillDir: '/.well-known/agent-skills/pacer/',
  skill: '/.well-known/agent-skills/pacer/SKILL.md',
  search: '/.well-known/search',
  searchIndex: '/search-index.json',
  security: '/.well-known/security.txt',
  /** The app's copy of the price list: counted by the Worker, never advertised (see `priceList`). */
  priceHistory: '/price-history.json',
  /**
   * The public copy for everyone else: the same bytes, written at build time
   * (scripts/llms-full.mjs), a plain static asset that never runs the Worker,
   * so other readers neither use up the daily request limit the app's update
   * checks share nor show up in its feed_request counts.
   */
  priceList: '/claude-prices.json',
  priceSchema: '/price-history.schema.json',
  prices: '/claude-prices/',
  cli: '/cli/',
  compare: '/compare/',
  privacy: '/privacy/',
};

/**
 * The routes that run the Worker first (wrangler.jsonc `run_worker_first`,
 * checked by worker/index.test.ts). The first five are the Worker's own: the
 * update feed and the price history (counted, then served untouched),
 * /download and /api/feedback. Then the pages, for the Markdown router, and
 * the search endpoint. Every other path (assets, the twins, the other
 * /.well-known/ files) is a static asset and never runs Worker code.
 */
export const WORKER_ROUTES = ['/download', '/download/', '/api/feedback', '/appcast.xml', '/price-history.json'];
export const PAGE_ROUTES = [...MARKDOWN_PAGES.map((p) => `/${p}`), ...COMPARE_TOOLS.map((t) => `/compare/${t}/`)];
export const SEARCH_ROUTES = [PATHS.search];

/** RFC 9727's profile URI, for the API catalog's Content-Type. */
export const API_CATALOG_PROFILE = 'https://www.rfc-editor.org/info/rfc9727';

/**
 * Whether `pathname` runs the Worker first under a `run_worker_first` list:
 * a pattern matches it (`*` matches anything, `/` included) and no `!`
 * pattern does, as Cloudflare's static-assets routing reads the list.
 * @param {string[]} routes
 * @param {string} pathname
 */
export function runsWorkerFirst(routes, pathname) {
  const match = (pattern) =>
    new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`).test(pathname);
  return routes.some((r) => !r.startsWith('!') && match(r)) && !routes.some((r) => r.startsWith('!') && match(r.slice(1)));
}

/**
 * RFC 9727 API catalog (an RFC 9264 linkset). Pacer has one public API: the
 * dated Claude price list, /claude-prices.json (the same bytes the app reads
 * at /price-history.json), described by its JSON Schema and documented on
 * /claude-prices/. The update feed is a Sparkle appcast for the app, not an
 * API, and is left out, as is the app's own copy of the price list.
 * @param {string} origin e.g. `https://pacer.andrechek.com`
 */
export function apiCatalog(origin) {
  const u = (p) => `${origin}${p}`;
  return {
    linkset: [
      { anchor: u(PATHS.apiCatalog), item: [{ href: u(PATHS.priceList), type: 'application/json' }] },
      {
        anchor: u(PATHS.priceList),
        'service-desc': [{ href: u(PATHS.priceSchema), type: 'application/schema+json' }],
        'service-doc': [
          { href: u(PATHS.prices), type: 'text/html' },
          { href: u(markdownPath(PATHS.prices)), type: 'text/markdown' },
        ],
        'privacy-policy': [{ href: u(PATHS.privacy) }],
      },
    ],
  };
}

/**
 * RFC 9116 security.txt: GitHub's private vulnerability reporting (on for the
 * repo) and its issues. Expires a year after the build; each deploy renews it.
 * @param {string} origin
 * @param {Date} now
 */
export function securityTxt(origin, now = new Date()) {
  const expires = new Date(now.getTime() + 365 * 24 * 3600 * 1000);
  expires.setUTCHours(0, 0, 0, 0);
  return [
    `Contact: ${REPO}/security/advisories/new`,
    `Contact: ${REPO}/issues`,
    `Expires: ${expires.toISOString()}`,
    'Preferred-Languages: en',
    `Canonical: ${origin}${PATHS.security}`,
    '',
  ].join('\n');
}

/** Pages whose head and `Link` header carry the discovery pointers. */
export const API_POINTER_PAGES = ['', 'cli/', 'claude-prices/'];

/**
 * The discovery pointers of a page (RFC 8288 `Link` values, and the same as
 * `<link>`s in its head): llms.txt, the API catalog, the API's documentation,
 * the AI catalog (as `ard` and as `ai-catalog`) and, unless `twin: false`,
 * the page's Markdown twin (the Worker leaves that one to the Markdown router,
 * which adds it to every page).
 * @param {string} path e.g. `` or `cli/`
 * @param {{ twin?: boolean }} [options]
 */
export function pointerLinks(path, { twin = true } = {}) {
  const md = twin ? markdownPath(path) : null;
  return [
    { href: PATHS.llms, rel: 'describedby', type: 'text/plain' },
    { href: PATHS.apiCatalog, rel: 'api-catalog', type: 'application/linkset+json' },
    { href: PATHS.prices, rel: 'service-doc', type: 'text/html' },
    ...(md ? [{ href: md, rel: 'alternate', type: 'text/markdown' }] : []),
    { href: PATHS.ard, rel: 'ard', type: 'application/ai-catalog+json' },
    { href: PATHS.aiCatalog, rel: 'ai-catalog', type: 'application/ai-catalog+json' },
  ];
}

/**
 * The `Link` header for a page with the pointers.
 * @param {string} path
 * @param {{ twin?: boolean }} [options]
 */
export function linkHeader(path, options) {
  return pointerLinks(path, options)
    .map((l) => `<${l.href}>; rel="${l.rel}"; type="${l.type}"`)
    .join(', ');
}

/**
 * What the published skill needs, said where agents choose skills (the index
 * and the AI catalog): the skill's own description assumes Pacer is there,
 * because Pacer is what installs it. A copy installed by hand has no `pacer`
 * command beside it, and Pacer's installer leaves a directory it did not
 * write alone (ClaudeSkillInstaller, `.foreign`), so the way in is the app.
 */
export const SKILL_REQUIREMENT =
  `Needs Pacer, the free macOS menu-bar app (${BREW_COMMAND}); ` +
  "install the skill from Pacer's Settings, which links the pacer command beside it and updates it with the app.";

/**
 * The description agents see for the skill: its SKILL.md description, then
 * what it needs.
 * @param {string} skillDescription the `description:` of SKILL.md's front matter
 */
export const skillIndexDescription = (skillDescription) => `${skillDescription} ${SKILL_REQUIREMENT}`;

/**
 * Agent Skills discovery index (Cloudflare's Agent Skills Discovery RFC
 * v0.2.0). The skill has supporting files (reference.md, planning.md,
 * pacing.md, pace-guard.sh), which the RFC distributes as an archive; its
 * digest is the SHA-256 of the archive's bytes.
 * @param {{ description: string, digest: string }} skill
 */
export function agentSkillsIndex({ description, digest }) {
  return {
    $schema: 'https://schemas.agentskills.io/discovery/0.2.0/schema.json',
    skills: [{ name: 'pacer', type: 'archive', description, url: PATHS.skillArchive, digest }],
  };
}

/**
 * The AI Catalog (v0.9) whose entries are ARD (v0.91) entries: a display
 * name and representative queries each. Served at /.well-known/ai-catalog.json
 * and /.well-known/ard.json. Identifiers are `urn:air:<host>:pacer:<kind>`.
 * @param {string} origin
 * @param {{ skillDescription: string, skillDigest: string }} skill the SKILL.md digest
 */
export function aiCatalog(origin, { skillDescription, skillDigest }) {
  const host = new URL(origin).hostname;
  const id = (kind) => `urn:air:${host}:pacer:${kind}`;
  const u = (p) => `${origin}${p}`;
  return {
    specVersion: '0.9',
    host: {
      displayName: 'Pacer',
      identifier: host,
      documentationUrl: u(PATHS.cli),
      logoUrl: u('/apple-touch-icon.png'),
    },
    entries: [
      {
        identifier: id('llms'),
        displayName: 'Pacer llms.txt',
        type: 'text/plain',
        url: u(PATHS.llms),
        description:
          'What Pacer is (a free, open-source macOS menu-bar app that tracks Claude Code usage, cost and rate limits), and where everything for agents is.',
        tags: ['claude-code', 'rate-limits', 'usage-tracking', 'macos'],
        representativeQueries: [
          'how do I see my Claude Code rate limits in the menu bar',
          'track Claude Code token usage and cost on a Mac',
          'will I hit my Claude Code limit before it resets',
        ],
      },
      {
        identifier: id('docs'),
        displayName: 'Pacer documentation (full text)',
        type: 'text/plain',
        url: u(PATHS.llmsFull),
        description: "Every page of Pacer's site as Markdown in one file: features, the pacer command, how it counts, prices, comparisons, privacy, FAQ, changelog.",
        tags: ['claude-code', 'documentation'],
        representativeQueries: [
          'what does the pacer command do',
          'why do Pacer and ccusage show different numbers',
        ],
      },
      {
        identifier: id('skill'),
        displayName: 'Pacer skill for Claude Code',
        type: 'application/agent-skills+md',
        url: u(PATHS.skill),
        description: skillIndexDescription(skillDescription),
        digest: skillDigest,
        tags: ['claude-code', 'rate-limits', 'agents', 'subagents'],
        representativeQueries: [
          'pause my agents before a Claude Code rate limit and resume after',
          'gate a fan-out of subagents on usage',
          'how much Claude Code usage is left',
        ],
      },
      {
        identifier: id('api-catalog'),
        displayName: 'Pacer API catalog',
        type: 'application/linkset+json',
        url: u(PATHS.apiCatalog),
        description: "RFC 9727 catalog of Pacer's one public API, the Claude price history.",
        tags: ['api-catalog'],
        representativeQueries: ['what APIs does pacer.andrechek.com offer', 'Claude price list API'],
      },
      {
        identifier: id('price-history'),
        displayName: 'Claude price history',
        type: 'application/json',
        url: u(PATHS.priceList),
        description: `Dated per-million-token prices for every Claude model (input, output, cache reads, 5-minute and 1-hour cache writes, long-context tiers), as Pacer prices usage. Public, no key, CORS open, refreshed every 6 hours. JSON Schema: ${u(PATHS.priceSchema)}. Documentation: ${u(PATHS.prices)}.`,
        tags: ['claude', 'pricing', 'anthropic-api', 'json'],
        capabilities: ['GET'],
        representativeQueries: [
          'current Claude API price per million tokens',
          'when did the Claude Sonnet price change',
          'Claude cache write price 1 hour vs 5 minutes',
        ],
      },
    ],
  };
}

/**
 * Search for Agents (developers.cloudflare.com/ai-search/how-to/search-for-agents/):
 * the pointers every page carries, as `<meta name="agent:...">` in its HTML
 * and an `agent:` block in its Markdown twin's front matter. The endpoint is
 * the Worker's (worker/search.ts).
 * @param {string} origin
 */
export function searchPointers(origin) {
  return {
    instructions:
      'Use this search API to find relevant content across this site with keywords or natural-language queries, instead of crawling individual pages. Results are returned in Markdown.',
    endpoint: `${origin}${PATHS.search}?q={query}`,
    method: 'GET',
    documentation: 'https://developers.cloudflare.com/ai-search/how-to/search-for-agents/',
  };
}
