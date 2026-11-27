// /.well-known/search: Search for Agents
// (developers.cloudflare.com/ai-search/how-to/search-for-agents/) over the
// site's own pages. The index is a static asset built from the Markdown twins
// (scripts/search.mjs, /search-index.json), read through the assets binding
// once per isolate; a query is a BM25 pass over a few hundred sections.
// `GET ?q=` and `QUERY` (a text/plain or JSON `{"q"}` body) answer in
// Markdown. Ported from room-planner's worker/search.ts, without its rate
// limit (this Worker has no rate-limit binding, and a refusal would count
// against the daily request limit just the same: site/README.md, "Discovery
// for agents").
import { PATHS } from '../scripts/discovery.mjs';
import { renderResults, search, type SearchIndex } from '../scripts/search.mjs';

/** The longest query read (characters) and QUERY body (bytes). */
export const MAX_QUERY = 500;
const MAX_BODY = 4096;
const ACCEPT_QUERY = 'text/plain, application/json';
const ALLOW = 'GET, HEAD, QUERY, OPTIONS';
const RETRY_AFTER_SECONDS = 60;

const HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Expose-Headers': '*',
  'X-Content-Type-Options': 'nosniff',
  'Accept-Query': ACCEPT_QUERY,
};

const markdown = (body: string | null, status: number, extra: Record<string, string> = {}) =>
  new Response(body, {
    status,
    headers: { 'Content-Type': 'text/markdown; charset=utf-8', 'Cache-Control': 'no-store', ...HEADERS, ...extra },
  });

/** The index, fetched and parsed once per isolate (a failed load is retried on the next call). */
let loading: Promise<SearchIndex> | undefined;
const loadIndex = (env: Env, url: URL): Promise<SearchIndex> => {
  loading ??= env.ASSETS.fetch(new URL(PATHS.searchIndex, url))
    .then((r) => {
      if (!r.ok) throw new Error(`search index: ${r.status}`);
      return r.json() as Promise<SearchIndex>;
    })
    .catch((error: unknown) => {
      loading = undefined;
      throw error;
    });
  return loading;
};

/** The query: `?q=` on GET and HEAD; the body of a QUERY request (text, or JSON with `q`). */
async function readQuery(request: Request, url: URL): Promise<string | null> {
  if (request.method !== 'QUERY') return url.searchParams.get('q');
  const text = await request.text();
  if (text.length > MAX_BODY) return null;
  if ((request.headers.get('content-type') ?? '').includes('json')) {
    try {
      const q = (JSON.parse(text) as { q?: unknown }).q;
      return typeof q === 'string' ? q : null;
    } catch {
      return null;
    }
  }
  return text;
}

export async function handleSearch(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        ...HEADERS,
        'Access-Control-Allow-Methods': ALLOW,
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400',
      },
    });
  }
  if (!['GET', 'HEAD', 'QUERY'].includes(request.method)) {
    return markdown('# Method not allowed\n\nUse GET with ?q=, or QUERY.\n', 405, { Allow: ALLOW });
  }
  const query = (await readQuery(request, url))?.trim().slice(0, MAX_QUERY);
  if (!query) {
    return markdown(`# Search\n\nAdd a query: ${url.origin}${PATHS.search}?q=rate+limits (keywords or a question).\n`, 400);
  }
  let index: SearchIndex;
  try {
    index = await loadIndex(env, url);
  } catch {
    return markdown('# Search unavailable\n\nTry again in a minute.\n', 503, { 'Retry-After': String(RETRY_AFTER_SECONDS) });
  }
  const body = renderResults(query, search(index, query), `${url.origin}${PATHS.llms}`);
  return markdown(request.method === 'HEAD' ? null : body, 200, { 'Cache-Control': 'public, max-age=3600' });
}
