// When each page's content last changed: the newest commit touching its
// source files (git committer date), or the build time when git can't tell
// (no checkout, a shallow clone, or an uncommitted new file). Used for the
// sitemap's <lastmod> (astro.config.mjs), which scripts/indexnow.mjs reads.
// Copied from room-planner's approach.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

// site/. Not derived from import.meta.url: Astro bundles this file into its build output.
const root = process.cwd();
const buildTime = new Date();

/** Every page shares the layout and the site constants. */
const SHARED = ['src/layouts/Base.astro', 'src/lib/site.ts'];

/** Files outside the page itself whose edits change what the page says. */
const EXTRA_SOURCES = {
  '/': ['src/components/PaceChart.astro', '../docs/screenshots'],
  '/features/': ['../docs/screenshots'],
  '/faq/': ['src/lib/faq.ts'],
  '/changelog/': ['src/lib/releases.ts', '../docs/release-notes'],
  '/how-pacer-counts/': ['src/lib/compare.ts'],
  // Redeployed by every catalog sync commit that moves a price.
  '/claude-prices/': ['src/lib/prices.ts', 'public/price-history.json'],
  '/compare/': ['src/lib/compare.ts'],
};

/** The per-tool comparison pages share one template and one data file. */
const COMPARE_TOOL_SOURCES = ['src/pages/compare/[tool].astro', 'src/lib/compare.ts'];

/** Repo-relative (to site/) source files for a site path such as `/faq/`. */
export function sourcesFor(pathname) {
  const path = pathname.replace(/^\/+|\/+$/g, '');
  const candidates = path
    ? [`src/pages/${path}.astro`, `src/pages/${path}/index.astro`]
    : ['src/pages/index.astro'];
  const extra = EXTRA_SOURCES[`/${path}${path ? '/' : ''}`] ?? (/^compare\/[^/]+$/.test(path) ? COMPARE_TOOL_SOURCES : []);
  return [...candidates, ...extra, ...SHARED].filter((f) => existsSync(`${root}/${f}`));
}

function git(args) {
  return execFileSync('git', args, { cwd: root, stdio: ['ignore', 'pipe', 'ignore'] })
    .toString()
    .trim();
}

let shallow;
/** A shallow clone dates every file to its one commit, which would be wrong, not just coarse. */
export function isShallow() {
  if (shallow === undefined) {
    try {
      shallow = git(['rev-parse', '--is-shallow-repository']) === 'true';
    } catch {
      shallow = true; // not a git checkout: nothing to read either way
    }
  }
  return shallow;
}

const cache = new Map();

/** Last content change of the page at `pathname`. */
export function lastModified(pathname) {
  if (cache.has(pathname)) return cache.get(pathname);
  let date = buildTime;
  const files = sourcesFor(pathname);
  if (files.length && !isShallow()) {
    try {
      const out = git(['log', '-1', '--format=%cI', '--', ...files]);
      if (out) date = new Date(out);
    } catch {
      /* keep the build time */
    }
  }
  cache.set(pathname, date);
  return date;
}
