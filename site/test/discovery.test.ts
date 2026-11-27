// Discovery for agents (site/README.md, "Discovery for agents"): every file an
// agent or crawler may look for, made by the same code the build runs
// (scripts/llms-full.mjs's writeDiscovery, over a stand-in dist/ with one
// small HTML file per page), parsed, and checked against each other and
// against the routes, so the URLs, digests and descriptions agree everywhere.
// room-planner checks the same things in an e2e against a running server;
// this runs in `pnpm test`, before the build.
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  API_POINTER_PAGES,
  BREW_COMMAND,
  COMPARE_TOOL,
  MARKDOWN_PAGES,
  PAGE_ROUTES,
  PATHS,
  REPO,
  SKILL_REQUIREMENT,
  isPageRoute,
  linkHeader,
  runsWorkerFirst,
  markdownPath,
  pointerLinks,
} from '../scripts/discovery.mjs';
import { PAGES as LLMS_FULL_PAGES, writeDiscovery } from '../scripts/llms-full.mjs';
import { frontMatter, readSkill, sha256, untar } from '../scripts/skill.mjs';
import { toolPages } from '../src/lib/compare';
import { GET as robotsTxt } from '../src/pages/robots.txt';
import { GET as llmsTxt } from '../src/pages/llms.txt';
import { BREW_COMMAND as SITE_BREW, REPO as SITE_REPO } from '../src/lib/site';

const ORIGIN = 'https://pacer.andrechek.com';
const NOW = new Date('2026-11-27T12:00:00Z');
const TOOLS = toolPages().map((t) => `compare/${t.slug}/`);
const ALL_PAGES = [...MARKDOWN_PAGES, ...TOOLS];

let dist = '';
const read = (path: string) => readFileSync(join(dist, path));
const text = (path: string) => read(path).toString('utf8');
const json = (path: string) => JSON.parse(text(path));
/** A site path that the build serves: written here, or in public/ (copied into dist by Astro), or an Astro route. */
const ASTRO_ROUTES = ['/llms.txt', '/robots.txt', '/sitemap-index.xml'];
const served = (path: string) =>
  existsSync(join(dist, path)) ||
  existsSync(join('public', path)) ||
  ASTRO_ROUTES.includes(path) ||
  ALL_PAGES.some((p) => `/${p}` === path);

beforeAll(() => {
  dist = mkdtempSync(join(tmpdir(), 'pacer-discovery-'));
  for (const page of ALL_PAGES) {
    mkdirSync(join(dist, page), { recursive: true });
    const heading = page === '' ? 'Pacer' : page.replace(/\/$/, '');
    writeFileSync(
      join(dist, page, 'index.html'),
      `<!doctype html><title>${heading} | Pacer</title><main><h1>${heading}</h1><p>About ${heading}.</p><h2>Rate limits</h2><p>Every window paced.</p></main>`,
    );
  }
  writeFileSync(join(dist, '_headers'), "/*\n  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'\n");
  // Astro copies public/ into dist/ before the integration runs.
  writeFileSync(join(dist, 'price-history.json'), readFileSync('public/price-history.json'));
  writeDiscovery(dist, ORIGIN, ALL_PAGES, NOW);
});
afterAll(() => rmSync(dist, { recursive: true, force: true }));

describe('pages, twins and routes', () => {
  it('every page in src/pages has a Markdown twin, and every twin a page', () => {
    const astro = readdirSync('src/pages')
      .filter((f) => f.endsWith('.astro') && f !== '404.astro')
      .map((f) => (f === 'index.astro' ? '' : `${f.replace(/\.astro$/, '')}/`));
    const dirs = readdirSync('src/pages', { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith('.') && existsSync(join('src/pages', d.name, 'index.astro')))
      .map((d) => `${d.name}/`);
    expect([...astro, ...dirs].sort()).toEqual([...MARKDOWN_PAGES].sort());
    for (const page of TOOLS) expect(page).toMatch(COMPARE_TOOL);
    expect([...LLMS_FULL_PAGES].sort()).toEqual([...MARKDOWN_PAGES].sort());
  });

  it('every page with a twin runs the Worker first, and nothing else does but the Worker routes and search', () => {
    const covered = (path: string) =>
      PAGE_ROUTES.includes(path) || (path.startsWith('/compare/') && !path.endsWith('.md') && PAGE_ROUTES.includes('/compare/*'));
    for (const page of ALL_PAGES) {
      expect(covered(`/${page}`), page).toBe(true);
      expect(isPageRoute(`/${page}`), page).toBe(true);
    }
    for (const path of ['/404/', '/appcast.xml', '/price-history.json', '/download/', '/api/feedback', '/faq.md', '/llms.txt']) {
      expect(isPageRoute(path), path).toBe(false);
    }
  });

  it('writes each twin with the Search for Agents front matter, the page and its source', () => {
    for (const page of ALL_PAGES) {
      const md = markdownPath(page)!;
      const body = text(md);
      expect(body, md).toMatch(/^---\nagent:\n( {2}\w+: "[^"\n]*"\n){4}---\n\n# /);
      expect(body, md).toContain(`  endpoint: "${ORIGIN}${PATHS.search}?q={query}"`);
      expect(body, md).toContain(`Source: ${ORIGIN}/${page}`);
    }
    expect(markdownPath('')).toBe('/index.md');
    expect(markdownPath('/compare/ccusage/')).toBe('/compare/ccusage.md');
    expect(markdownPath('/404/')).toBeNull();
  });

  it('indexes every page for search, and writes llms-full.txt with all of them', () => {
    const index = json(PATHS.searchIndex);
    const urls = new Set(index.docs.map((d: { u: string }) => d.u));
    for (const page of ALL_PAGES) expect(urls.has(`${ORIGIN}/${page}`), page).toBe(true);
    const full = text('llms-full.txt');
    for (const page of ALL_PAGES) expect(full, page).toContain(`<!-- ${ORIGIN}/${page} -->`);
  });

  it('gives every file it writes a _headers rule with its type, CORS where public', () => {
    const headers = text('_headers');
    for (const page of ALL_PAGES) expect(headers).toContain(`${markdownPath(page)}\n  Content-Type: text/markdown; charset=utf-8`);
    for (const [path, type] of [
      [PATHS.apiCatalog, 'application/linkset+json'],
      [PATHS.aiCatalog, 'application/ai-catalog+json'],
      [PATHS.ard, 'application/ai-catalog+json'],
      [PATHS.agentSkills, 'application/json'],
      [PATHS.skillArchive, 'application/gzip'],
      [PATHS.skill, 'text/markdown; charset=utf-8'],
      [PATHS.security, 'text/plain; charset=utf-8'],
      [PATHS.searchIndex, 'application/json'],
    ]) {
      expect(headers, path).toContain(`${path}\n  Content-Type: ${type}`);
    }
    // The CSP line is still the first and only one, so csp-hashes.mjs still finds it.
    expect(headers.match(/Content-Security-Policy:/g)).toHaveLength(1);
  });
});

describe('the Agent Skill', () => {
  const skill = readSkill();
  const skillMd = skill.find((f) => f.name === 'SKILL.md')!;
  const own = frontMatter(skillMd.bytes.toString('utf8'));

  it('publishes the repo skill byte for byte, file by file and as the archive the index lists', () => {
    for (const f of skill) expect(read(`${PATHS.skillDir}${f.name}`).equals(f.bytes), f.name).toBe(true);
    const index = json(PATHS.agentSkills);
    expect(index.$schema).toBe('https://schemas.agentskills.io/discovery/0.2.0/schema.json');
    expect(index.skills).toHaveLength(1);
    const [entry] = index.skills;
    expect(entry).toMatchObject({ name: 'pacer', type: 'archive', url: PATHS.skillArchive });
    const archive = read(entry.url);
    expect(entry.digest).toBe(sha256(archive));
    expect(entry.digest).toMatch(/^sha256:[0-9a-f]{64}$/);
    const files = untar(gunzipSync(archive));
    expect(files.map((f) => f.name)).toEqual(skill.map((f) => f.name));
    for (const [i, f] of files.entries()) {
      expect(f.bytes.equals(skill[i]!.bytes), f.name).toBe(true);
      expect(f.mode, f.name).toBe(f.name.endsWith('.sh') ? 0o755 : 0o644);
    }
  });

  it('names it as SKILL.md does, links every file SKILL.md links, and says what it needs', () => {
    const [entry] = json(PATHS.agentSkills).skills;
    expect(own.name).toBe('pacer');
    expect(entry.name).toBe(own.name);
    expect(entry.name).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$/);
    // The skill's own description, then what it needs: the app, and how to install it.
    expect(entry.description).toBe(`${own.description} ${SKILL_REQUIREMENT}`);
    expect(entry.description).toContain(BREW_COMMAND);
    expect(entry.description.length).toBeLessThanOrEqual(1024);
    const linked = [...skillMd.bytes.toString('utf8').matchAll(/\]\(([\w.-]+\.(?:md|sh))\)/g)].map((m) => m[1]!);
    expect(linked.length).toBeGreaterThan(0);
    for (const name of linked) expect(skill.map((f) => f.name), name).toContain(name);
  });

  it('holds nothing private', () => {
    for (const f of skill) {
      const body = f.bytes.toString('utf8');
      expect(body, f.name).not.toMatch(/\/Users\/(?!…)[A-Za-z]/);
      // An email address; a git remote's `git@github.com` is not one.
      expect(body.replaceAll('git@github.com', ''), f.name).not.toMatch(/[\w.+-]+@[\w-]+\.[a-z]{2,}/i);
    }
  });
});

describe('the catalogs', () => {
  it('serves one AI catalog at ai-catalog.json and ard.json, whose entries all resolve', () => {
    const catalog = text(PATHS.aiCatalog);
    expect(text(PATHS.ard)).toBe(catalog);
    const { specVersion, host, entries } = JSON.parse(catalog);
    expect(specVersion).toBe('0.9');
    expect(host).toMatchObject({ displayName: 'Pacer', identifier: 'pacer.andrechek.com' });
    expect(served(new URL(host.logoUrl).pathname)).toBe(true);
    const ids = entries.map((e: { identifier: string }) => e.identifier);
    expect(new Set(ids).size).toBe(ids.length);
    for (const e of entries) {
      expect(e.identifier).toMatch(/^urn:air:pacer\.andrechek\.com:pacer:[a-z-]+$/);
      expect(new URL(e.url).origin).toBe(ORIGIN);
      expect(served(new URL(e.url).pathname), e.url).toBe(true);
      expect(e.representativeQueries.length).toBeGreaterThanOrEqual(2);
      expect(e.representativeQueries.length).toBeLessThanOrEqual(5);
    }
    const byId = Object.fromEntries(entries.map((e: { identifier: string }) => [e.identifier.split(':').at(-1), e]));
    expect(Object.keys(byId).sort()).toEqual(['api-catalog', 'docs', 'llms', 'price-history', 'skill']);
    // The skill entry points at SKILL.md, with that file's digest.
    expect(byId.skill.url).toBe(`${ORIGIN}${PATHS.skill}`);
    expect(byId.skill.digest).toBe(sha256(read(PATHS.skill)));
    expect(byId.skill.description).toBe(json(PATHS.agentSkills).skills[0].description);
    expect(byId['price-history'].url).toBe(`${ORIGIN}${PATHS.priceList}`);
  });

  it('lists the price history in the API catalog (RFC 9727), with its schema and documentation', () => {
    const { linkset } = json(PATHS.apiCatalog);
    const byAnchor = Object.fromEntries(linkset.map((l: { anchor: string }) => [l.anchor, l]));
    expect(byAnchor[`${ORIGIN}${PATHS.apiCatalog}`].item).toEqual([{ href: `${ORIGIN}${PATHS.priceList}`, type: 'application/json' }]);
    const api = byAnchor[`${ORIGIN}${PATHS.priceList}`];
    expect(api['service-desc']).toEqual([{ href: `${ORIGIN}${PATHS.priceSchema}`, type: 'application/schema+json' }]);
    expect(api['service-doc'].map((d: { href: string }) => d.href)).toEqual([`${ORIGIN}/claude-prices/`, `${ORIGIN}/claude-prices.md`]);
    for (const l of linkset) {
      for (const [rel, v] of Object.entries(l)) {
        if (rel === 'anchor') continue;
        for (const { href } of v as { href: string }[]) expect(served(new URL(href).pathname), href).toBe(true);
      }
    }
    // The update feed is the app's, not an API.
    expect(JSON.stringify(linkset)).not.toContain('appcast');
  });

  it('publishes the price list at its own static path: the app\'s bytes, never routed to the Worker, and the only copy advertised', () => {
    expect(read(PATHS.priceList).equals(readFileSync('public/price-history.json'))).toBe(true);
    expect(read(PATHS.priceList).equals(read(PATHS.priceHistory))).toBe(true);
    const runFirst = /"run_worker_first":\s*\[([^\]]*)\]/.exec(readFileSync('wrangler.jsonc', 'utf8'))?.[1] ?? '';
    const routes = [...runFirst.matchAll(/"([^"]+)"/g)].map((m) => m[1]!);
    expect(runsWorkerFirst(routes, PATHS.priceList)).toBe(false);
    expect(runsWorkerFirst(routes, PATHS.priceHistory)).toBe(true); // the app's, counted
    expect(isPageRoute(PATHS.priceList)).toBe(false);
    expect(text('_headers')).toContain(
      `${PATHS.priceList}\n  Content-Type: application/json; charset=utf-8\n  Access-Control-Allow-Origin: *\n  Cache-Control: public, max-age=3600`,
    );
    // The app's path is not offered to anyone else.
    for (const path of [PATHS.apiCatalog, PATHS.aiCatalog]) expect(text(path), path).not.toContain(PATHS.priceHistory);
  });

  it('writes security.txt (RFC 9116) with GitHub contacts, a future expiry and its canonical URL', () => {
    const body = text(PATHS.security);
    expect(body).toContain(`Contact: ${REPO}/security/advisories/new`);
    expect(body).toContain(`Contact: ${REPO}/issues`);
    expect(Date.parse(/^Expires: (.+)$/m.exec(body)![1]!)).toBeGreaterThan(NOW.getTime());
    expect(body).toContain(`Canonical: ${ORIGIN}${PATHS.security}`);
    expect(body).toMatch(/^Preferred-Languages: en$/m);
    expect(body).not.toMatch(/@/);
  });

  it('publishes no OAuth or sign-in metadata: Pacer has no API that needs it', () => {
    for (const path of [
      '/.well-known/oauth-protected-resource',
      '/.well-known/oauth-authorization-server',
      '/.well-known/openid-configuration',
      '/.well-known/mcp/server-card.json',
      '/auth.md',
    ]) {
      expect(served(path), path).toBe(false);
      expect(isPageRoute(path), path).toBe(false);
    }
  });
});

describe('pointers', () => {
  it('/, /cli/ and /claude-prices/ point at llms.txt, the catalogs, the API docs and their twin', () => {
    expect(API_POINTER_PAGES).toEqual(['', 'cli/', 'claude-prices/']);
    for (const page of API_POINTER_PAGES) {
      const links = pointerLinks(page);
      expect(links.map((l) => l.rel).sort()).toEqual(['ai-catalog', 'alternate', 'api-catalog', 'ard', 'describedby', 'service-doc']);
      for (const l of links) expect(served(l.href), l.href).toBe(true);
      expect(linkHeader(page)).toContain(`<${markdownPath(page)}>; rel="alternate"; type="text/markdown"`);
      expect(linkHeader(page, { twin: false })).not.toContain('text/markdown');
    }
  });

  it('robots.txt allows every crawler with the content signals, keeps /download out, and names the AI catalog', async () => {
    const body = await (await robotsTxt({ site: new URL(ORIGIN) } as never)).text();
    expect(body).toMatch(/^User-agent: \*$/m);
    expect(body).toMatch(/^Content-Signal: search=yes, ai-input=yes, ai-train=yes$/m);
    expect(body).toMatch(/^Allow: \/$/m);
    expect(body).toMatch(/^Disallow: \/download\/$/m);
    expect(body).toMatch(/^Disallow: \/download$/m);
    expect(body).toContain(`Sitemap: ${ORIGIN}/sitemap-index.xml`);
    expect(body).toMatch(new RegExp(`^Agentmap: ${ORIGIN}${PATHS.ard}$`, 'm'));
    expect(body).toContain(`${ORIGIN}${PATHS.llms}`);
  });

  it('llms.txt follows llmstxt.org and links the skill, the API, every twin and every comparison', async () => {
    const body = await (await llmsTxt({ site: new URL(ORIGIN) } as never)).text();
    expect(body).toMatch(/^# Pacer\n\n> /);
    expect(body).toContain('## Use Pacer from an agent');
    const links = new Set([...body.matchAll(/\]\((https?:\/\/[^)\s]+)\)/g)].map((m) => m[1]!));
    for (const path of [PATHS.skill, PATHS.agentSkills, PATHS.priceList, PATHS.priceSchema, PATHS.prices, PATHS.apiCatalog, PATHS.aiCatalog, PATHS.llmsFull]) {
      expect(links, path).toContain(`${ORIGIN}${path}`);
    }
    for (const page of ALL_PAGES) {
      expect(links, page).toContain(`${ORIGIN}/${page}`);
      expect(links, page).toContain(`${ORIGIN}${markdownPath(page)}`);
    }
    for (const href of links) if (new URL(href).origin === ORIGIN) expect(served(new URL(href).pathname), href).toBe(true);
    expect(body).toContain(BREW_COMMAND);
    expect(body).not.toContain(PATHS.priceHistory);
  });

  it('the site and the discovery files share one repository and Homebrew command', () => {
    expect(SITE_BREW).toBe(BREW_COMMAND);
    expect(SITE_REPO).toBe(REPO);
  });
});
