// Pacer's release notes, read from the repo's docs/release-notes/*.md at build
// time. The same files become the GitHub release text, so the changelog page
// and the version the site names can't disagree with a release.
import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { Marked } from 'marked';

// site/ is the working directory of every build (`pnpm build` runs there).
const NOTES_DIR = resolve(process.cwd(), '..', 'docs', 'release-notes');
// The update feed this site serves (bin/publish-feeds.sh writes it at release).
const APPCAST = resolve(process.cwd(), 'public', 'appcast.xml');

/**
 * The versions the update feed offers. Release notes land on main before the
 * tag (they become the GitHub release text), so a notes file alone doesn't
 * mean the version is out; the feed does. A release pulled from the feed
 * drops off the changelog too. Null (list every notes file) only if the feed
 * can't be read, so a missing file never empties the page.
 */
function offeredVersions(): Set<string> | null {
  try {
    const xml = readFileSync(APPCAST, 'utf8');
    const versions = [...xml.matchAll(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/g)].map(
      (m) => m[1].trim(),
    );
    return versions.length ? new Set(versions) : null;
  } catch {
    return null;
  }
}

export interface Release {
  version: string;
  /** Publish day (UTC, YYYY-MM-DD) from the release tag, when git can tell. */
  date: string | null;
  /** The notes' first paragraph, as plain text. */
  summary: string;
  /** The notes as HTML, headings demoted one level so each release sits under its own h2. */
  html: string;
}

const parse = (v: string) => v.split('.').map(Number);
export function compareVersions(a: string, b: string): number {
  const [x, y] = [parse(a), parse(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d) return d;
  }
  return 0;
}

function git(args: string[]): string | null {
  try {
    return execFileSync('git', args, { cwd: NOTES_DIR, stdio: ['ignore', 'pipe', 'ignore'] })
      .toString()
      .trim();
  } catch {
    return null;
  }
}

/** A shallow clone has no tags and dates everything to one commit, so dates are left out. */
const shallow = git(['rev-parse', '--is-shallow-repository']) !== 'false';

function releaseDate(version: string): string | null {
  if (shallow) return null;
  // The tag's own date (annotated) or its commit's (lightweight).
  const tagged = git(['for-each-ref', `refs/tags/v${version}`, '--format=%(creatordate:iso-strict)']);
  if (!tagged) return null;
  return new Date(tagged).toISOString().slice(0, 10);
}

const marked = new Marked({
  gfm: true,
  walkTokens(token) {
    if (token.type === 'heading') token.depth = Math.min(token.depth + 1, 6);
  },
});

const plain = (md: string) =>
  md
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();

let cached: Release[] | undefined;

/** Every released version (one the update feed offers), newest first. */
export function releases(): Release[] {
  if (cached) return cached;
  const offered = offeredVersions();
  cached = readdirSync(NOTES_DIR)
    .filter((f) => /^\d+\.\d+\.\d+\.md$/.test(f))
    .filter((f) => !offered || offered.has(f.replace(/\.md$/, '')))
    .map((f) => {
      const version = f.replace(/\.md$/, '');
      const md = readFileSync(join(NOTES_DIR, f), 'utf8').trim();
      const summary = plain(md.split(/\n\s*\n/)[0] ?? '');
      return { version, date: releaseDate(version), summary, html: marked.parse(md) as string };
    })
    .sort((a, b) => compareVersions(b.version, a.version));
  return cached;
}

/** The newest version with release notes: what the site calls the current version. */
export function latestVersion(): string {
  const latest = releases()[0];
  if (!latest) throw new Error(`No release notes found in ${NOTES_DIR}`);
  return latest.version;
}
