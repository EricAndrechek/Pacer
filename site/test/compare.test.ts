// How Pacer compares (src/lib/compare.ts): every other tool's cell carries the
// source it was read from, each per-tool page says something of its own, and
// the README's table is the site's.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { COMPARE_TOOL, COMPARE_TOOLS, markdownPath } from '../scripts/discovery.mjs';
import { CHECKED, HUB, PACER, ROWS, TOOLS, readmeTable, toolPages } from '../src/lib/compare';

describe('the facts', () => {
  it('every tool has every row, and every cell but Pacer’s has a source URL', () => {
    for (const tool of HUB) {
      expect(Object.keys(tool.cells).sort(), tool.slug).toEqual(ROWS.map((r) => r.key).sort());
      if (tool === PACER) continue;
      expect(tool.url, tool.slug).toMatch(/^https:\/\//);
      for (const row of ROWS) {
        const cell = tool.cells[row.key];
        expect(cell.source, `${tool.slug} ${row.key}`).toMatch(/^https:\/\/\S+$/);
        expect(cell.mark || cell.text, `${tool.slug} ${row.key}`).toBeTruthy();
      }
      expect(tool.sources.length, tool.slug).toBeGreaterThan(0);
      for (const s of tool.sources) expect(s.url, tool.slug).toMatch(/^https:\/\//);
    }
    // Pacer's own cells point at this site's pages.
    for (const row of ROWS) expect(PACER.cells[row.key].source, row.key).toMatch(/^\/[a-z-]*\/?$/);
  });

  it('a partly has a note saying what it covers, and the date checked is a day', () => {
    for (const tool of HUB) for (const row of ROWS) if (tool.cells[row.key].mark === 'partial') expect(tool.cells[row.key].text, `${tool.slug} ${row.key}`).toBeTruthy();
    expect(CHECKED).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('points at ccusage’s current repository', () => {
    const all = JSON.stringify(TOOLS);
    expect(all).not.toContain('ryoppippi');
    expect(all).toContain('https://github.com/ccusage/ccusage');
  });
});

describe('the per-tool pages', () => {
  const pages = toolPages();

  it('each has a twin path and its own words', () => {
    const seen = new Map<string, string>();
    for (const tool of pages) {
      expect(`compare/${tool.slug}/`).toMatch(COMPARE_TOOL);
      expect(markdownPath(`/compare/${tool.slug}/`)).toBe(`/compare/${tool.slug}.md`);
      expect(tool.page.betterPick.length, tool.slug).toBeGreaterThanOrEqual(2);
      expect(tool.page.pacerDiffers.length, tool.slug).toBeGreaterThanOrEqual(2);
      // No sentence repeated from another page: these are not one template with the name swapped.
      for (const line of [tool.page.what, tool.page.data, tool.page.description, ...tool.page.betterPick, ...tool.page.pacerDiffers]) {
        expect(seen.get(line), `${tool.slug}: "${line}" is also on ${seen.get(line)}`).toBeUndefined();
        seen.set(line, tool.slug);
      }
    }
    expect(pages.map((t) => t.slug).sort()).toEqual(['ccusage', 'claude-code-usage-command', 'claude-code-usage-monitor', 'claudebar', 'codexbar']);
    // The routes and twins are built from scripts/discovery.mjs's list: the two must agree.
    expect([...COMPARE_TOOLS].sort()).toEqual(pages.map((t) => t.slug).sort());
  });
});

describe('README.md', () => {
  const readme = readFileSync('../README.md', 'utf8');
  const section = readme.slice(readme.indexOf('## How Pacer compares'), readme.indexOf('## Privacy'));

  it('carries the site’s table, and points at the site for the rest', () => {
    expect(section).toContain(readmeTable());
    expect(section).toContain('https://pacer.andrechek.com/compare/');
    expect(section).toContain('November 2026');
    expect(section).not.toContain('ryoppippi');
  });
});
