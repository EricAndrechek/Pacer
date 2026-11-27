import type { APIRoute } from 'astro';
import { PATHS, markdownPath } from '../../scripts/discovery.mjs';
import { HUB, toolPages } from '../lib/compare';
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
  /** ` ([Markdown](…))` for a page with a Markdown twin. */
  const md = (path: string) => {
    const m = markdownPath(path);
    return m ? ` ([Markdown](${url(m)}))` : '';
  };
  const compared = HUB.filter((t) => t.slug !== 'pacer').map((t) => t.name);

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

## Use Pacer from an agent

- [The Claude Code skill](${url(PATHS.skill)}): teaches an agent to pause a long run or a fan-out of subagents before a rate limit (\`pacer gate\`, \`pacer status\`), save its work, and resume when there is room (\`pacer wait\`). It needs Pacer on the Mac: install the app (\`${BREW_COMMAND}\`), then the skill from Pacer's Settings, which links the \`pacer\` command beside it. Also as an archive in the [Agent Skills index](${url(PATHS.agentSkills)}).
- [The pacer command](${url('/cli/')}): every subcommand, exit codes, gate-only and informed pacing.${md('/cli/')}
- [Claude price history API](${url(PATHS.priceList)}): dated per-million-token prices for every Claude model, the same file Pacer prices usage with. Public JSON, no key, CORS open, refreshed every six hours. [JSON Schema](${url(PATHS.priceSchema)}); [documentation](${url(PATHS.prices)}).
- [API catalog](${url(PATHS.apiCatalog)}) (RFC 9727) and [AI catalog](${url(PATHS.aiCatalog)}) (also at ${url(PATHS.ard)}): the same, for discovery. There is no MCP server, REST API or sign-in.
- Search: \`GET ${url(PATHS.search)}?q=<words>\` returns the best sections of this site's pages, in Markdown.
- Every page has a Markdown twin: ask for \`Accept: text/markdown\`, or use the links below.

## Pages

- [Home](${url('/')}): what Pacer is, screenshots, download.${md('/')}
- [Features](${url('/features/')}): everything the app does.${md('/features/')}
- [For agents: the pacer command and Claude Code skill](${url('/cli/')}): gate, status, wait and report; gate-only and informed pacing.${md('/cli/')}
- [How Pacer counts](${url('/how-pacer-counts/')}): where the numbers come from, and why they differ from ccusage.${md('/how-pacer-counts/')}
- [Claude API prices](${url(PATHS.prices)}): the current price of every Claude model per million tokens, when it took effect, every change, and the API.${md(PATHS.prices)}
- [How Pacer compares](${url('/compare/')}): Pacer next to ${compared.join(', ')}.${md('/compare/')}
${toolPages()
  .map((t) => `  - [${t.page.title}](${url(`/compare/${t.slug}/`)}): ${t.page.description.split('. ')[0]}.${md(`/compare/${t.slug}/`)}`)
  .join('\n')}
- [Privacy](${url('/privacy/')}): what the app sends, the two toggles, and the site's cookieless analytics.${md('/privacy/')}
- [FAQ](${url('/faq/')}): ${FAQ.map((f) => f.q.replace(/\?$/, '').toLowerCase()).join('; ')}.${md('/faq/')}
- [Changelog](${url('/changelog/')}): every release's notes.${md('/changelog/')}

## Optional

- [Full text of every page](${url('/llms-full.txt')}): the pages above as Markdown, in one file.
- [Source code and README](${REPO}).
`;
  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
