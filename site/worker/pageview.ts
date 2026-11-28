// Page views, counted by the Worker (site/README.md, "Analytics";
// docs/telemetry-plan.md, "The website"). The pages already run the Worker
// first for the Markdown router, so it can count every request for one,
// crawlers and agents included, which the browser snippet never sees. One
// `page_view` event each, sent like `feed_request`: after the answer, in
// ctx.waitUntil, through `sendEvent`, and never able to fail or delay it.
//
// What it says is only which page, what kind of client asked, which
// representation it got and the status class. Never the IP address, the
// User-Agent itself, the referrer, the query string, cookies or any id that
// could join two requests: a new random distinct_id each time, and no person
// profile (`sendEvent`).

import { LLM_BOT_UA } from './md-router.mjs';
import { environmentOf, sendEvent } from './lib';

export type VisitorClass = 'human' | 'search_crawler' | 'ai_agent' | 'other_bot';

/** Search engines' crawlers, by the token each puts in its User-Agent. */
const SEARCH_CRAWLER =
  /googlebot|google-inspectiontool|bingbot|bingpreview|duckduckbot|applebot|yandexbot|yandex\.com\/bots|baiduspider|slurp|sogou|seznambot|qwantify|petalbot|naverbot|yeti\/|exabot|mojeekbot/i;

/** Everything else that is not a person: scripts, libraries, headless browsers, anything calling itself a bot. */
const OTHER_BOT =
  /bot|crawl|spider|slurp|curl\/|wget\/|python|go-http-client|httpclient|okhttp|java\/|libwww|axios|node-fetch|undici|scrapy|headless|phantomjs|facebookexternalhit|preview/i;

/**
 * How a client is classed. Each pattern is a flat alternation of literals
 * (no nested quantifiers, so matching is linear), tried on at most the first
 * 512 characters of the User-Agent. An AI agent first: one of md-router's
 * LLM crawlers, or anything asking for Markdown, which is how agents fetch
 * this site; then the search engines; then any other automation, an empty
 * User-Agent included; and otherwise a person's browser.
 */
export function visitorClass(request: Request): VisitorClass {
  const ua = (request.headers.get('User-Agent') ?? '').slice(0, 512);
  if ((request.headers.get('Accept') ?? '').includes('text/markdown') || LLM_BOT_UA.test(ua)) return 'ai_agent';
  if (SEARCH_CRAWLER.test(ua)) return 'search_crawler';
  if (!ua.trim() || OTHER_BOT.test(ua)) return 'other_bot';
  return 'human';
}

/** `2xx`, `3xx`, `4xx`, `5xx`, and `304` on its own (a revalidation, not a page sent). */
export function statusClass(status: number): string {
  return status === 304 ? '304' : `${Math.floor(status / 100)}xx`;
}

/** Do Not Track or Global Privacy Control: the site records nothing (Privacy page). */
const optedOut = (request: Request) => request.headers.get('DNT') === '1' || request.headers.get('Sec-GPC') === '1';

/**
 * The page_view event for one answered request, or null when it is not
 * counted: anything but GET (HEAD included), a 404 (the not-found page is not
 * a page view), or DNT/GPC. `path` is the route the Worker matched, never the
 * URL as sent, so no query string or fragment can ride along.
 */
export function pageViewEvent(request: Request, path: string, response: Response): Record<string, unknown> | null {
  if (request.method !== 'GET' || response.status === 404 || optedOut(request)) return null;
  const type = response.headers.get('Content-Type') ?? '';
  const markdown = type ? type.startsWith('text/markdown') : visitorClass(request) === 'ai_agent';
  return {
    surface: 'website',
    environment: environmentOf(new URL(request.url).hostname),
    path,
    class: visitorClass(request),
    representation: markdown ? 'markdown' : 'html',
    status: statusClass(response.status),
  };
}

/** Schedules the page_view event. Never throws, never awaits. */
export function countPageView(request: Request, env: Env, ctx: ExecutionContext, path: string, response: Response): void {
  try {
    if (!env.POSTHOG_TOKEN) return;
    const event = pageViewEvent(request, path, response);
    if (!event) return;
    ctx.waitUntil(sendEvent(env, 'page_view', crypto.randomUUID(), event).catch(captureFailed));
  } catch (err) {
    captureFailed(err);
  }
}

function captureFailed(err: unknown): void {
  try {
    console.error(JSON.stringify({ message: 'page view capture failed', error: String(err) }));
  } catch {
    // Nothing left to tell.
  }
}
