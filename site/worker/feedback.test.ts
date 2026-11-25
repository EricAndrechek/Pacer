// POST /api/feedback (worker/feedback.ts): what is accepted, what is refused,
// and exactly what reaches Sentry.
import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest';
import worker from './index';
import {
  FULL_MESSAGE_FILENAME,
  MAX_ATTACHMENT_BYTES,
  MAX_BODY_BYTES,
  SENTRY_MESSAGE_MAX,
  SENTRY_TIMEOUT_MS,
  decodeBase64,
  parseDsn,
  parseFeedback,
} from './feedback';
import wrangler from '../wrangler.jsonc?raw';

const DSN = 'https://4538a70956bdb802f903aa6ceba5ba32@o4506596663427072.ingest.us.sentry.io/4512290674049024';
const ENVELOPE_URL = 'https://o4506596663427072.ingest.us.sentry.io/api/4512290674049024/envelope/';
const PACER_UA = 'Pacer/1795528779 CFNetwork/3860.100.1 Darwin/25.1.0';
const VISITOR_IP = '203.0.113.77';
const INSTALL_ID = '5E8F0C3A-1B2D-4C5E-9F60-7A8B9C0D1E2F';

const valid = (extra: Record<string, unknown> = {}): Record<string, unknown> => ({
  kind: 'problem',
  message: 'The 7-day gauge froze after the update.',
  appVersion: '0.9.5',
  appBuild: '1795528779',
  macOS: '26.1',
  model: 'Mac16,8',
  ...extra,
});

const base64 = (bytes: Uint8Array) => (bytes as Uint8Array & { toBase64(): string }).toBase64();
const bytesOf = (n: number, seed = 7) => {
  const out = new Uint8Array(n);
  // Every byte value, newlines included: the envelope is newline-delimited, so lengths must carry it.
  for (let i = 0; i < n; i++) out[i] = (i * 31 + seed) & 0xff;
  return out;
};

interface Sent {
  url: string;
  headers: Record<string, string>;
  body: Uint8Array;
}
let upstream: MockInstance<typeof fetch> | undefined;
let sent: Sent[] = [];
let warn: MockInstance<typeof console.warn>;

/** Stand in for Sentry: record each envelope and answer with `reply()`. */
function sentry(reply: () => Response | Promise<Response> = () => new Response('{"id":"x"}')) {
  upstream?.mockRestore();
  upstream = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    const body = init?.body instanceof Blob ? new Uint8Array(await init.body.arrayBuffer()) : new Uint8Array();
    sent.push({ url, headers: Object.fromEntries(new Headers(init?.headers)), body });
    return reply();
  });
}

beforeEach(() => {
  sent = [];
  warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
});
afterEach(() => {
  upstream?.mockRestore();
  upstream = undefined;
  warn.mockRestore();
});

type Init = { body?: BodyInit | null; method?: string; headers?: Record<string, string>; host?: string; dsn?: string };

/** POST the handler, the way the app does unless `init` says otherwise. */
async function post(body: unknown, init: Init = {}) {
  const env = { ASSETS: { fetch: async () => new Response('asset') }, POSTHOG_TOKEN: '', SENTRY_DSN: init.dsn ?? DSN } as unknown as Env;
  const ctx = createExecutionContext();
  const method = init.method ?? 'POST';
  const request = new Request(`https://${init.host ?? 'pacer.andrechek.com'}/api/feedback`, {
    method,
    headers: {
      'User-Agent': PACER_UA,
      'Content-Type': 'application/json',
      'CF-Connecting-IP': VISITOR_IP,
      'X-Forwarded-For': VISITOR_IP,
      'X-Real-IP': VISITOR_IP,
      Cookie: 'c=secret-cookie',
      ...init.headers,
    },
    body: method === 'GET' || method === 'HEAD' ? null : 'body' in init ? init.body : JSON.stringify(body),
  });
  const response = await worker.fetch(request as Parameters<typeof worker.fetch>[0], env, ctx);
  await waitOnExecutionContext(ctx);
  return { response, json: (await response.clone().json().catch(() => null)) as Record<string, unknown> | null };
}

/** An envelope back into its parts: the header, then each item's header and exactly `length` bytes. */
function parseEnvelope(bytes: Uint8Array) {
  const text = new TextDecoder();
  let at = 0;
  const line = () => {
    const end = bytes.indexOf(0x0a, at);
    expect(end).toBeGreaterThan(at);
    const value = JSON.parse(text.decode(bytes.subarray(at, end))) as Record<string, unknown>;
    at = end + 1;
    return value;
  };
  const header = line();
  const items: { header: Record<string, unknown>; payload: Uint8Array }[] = [];
  while (at < bytes.length) {
    const itemHeader = line();
    const length = itemHeader.length as number;
    const payload = bytes.slice(at, at + length);
    at += length;
    expect(bytes[at], 'each payload ends with a newline').toBe(0x0a);
    at += 1;
    items.push({ header: itemHeader, payload });
  }
  return { header, items };
}
const eventOf = (envelope: ReturnType<typeof parseEnvelope>) =>
  JSON.parse(new TextDecoder().decode(envelope.items[0]!.payload)) as Record<string, any>;

describe('forwarding to Sentry', () => {
  it('sends a valid report as user feedback to the project in the DSN, and answers ok with the event id', async () => {
    sentry();
    const { response, json } = await post(valid());
    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toBe('application/json; charset=utf-8');
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(json).toEqual({ ok: true, id: expect.stringMatching(/^[0-9a-f]{32}$/) });

    expect(sent).toHaveLength(1);
    const [request] = sent;
    expect(request!.url).toBe(ENVELOPE_URL);
    // The Worker's own headers, nothing of the client's.
    expect(request!.headers).toEqual({
      'content-type': 'application/x-sentry-envelope',
      'x-sentry-auth': 'Sentry sentry_version=7, sentry_key=4538a70956bdb802f903aa6ceba5ba32, sentry_client=pacer.site-worker/1.0.0',
    });

    const envelope = parseEnvelope(request!.body);
    expect(envelope.header).toEqual({ event_id: json!.id, sent_at: expect.any(String), sdk: { name: 'pacer.site-worker', version: '1.0.0' } });
    expect(envelope.items).toHaveLength(1);
    expect(envelope.items[0]!.header).toEqual({ type: 'feedback', length: envelope.items[0]!.payload.byteLength });
    const event = eventOf(envelope);
    expect(event).toEqual({
      event_id: json!.id,
      timestamp: expect.any(Number),
      platform: 'other',
      level: 'info',
      release: 'com.ericandrechek.pacer@0.9.5+1795528779',
      environment: 'production',
      sdk: { name: 'pacer.site-worker', version: '1.0.0', settings: { infer_ip: 'never' } },
      tags: { kind: 'problem', app_version: '0.9.5', macos: '26.1', model: 'Mac16,8', source: 'website-proxy', site_environment: 'production' },
      contexts: {
        // No name: Sentry shows it as the reporter's name. The kind is the tag.
        feedback: { message: 'The 7-day gauge froze after the update.', source: 'website-proxy' },
        os: { name: 'macOS', version: '26.1' },
        device: { family: 'Mac', model: 'Mac16,8' },
        app: { app_version: '0.9.5', app_build: '1795528779' },
      },
    });
    // No user without an install id, and no address anywhere.
    const all = new TextDecoder().decode(request!.body);
    for (const leak of [VISITOR_IP, 'ip_address', '{{auto}}', 'secret-cookie', PACER_UA]) expect(all).not.toContain(leak);
  });

  it('carries the optional fields where Sentry shows them', async () => {
    sentry();
    await post(
      valid({
        kind: 'idea',
        email: '  someone@example.com ',
        installId: INSTALL_ID,
        locale: 'en_CA',
        devDescribe: 'v0.9.4-12-gabc1234-dirty',
        macOS: '26.1 (25B78)',
      }),
    );
    const event = eventOf(parseEnvelope(sent[0]!.body));
    expect(event.user).toEqual({ id: INSTALL_ID }); // and nothing else: no ip_address
    expect(event.contexts.feedback).toEqual({
      message: 'The 7-day gauge froze after the update.',
      source: 'website-proxy',
      contact_email: 'someone@example.com',
    });
    expect(event.contexts.culture).toEqual({ locale: 'en_CA' });
    expect(event.contexts.os).toEqual({ name: 'macOS', version: '26.1', build: '25B78' });
    expect(event.contexts.app).toEqual({ app_version: '0.9.5', app_build: '1795528779', dev_describe: 'v0.9.4-12-gabc1234-dirty' });
    // A dev build is reported the way the app's own SDK names it.
    expect(event.release).toBe('com.ericandrechek.pacer@dev+1795528779');
    expect(event.environment).toBe('development');
    expect(event.tags).toMatchObject({ kind: 'idea', macos: '26.1' });
  });

  it('sends the attachment as its own item, byte for byte, in the same envelope', async () => {
    const files: [string, string, Uint8Array][] = [
      ['pacer-window.png', 'image/png', bytesOf(4096, 1)],
      ['settings "export".json', 'application/json', new TextEncoder().encode('{"a":[1,2,3]}\n')],
      ['repro.mov', 'video/quicktime', bytesOf(300_001, 3)],
      ['Capture d’écran 2026-11-25 à 10.00.png', 'image/png', bytesOf(10, 5)],
    ];
    for (const [filename, contentType, bytes] of files) {
      sent = [];
      sentry();
      const { response } = await post(valid({ attachments: [{ filename, contentType, base64: base64(bytes) }] }));
      expect(response.status, filename).toBe(200);
      const envelope = parseEnvelope(sent[0]!.body);
      expect(envelope.items.map((i) => i.header.type)).toEqual(['feedback', 'attachment']);
      expect(envelope.items[1]!.header).toEqual({
        type: 'attachment',
        length: bytes.byteLength,
        filename,
        content_type: contentType,
        attachment_type: 'event.attachment',
      });
      expect(envelope.items[1]!.payload).toEqual(bytes);
    }
  });

  it('accepts an attachment of exactly 8 MB, within the 12 MB body', async () => {
    sentry();
    const big = bytesOf(MAX_ATTACHMENT_BYTES, 9);
    const body = JSON.stringify(valid({ message: 'é'.repeat(10_000), attachments: [{ filename: 'big.mov', contentType: 'video/quicktime', base64: base64(big) }] }));
    expect(body.length).toBeLessThan(MAX_BODY_BYTES);
    const { response } = await post(null, { body });
    expect(response.status).toBe(200);
    expect(parseEnvelope(sent[0]!.body).items[1]!.payload.byteLength).toBe(MAX_ATTACHMENT_BYTES);
  });

  it('keeps a message longer than Sentry takes: the start in the feedback, the whole text attached', async () => {
    sentry();
    const long = '🙂'.repeat(10_000); // 10,000 characters, 20,000 UTF-16 units
    const { response } = await post(valid({ message: long }));
    expect(response.status).toBe(200);
    const envelope = parseEnvelope(sent[0]!.body);
    const shown = eventOf(envelope).contexts.feedback.message as string;
    expect([...shown].length).toBe(SENTRY_MESSAGE_MAX);
    expect(shown.startsWith('🙂'.repeat(100))).toBe(true);
    expect(shown.endsWith(`[continues in ${FULL_MESSAGE_FILENAME}]`)).toBe(true);
    const full = envelope.items[1]!;
    expect(full.header).toMatchObject({ filename: FULL_MESSAGE_FILENAME, content_type: 'text/plain' });
    expect(new TextDecoder().decode(full.payload)).toBe(long);
  });

  it('sends a message of exactly 4096 characters as it is', async () => {
    sentry();
    const exact = 'a'.repeat(SENTRY_MESSAGE_MAX);
    await post(valid({ message: exact }));
    const envelope = parseEnvelope(sent[0]!.body);
    expect(eventOf(envelope).contexts.feedback.message).toBe(exact);
    expect(envelope.items).toHaveLength(1);
  });

  it('tags reports sent through a preview, which stays out of search', async () => {
    sentry();
    const { response } = await post(valid(), { host: 'feat-pacer.example.workers.dev' });
    expect(response.headers.get('X-Robots-Tag')).toBe('noindex');
    expect(eventOf(parseEnvelope(sent[0]!.body)).tags.site_environment).toBe('preview');
  });

  it('gives Sentry a timeout', async () => {
    sentry();
    const spy = upstream!;
    await post(valid());
    expect(spy.mock.calls[0]![1]?.signal).toBeInstanceOf(AbortSignal);
    expect(spy.mock.calls[0]![1]?.redirect).toBe('manual');
    expect(SENTRY_TIMEOUT_MS).toBe(20_000);
  });
});

describe("Sentry's answers", () => {
  it('passes on a rate limit with its Retry-After', async () => {
    sentry(() => new Response('', { status: 429, headers: { 'Retry-After': '60' } }));
    const { response, json } = await post(valid());
    expect(response.status).toBe(429);
    expect(response.headers.get('Retry-After')).toBe('60');
    expect(json).toEqual({ ok: false, error: 'Sentry is rate limiting reports' });
  });

  it('answers 502 when Sentry refuses, fails, cannot be reached or takes too long, and 413 when it refuses the size', async () => {
    const cases: [() => Response | Promise<Response>, number, string][] = [
      [() => new Response('bad', { status: 400 }), 502, 'Sentry refused the report'],
      [() => new Response('oops', { status: 500 }), 502, 'Sentry refused the report'],
      [() => new Response(null, { status: 302, headers: { Location: 'https://evil.example/' } }), 502, 'Sentry refused the report'],
      [() => new Response('big', { status: 413 }), 413, 'Sentry refused the size'],
      [
        () => {
          throw new TypeError('network down');
        },
        502,
        'could not reach Sentry',
      ],
      [
        () => {
          throw new DOMException('The operation was aborted due to timeout', 'TimeoutError');
        },
        502,
        'Sentry took too long',
      ],
    ];
    for (const [reply, status, error] of cases) {
      sentry(reply);
      const { response, json } = await post(valid());
      expect(response.status, error).toBe(status);
      expect(json, error).toEqual({ ok: false, error });
    }
  });

  it('is off, answering 503, when the DSN is empty or not a DSN', async () => {
    sentry();
    for (const dsn of ['', 'not a dsn', 'http://4538a70956bdb802f903aa6ceba5ba32@example.com/1', 'https://example.com/123']) {
      const { response, json } = await post(valid(), { dsn });
      expect(response.status, dsn).toBe(503);
      expect(json).toEqual({ ok: false, error: 'feedback is not configured' });
    }
    expect(sent).toHaveLength(0);
  });
});

describe('refused requests', () => {
  it('serves only Pacer, and logs the refusal without the address', async () => {
    sentry();
    for (const ua of ['curl/8.7.1', '', 'Mozilla/5.0 Pacer/0.9.5', 'pacer/1.0']) {
      const { response, json } = await post(valid(), { headers: { 'User-Agent': ua } });
      expect(response.status, ua).toBe(403);
      expect(json).toEqual({ ok: false, error: 'not a Pacer client' });
    }
    expect(sent).toHaveLength(0);
    expect(warn).toHaveBeenCalledTimes(4);
    const logged = JSON.stringify(warn.mock.calls);
    expect(logged).toContain('feedback refused');
    expect(logged).not.toContain(VISITOR_IP);
  });

  it('takes only POST, only JSON, and only a JSON object', async () => {
    sentry();
    const get = await post(valid(), { method: 'GET' });
    expect(get.response.status).toBe(405);
    expect(get.response.headers.get('Allow')).toBe('POST');
    for (const type of ['text/plain', 'multipart/form-data', 'application/json; charset=latin1', '']) {
      const { response } = await post(valid(), { headers: { 'Content-Type': type } });
      expect(response.status, type).toBe(415);
    }
    expect((await post(valid(), { headers: { 'Content-Type': 'application/json; charset=UTF-8' } })).response.status).toBe(200);
    const notJson = await post(null, { body: '{"kind": "idea",' });
    expect(notJson.response.status).toBe(400);
    expect(notJson.json).toEqual({ ok: false, error: 'body is not JSON' });
    for (const body of ['[]', '"text"', 'null', '42']) {
      const { json } = await post(null, { body });
      expect(json, body).toEqual({ ok: false, error: 'body must be a JSON object' });
    }
    expect(sent).toHaveLength(1);
  });

  it('refuses a body whose Content-Length is over 12 MB, before reading any of it', async () => {
    sentry();
    let pulled = 0;
    // highWaterMark 0: the stream is pulled only when something reads it.
    const untouched = new ReadableStream<Uint8Array>(
      {
        pull(controller) {
          pulled++;
          controller.close();
        },
      },
      { highWaterMark: 0 },
    );
    const { response, json } = await post(null, {
      body: untouched,
      headers: { 'Content-Length': String(MAX_BODY_BYTES + 1) },
    });
    expect(response.status).toBe(413);
    expect(json).toEqual({ ok: false, error: 'body larger than 12 MB' });
    expect(pulled).toBe(0);
    expect(sent).toHaveLength(0);
  });

  it('refuses a body of 12 MB and one byte however it arrives', async () => {
    sentry();
    const { response } = await post(null, { body: new Uint8Array(MAX_BODY_BYTES + 1) });
    expect(response.status).toBe(413);
    expect(sent).toHaveLength(0);
  });

  it('refuses a streamed body (no Content-Length) once it passes 12 MB', async () => {
    sentry();
    const chunk = new Uint8Array(1024 * 1024).fill(0x20);
    let pulled = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled++;
        if (pulled > 40) controller.close();
        else controller.enqueue(chunk);
      },
    });
    const { response } = await post(null, { body: stream });
    expect(response.status).toBe(413);
    // It stopped reading at the cap, not at the end of the stream.
    expect(pulled).toBeLessThanOrEqual(15);
    expect(sent).toHaveLength(0);
  });

  it('refuses an attachment over 8 MB from its size alone', async () => {
    sentry();
    const { json } = await post(
      valid({ attachments: [{ filename: 'big.mov', contentType: 'video/quicktime', base64: base64(bytesOf(MAX_ATTACHMENT_BYTES + 1)) }] }),
    );
    expect(json).toEqual({ ok: false, error: 'attachment 1: larger than 8 MB' });
    expect(sent).toHaveLength(0);
  });

  const att = (extra: Record<string, unknown> = {}) => ({ filename: 'a.png', contentType: 'image/png', base64: 'iVBORw0KGgo=', ...extra });
  const invalid: [string, Record<string, unknown>, string][] = [
    ['an unknown field', valid({ ip: VISITOR_IP }), 'unknown field: ip'],
    ['no kind', valid({ kind: undefined }), 'kind must be idea, problem or other'],
    ['another kind', valid({ kind: 'bug' }), 'kind must be idea, problem or other'],
    ['no message', valid({ message: undefined }), 'message must be 1 to 10000 characters'],
    ['an empty message', valid({ message: '' }), 'message must be 1 to 10000 characters'],
    ['a blank message', valid({ message: ' \n\t ' }), 'message must be 1 to 10000 characters'],
    ['a message of 10,001 characters', valid({ message: 'a'.repeat(10_001) }), 'message must be 1 to 10000 characters'],
    ['a message that is not text', valid({ message: ['hi'] }), 'message must be 1 to 10000 characters'],
    ['an email that is not one', valid({ email: 'not an email' }), 'email is not an email address'],
    ['an email that is too long', valid({ email: `${'a'.repeat(60)}@${'b'.repeat(200)}.com` }), 'email is not an email address'],
    ['an email that is a number', valid({ email: 5 }), 'email is not an email address'],
    ['no appVersion', valid({ appVersion: undefined }), 'appVersion must be X.Y.Z'],
    ['an appVersion with a v', valid({ appVersion: 'v0.9.5' }), 'appVersion must be X.Y.Z'],
    ['no appBuild', valid({ appBuild: undefined }), 'appBuild must be a build number'],
    ['an appBuild that is a number', valid({ appBuild: 1795528779 }), 'appBuild must be a build number'],
    ['a devDescribe with a space', valid({ devDescribe: 'v0.9.4 dirty' }), 'devDescribe is not a git describe'],
    ['no macOS', valid({ macOS: undefined }), 'macOS must be a version like 26.1'],
    ['a macOS that is a sentence', valid({ macOS: 'Version 26.1 (Build 25B78)' }), 'macOS must be a version like 26.1'],
    ['no model', valid({ model: undefined }), 'model must be a Mac model identifier'],
    ['a model that is a name', valid({ model: "Somebody's MacBook Pro" }), 'model must be a Mac model identifier'],
    ['a locale that is not one', valid({ locale: 'English (Canada)' }), 'locale is not a locale identifier'],
    ['an installId that is not one', valid({ installId: 'someone@example.com' }), 'installId is not an install id'],
    ['an installId that is too long', valid({ installId: 'a'.repeat(65) }), 'installId is not an install id'],
    ['attachments that are not a list', valid({ attachments: att() }), 'attachments must be a list'],
    ['two attachments', valid({ attachments: [att(), att()] }), 'at most 1 attachment'],
    ['an attachment that is not an object', valid({ attachments: ['iVBORw0KGgo='] }), 'attachment 1: must be an object'],
    ['an attachment with an unknown field', valid({ attachments: [att({ path: '/Users/x' })] }), 'attachment 1: unknown field: path'],
    ['an attachment named with a path', valid({ attachments: [att({ filename: '../../etc/passwd' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a backslash', valid({ attachments: [att({ filename: 'a\\b.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a C1 control', valid({ attachments: [att({ filename: 'a\u0085b.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a right-to-left override', valid({ attachments: [att({ filename: 'photo\u202egnp.exe' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a bidi isolate', valid({ attachments: [att({ filename: 'a\u2067b.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a zero-width space', valid({ attachments: [att({ filename: 'a\u200bb.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a left-to-right mark', valid({ attachments: [att({ filename: 'a\u200eb.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a byte-order mark', valid({ attachments: [att({ filename: '\ufeffa.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named ..', valid({ attachments: [att({ filename: '..' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment named with a newline', valid({ attachments: [att({ filename: 'a\nb.png' })] }), 'attachment 1: filename must be a file name'],
    ['an attachment with no name', valid({ attachments: [att({ filename: '' })] }), 'attachment 1: filename must be a file name'],
    ['a type not allowed', valid({ attachments: [att({ contentType: 'text/html' })] }), 'attachment 1: contentType must be one of'],
    ['an empty attachment', valid({ attachments: [att({ base64: '' })] }), 'attachment 1: base64 is not valid'],
    ['base64 with a space', valid({ attachments: [att({ base64: 'iVBO Rw0KGgo=' })] }), 'attachment 1: base64 is not valid'],
    // Four spaces keep the length a multiple of 4: refused because it decodes shorter than it claims.
    ['base64 with whitespace a decoder would skip', valid({ attachments: [att({ base64: 'iVBO    Rw0KGgo=' })] }), 'attachment 1: base64 is not valid'],
    ['base64 without padding', valid({ attachments: [att({ base64: 'iVBORw0KGgo' })] }), 'attachment 1: base64 is not valid'],
    ['url-safe base64', valid({ attachments: [att({ base64: 'ab-_' })] }), 'attachment 1: base64 is not valid'],
    ['not base64', valid({ attachments: [att({ base64: '$$$$' })] }), 'attachment 1: base64 is not valid'],
  ];
  for (const [what, body, reason] of invalid) {
    it(`refuses ${what} with a 400 and a short reason`, async () => {
      sentry();
      const { response, json } = await post(body);
      expect(response.status).toBe(400);
      expect(json?.ok).toBe(false);
      expect(String(json?.error)).toContain(reason);
      expect(String(json?.error).length).toBeLessThan(120);
      expect(sent).toHaveLength(0);
    });
  }
});

describe('parsing', () => {
  it('parseFeedback accepts the smallest valid report and treats a blank email as none', () => {
    const parsed = parseFeedback(valid({ email: '   ', attachments: null, installId: null }));
    expect(parsed).toMatchObject({ ok: true, value: { email: null, installId: null, attachments: [], locale: null, devDescribe: null } });
  });

  it('decodeBase64 is strict standard base64', () => {
    expect(decodeBase64('aGk=')).toEqual(new TextEncoder().encode('hi'));
    expect(decodeBase64('')).toEqual(new Uint8Array());
    for (const bad of ['aGk', 'a', 'aGk=x', '-_8=', 'aG k=']) {
      const out = decodeBase64(bad);
      // Either refused, or (whitespace skipped) shorter than the text implies, which parseAttachment refuses.
      if (out) expect(out.length, bad).not.toBe((bad.length / 4) * 3 - (bad.endsWith('=') ? 1 : 0));
    }
  });

  it('parseDsn reads the key, host and project', () => {
    expect(parseDsn(DSN)).toEqual({ key: '4538a70956bdb802f903aa6ceba5ba32', host: 'o4506596663427072.ingest.us.sentry.io', projectId: '4512290674049024' });
    expect(parseDsn(undefined)).toBeNull();
  });
});

describe('configuration', () => {
  it('routes /api/feedback through the Worker and forwards to the app\'s own DSN (project.yml PACER_SENTRY_DSN)', () => {
    const runFirst = /"run_worker_first":\s*\[([^\]]*)\]/.exec(wrangler)?.[1] ?? '';
    expect(runFirst).toContain('"/api/feedback"');
    expect(wrangler).toContain(`"SENTRY_DSN": "${DSN}"`);
  });
});
