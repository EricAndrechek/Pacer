import type { APIRoute } from 'astro';
import { PATHS } from '../../scripts/discovery.mjs';

/**
 * robots.txt: every crawler, AI crawlers included, may read the site (the
 * owner's choice, as on room-planner: the point is for AI assistants to know
 * Pacer), with Cloudflare's Content Signals saying the same for search, AI
 * answers and AI training (site/README.md, "Discovery for agents"). /download
 * stays out: it is a redirect to the installer, counted as a download.
 * `Agentmap` points agents at the AI catalog (ARD v0.91); crawlers ignore it.
 */
export const GET: APIRoute = ({ site }) => {
  const url = (path: string) => new URL(path, site ?? 'http://localhost').toString();
  const body = [
    '# Content signals (https://contentsignals.org): search = building a search index and linking',
    '# to results; ai-input = using the content as input to AI answers; ai-train = training or',
    '# fine-tuning AI models. All allowed.',
    'User-agent: *',
    'Content-Signal: search=yes, ai-input=yes, ai-train=yes',
    'Allow: /',
    '# A redirect to the installer, counted as a download: not a page.',
    'Disallow: /download/',
    'Disallow: /download',
    '',
    `Sitemap: ${url('/sitemap-index.xml')}`,
    `Agentmap: ${url(PATHS.ard)}`,
    '',
    `# For AI agents: ${url(PATHS.llms)} (what Pacer is, its Claude Code skill, the price history API).`,
    '',
  ].join('\n');
  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
