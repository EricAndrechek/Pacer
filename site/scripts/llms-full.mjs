// Builds dist/llms-full.txt (https://llmstxt.org): the text of every page as
// Markdown, converted from the built HTML so it can never drift from what the
// pages say. Runs as an Astro integration after the build (astro.config.mjs).
// Adapted from room-planner's scripts/llms-full.mjs (adds <pre> blocks).
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Site paths included, in order. */
export const PAGES = ['', 'features/', 'cli/', 'how-pacer-counts/', 'privacy/', 'faq/', 'changelog/'];

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

const read = (dist, path) => readFileSync(join(dist, path, 'index.html'), 'utf8');

/** Astro integration: write dist/llms-full.txt after the build. */
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
      /** @param {{ dir: URL }} options */
      'astro:build:done': ({ dir }) => {
        const dist = fileURLToPath(dir);
        const origin = (site ?? 'http://localhost').replace(/\/+$/, '');
        const sections = PAGES.map((path) => `<!-- ${origin}/${path} -->\n\n${htmlToMarkdown(read(dist, path), origin)}`);
        const head =
          '# Pacer: the full text of pacer.andrechek.com\n\n' +
          `> Every page of ${origin}/ as Markdown, generated from the site at build time. ` +
          `Summary and links: ${origin}/llms.txt\n`;
        writeFileSync(join(dist, 'llms-full.txt'), `${head}\n${sections.join('\n\n---\n\n')}\n`);
      },
    },
  };
}
