import type { APIRoute } from 'astro';
import { FAQ } from '../lib/faq';
import {
  BREW_COMMAND,
  DEFAULT_DESCRIPTION,
  FEATURES,
  LATEST_RELEASE,
  REPO,
  REQUIREMENTS,
  SITE_NAME,
  VERSION,
} from '../lib/site';

/**
 * llms.txt (https://llmstxt.org): what Pacer is and where the site's content
 * lives, for AI assistants and answer engines. Built from the same constants
 * as the pages; the full text of every page is /llms-full.txt
 * (scripts/llms-full.mjs).
 */
export const GET: APIRoute = ({ site }) => {
  const url = (path: string) => new URL(path, site ?? 'http://localhost').toString();

  const body = `# ${SITE_NAME}

> ${SITE_NAME} (${url('/')}) is a free, open-source (MIT) native macOS menu-bar app that tracks Claude Code usage: tokens, cost, and how close you are to your 5-hour, weekly and per-model rate limits. Usage data stays on the user's Mac.

${DEFAULT_DESCRIPTION}

Key facts:

- Current version: ${VERSION}. Download: ${url('/download/')} (the latest DMG; release page: ${LATEST_RELEASE}). Homebrew: \`${BREW_COMMAND}\`.
- Requires ${REQUIREMENTS}. Signed, notarized, and updates itself.
- Price: free. Source: ${REPO}.
- Data: Pacer reads Claude Code's own transcript files on the Mac and uses the Claude Code login only to ask Anthropic for rate limits. It sends crash reports (Sentry) and anonymous usage stats (PostHog), never prompts, projects, files, accounts or costs; each can be turned off in Settings → Privacy.
- Not affiliated with or endorsed by Anthropic.

Features:

${FEATURES.map((f) => `- ${f}`).join('\n')}

## Pages

- [Home](${url('/')}): what Pacer is, screenshots, download.
- [Features](${url('/features/')}): everything the app does.
- [For agents: the pacer command and Claude Code skill](${url('/cli/')}): gate, status, wait and report; gate-only and informed pacing.
- [How Pacer counts](${url('/how-pacer-counts/')}): where the numbers come from, and why they differ from ccusage.
- [Privacy](${url('/privacy/')}): what the app sends, the two toggles, and the site's cookieless analytics.
- [FAQ](${url('/faq/')}): ${FAQ.map((f) => f.q.replace(/\?$/, '').toLowerCase()).join('; ')}.
- [Changelog](${url('/changelog/')}): every release's notes.

## Optional

- [Full text of every page](${url('/llms-full.txt')}): the pages above as Markdown, in one file.
- [Source code and README](${REPO}).
`;
  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
