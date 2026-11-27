// Builds dist/llms-full.txt (https://llmstxt.org): the text of every page as
// Markdown, converted from the built HTML so it can never drift from what the
// pages say. Then the discovery files made from the build (scripts/discovery.mjs;
// site/README.md, "Discovery for agents"): the Markdown twin of every page, the
// search index, the Agent Skills index with the skill (scripts/skill.mjs), the
// AI catalog (ai-catalog.json, ard.json), the API catalog and security.txt,
// and their _headers rules. Runs as an Astro integration after the build
// (astro.config.mjs). Adapted from room-planner's scripts/llms-full.mjs (adds
// <pre> blocks).
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  COMPARE_TOOL,
  MARKDOWN_PAGES,
  PATHS,
  agentSkillsIndex,
  aiCatalog,
  apiCatalog,
  markdownPath,
  searchPointers,
  securityTxt,
  skillIndexDescription,
} from './discovery.mjs';
import { buildSearchIndex } from './search.mjs';
import { frontMatter as skillFrontMatter, readSkill, sha256, skillArchive } from './skill.mjs';

/** Site paths in llms-full.txt, in order. The per-tool comparison pages follow /compare/. */
export const PAGES = ['', 'features/', 'cli/', 'how-pacer-counts/', 'claude-prices/', 'compare/', 'privacy/', 'faq/', 'changelog/'];

/** A `_headers` rule: a public discovery file, readable from anywhere, cached for an hour. */
const rule = (path, type, extra = []) => [
  path,
  `  Content-Type: ${type}`,
  '  Access-Control-Allow-Origin: *',
  '  Cache-Control: public, max-age=3600',
  ...extra,
  '',
];

/** `_headers` rules for the files this integration writes (appended to dist/_headers). */
const discoveryHeaders = (mdPaths, skillFiles) =>
  [
    '',
    '# Written by scripts/llms-full.mjs at build time: the Markdown twins of the pages and the',
    "# discovery files (scripts/discovery.mjs). The pages' Link headers come from the Worker",
    '# (worker/index.ts). None of these paths runs the Worker.',
    ...mdPaths.flatMap((p) => rule(p, 'text/markdown; charset=utf-8')),
    ...rule(PATHS.apiCatalog, 'application/linkset+json'),
    ...rule(PATHS.aiCatalog, 'application/ai-catalog+json'),
    ...rule(PATHS.ard, 'application/ai-catalog+json'),
    ...rule(PATHS.agentSkills, 'application/json'),
    ...rule(PATHS.skillArchive, 'application/gzip'),
    // The public copy of the price list: refreshed at most every six hours.
    ...rule(PATHS.priceList, 'application/json; charset=utf-8'),
    ...skillFiles.flatMap((f) =>
      rule(`${PATHS.skillDir}${f.name}`, f.name.endsWith('.md') ? 'text/markdown; charset=utf-8' : 'text/plain; charset=utf-8'),
    ),
    PATHS.searchIndex,
    '  Content-Type: application/json',
    '  Cache-Control: public, max-age=3600',
    '',
    PATHS.security,
    '  Content-Type: text/plain; charset=utf-8',
    '  Access-Control-Allow-Origin: *',
    '',
  ].join('\n');

/** YAML front matter for a Markdown twin: the Search for Agents pointers (`agent:`). */
const twinFrontMatter = (origin) => {
  const lines = Object.entries(searchPointers(origin)).map(([k, v]) => `  ${k}: ${JSON.stringify(v)}`);
  return `---\nagent:\n${lines.join('\n')}\n---\n\n`;
};

/** Write a file under dist, creating its directory. */
const write = (dist, path, data) => {
  mkdirSync(dirname(join(dist, path)), { recursive: true });
  writeFileSync(join(dist, path), data);
};
const writeJson = (dist, path, value) => write(dist, path, `${JSON.stringify(value, null, 2)}\n`);

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', '#39': "'" };
const decode = (s) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e) => {
    if (e[0] === '#') return String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : Number(e.slice(1)));
    return ENTITIES[e] ?? m;
  });

/**
 * Convert the `<main>` of one of this site's pages to Markdown. Not a general
 * converter: it knows the markup these pages use (headings, paragraphs, lists,
 * tables, links, code, inline emphasis).
 * @param {string} html
 * @param {string} origin e.g. `https://pacer.andrechek.com`
 */
export function htmlToMarkdown(html, origin) {
  let s = /<main\b[^>]*>([\s\S]*?)<\/main>/i.exec(html)?.[1] ?? '';
  // Code blocks keep their line breaks: park them before whitespace is collapsed.
  const blocks = [];
  s = s.replace(/<pre\b[^>]*>([\s\S]*?)<\/pre>/gi, (_, body) => {
    blocks.push(decode(body.replace(/<[^>]+>/g, '')).replace(/\n+$/, ''));
    return `\n\n@@PRE${blocks.length - 1}@@\n\n`;
  });
  s = s
    // Not content: anything marked data-llms="skip" (the hero's example chart), scripts,
    // drawings (their captions and labels say what they show), controls.
    .replace(/<(\w+)\b[^>]*\bdata-llms="skip"[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<(script|style|svg|button)\b[\s\S]*?<\/\1>/gi, '')
    .replace(/<picture\b[\s\S]*?<\/picture>/gi, '')
    .replace(/<span class="sr-only">[\s\S]*?<\/span>/gi, '')
    .replace(/\s+/g, ' ');

  s = s
    .replace(/<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, (_, href, text) => {
      const url = new URL(decode(href), `${origin}/`).toString();
      return `[${text.replace(/<[^>]+>/g, '').trim()}](${url})`;
    })
    .replace(/<(strong|b)\b[^>]*>([\s\S]*?)<\/\1>/gi, '**$2**')
    .replace(/<(em|i)\b[^>]*>([\s\S]*?)<\/\1>/gi, '*$2*')
    .replace(/<(code|kbd)\b[^>]*>([\s\S]*?)<\/\1>/gi, '`$2`')
    .replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi, (_, n, t) => `\n\n${'#'.repeat(+n)} ${t.replace(/<[^>]+>/g, '').trim()}\n\n`)
    .replace(/<caption\b[^>]*>([\s\S]*?)<\/caption>/gi, '\n\n$1\n\n')
    .replace(/<summary\b[^>]*>([\s\S]*?)<\/summary>/gi, '\n\n**$1**\n\n')
    // Tables: one Markdown row per <tr>; a separator after the header row.
    .replace(/<thead\b[^>]*>([\s\S]*?)<\/thead>/gi, (_, head) => {
      const cells = [...head.matchAll(/<th\b[^>]*>([\s\S]*?)<\/th>/gi)].map((m) => m[1].replace(/<[^>]+>/g, '').trim());
      return `\n| ${cells.join(' | ')} |\n|${cells.map(() => ' --- |').join('')}\n`;
    })
    .replace(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi, (_, row) => {
      const cells = [...row.matchAll(/<t[hd]\b[^>]*>([\s\S]*?)<\/t[hd]>/gi)].map((m) =>
        m[1].replace(/<[^>]+>/g, '').trim(),
      );
      return `| ${cells.join(' | ')} |\n`;
    })
    .replace(/<\/?table\b[^>]*>/gi, '\n')
    .replace(/<li\b[^>]*>/gi, '\n- ')
    .replace(/<\/(p|div|section|figure|figcaption|ul|ol|article|header|li|details|dd|dt)>/gi, '\n')
    .replace(/<(p|div|section|figure|figcaption|ul|ol|article|header|details|dd|dt)\b[^>]*>/gi, '\n')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, '');

  return decode(s)
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .join('\n')
    .replace(/(?<=\n- [^\n]*)\n\n(?=- )/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/@@PRE(\d+)@@/g, (_, i) => '```\n' + blocks[Number(i)] + '\n```')
    .trim();
}

/** A built page's HTML, or with `file` set, any file's bytes. */
const read = (dist, path, file = 'index.html') =>
  file === '' ? readFileSync(join(dist, path)) : readFileSync(join(dist, path, file), 'utf8');

/**
 * Every discovery file made from the build, written into `dist`.
 * @param {string} dist
 * @param {string} origin
 * @param {string[]} built site paths Astro built (`compare/ccusage/`, ...)
 * @param {Date} [now]
 */
export function writeDiscovery(dist, origin, built, now = new Date()) {
  const tools = built.filter((p) => COMPARE_TOOL.test(p)).sort();
  const order = PAGES.flatMap((p) => (p === 'compare/' ? [p, ...tools] : [p]));

  const sections = order.map((path) => `<!-- ${origin}/${path} -->\n\n${htmlToMarkdown(read(dist, path), origin)}`);
  const head =
    '# Pacer: the full text of pacer.andrechek.com\n\n' +
    `> Every page of ${origin}/ as Markdown, generated from the site at build time. ` +
    `Summary and links: ${origin}${PATHS.llms}\n`;
  writeFileSync(join(dist, 'llms-full.txt'), `${head}\n${sections.join('\n\n---\n\n')}\n`);

  // The Markdown twin of every page (the same converter). Their front matter
  // names the search endpoint, which searches their text.
  const mdPaths = [];
  const searchPages = [];
  for (const path of [...MARKDOWN_PAGES, ...tools]) {
    const md = markdownPath(path);
    if (!md) continue;
    const html = read(dist, path);
    const title = decode(/<title>([\s\S]*?)<\/title>/i.exec(html)?.[1]?.trim() ?? '');
    const body = htmlToMarkdown(html, origin);
    const text = body.startsWith('# ') ? body : `# ${title}\n\n${body}`;
    const source = `${origin}/${path}`;
    write(dist, md, `${twinFrontMatter(origin)}${text}\n\n---\n\nSource: ${source}\n`);
    mdPaths.push(md);
    searchPages.push({ url: source, title: /^# (.+)$/m.exec(text)?.[1]?.trim() ?? title, markdown: text });
  }
  writeJson(dist, PATHS.searchIndex, buildSearchIndex(searchPages));

  // The skill, byte for byte from ../Skills/pacer: each file, and the archive
  // the Agent Skills index lists with its digest.
  const skill = readSkill();
  for (const f of skill) write(dist, `${PATHS.skillDir}${f.name}`, f.bytes);
  const archive = skillArchive(skill);
  write(dist, PATHS.skillArchive, archive);
  const skillMd = skill.find((f) => f.name === 'SKILL.md').bytes;
  const { description } = skillFrontMatter(skillMd.toString('utf8'));
  writeJson(dist, PATHS.agentSkills, agentSkillsIndex({ description: skillIndexDescription(description), digest: sha256(archive) }));
  const catalog = aiCatalog(origin, { skillDescription: description, skillDigest: sha256(skillMd) });
  writeJson(dist, PATHS.aiCatalog, catalog);
  writeJson(dist, PATHS.ard, catalog);

  // The price list's public copy: the bytes Astro copied from public/ (which
  // check-feeds.mjs holds to public/ byte for byte), at a path that is a plain
  // static asset. scripts/check-discovery.mjs checks the two after the build.
  write(dist, PATHS.priceList, read(dist, PATHS.priceHistory.slice(1), ''));

  write(dist, PATHS.apiCatalog, `${JSON.stringify(apiCatalog(origin), null, 2)}\n`);
  write(dist, PATHS.security, securityTxt(origin, now));

  const headersFile = join(dist, '_headers');
  writeFileSync(headersFile, readFileSync(headersFile, 'utf8') + discoveryHeaders(mdPaths, skill));
  return { mdPaths, tools };
}

/** Astro integration: write dist/llms-full.txt and the discovery files after the build. */
export function llmsFull() {
  /** @type {string | undefined} */
  let site;
  return {
    name: 'llms-full',
    hooks: {
      /** @param {{ config: { site?: string } }} options */
      'astro:config:done': ({ config }) => {
        site = config.site;
      },
      /** @param {{ dir: URL, pages: { pathname: string }[] }} options */
      'astro:build:done': ({ dir, pages }) => {
        const origin = (site ?? 'http://localhost').replace(/\/+$/, '');
        writeDiscovery(
          fileURLToPath(dir),
          origin,
          pages.map((p) => p.pathname.replace(/^\/+/, '')),
        );
      },
    },
  };
}
