// POST /api/feedback: the Pacer app's feedback, forwarded to Sentry as user
// feedback (docs/telemetry-plan.md, "Feedback").
//
// The app posts JSON here instead of to Sentry so a report gets through where
// Sentry's own SDK path would not (and so the site decides what is forwarded).
// Every field is checked against a fixed shape and anything unexpected is
// refused with a 400 and a short reason. What is forwarded is built here from
// the checked values: the client's IP address and request headers never go to
// Sentry, because the envelope is posted by this Worker, from Cloudflare,
// with its own headers, and asks Sentry not to infer an address.
//
// Abuse: only a `Pacer/` User-Agent is served, and a body is at most 12 MB.
// There is no per-address rate limit (on the Free plan that would need KV or a
// Durable Object); Sentry's own project rate limits and spike protection cap
// what gets stored, and every refused request is logged (reason only).

/**
 * The whole request body, JSON with base64 attachments. This is what bounds
 * memory, whatever the number of files: the body, its parsed copy, the
 * decoded files and the envelope are all in memory at once, held well under
 * the isolate's 128 MB, and an isolate that runs out is restarted with every
 * request it is serving (price-history requests included).
 */
export const MAX_BODY_BYTES = 12 * 1024 * 1024;
/** Each attachment, decoded: as base64 (a third larger) it fits the body cap with the message. */
export const MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;
/** The app sends at most three (its own window picture and two files, or three files), 8 MB in all once encoded. */
export const MAX_ATTACHMENTS = 3;
export const MAX_MESSAGE_CHARS = 10_000;
/** Sentry refuses a feedback message longer than this (unicode scalars; sentry-cocoa's SentryFeedbackValidator). */
export const SENTRY_MESSAGE_MAX = 4096;
/** The full text of a longer message goes with the report as this attachment. */
export const FULL_MESSAGE_FILENAME = 'feedback-message.txt';
/** Uploads can be tens of MB; Sentry's ingest takes well under this from a data centre. */
export const SENTRY_TIMEOUT_MS = 20_000;

const KINDS = ['idea', 'problem', 'other'] as const;
const CONTENT_TYPES = ['image/png', 'image/jpeg', 'text/plain', 'application/json', 'video/quicktime'] as const;
const FIELDS = new Set(['kind', 'message', 'email', 'appVersion', 'appBuild', 'devDescribe', 'macOS', 'model', 'locale', 'installId', 'attachments']);
const ATTACHMENT_FIELDS = new Set(['filename', 'contentType', 'base64']);

/** X.Y.Z with an optional pre-release: CFBundleShortVersionString. */
const SHORT_VERSION = /^\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$/;
/** CFBundleVersion: digits (a release's is a timestamp; a local build's is 1), maybe dotted. */
const BUILD = /^\d{1,12}(?:\.\d{1,6}){0,2}$/;
/** `git describe` of a dev build: v0.9.4-12-gabc1234-dirty. */
const DEV_DESCRIBE = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,79}$/;
/** The macOS version, optionally with its build: `26.1`, `15.7.2`, `26.1 (25B78)`. */
const MACOS = /^\d{1,2}(?:\.\d{1,3}){0,2}(?: \([0-9A-Za-z]{1,12}\))?$/;
/** hw.model: Mac16,8, MacBookPro18,3, VirtualMac2,1; or `unknown`, the app's word when sysctl fails (DailyCheckIn.sysctlString). */
const MODEL = /^(?:[A-Za-z]{2,24}\d{1,3},\d{1,3}|unknown)$/;
/** A locale identifier: en, en_CA, en-CA, zh-Hans_CN. */
const LOCALE = /^[A-Za-z]{2,3}(?:[-_][0-9A-Za-z]{1,8}){0,5}$/;
/** Pacer's install id: Sentry's INSTALLATION id (an uppercase UUID), or a hex token. */
const INSTALL_ID = /^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{16,64})$/;
/** An address someone typed to be answered at; checked for shape only. */
const EMAIL = /^[^\s@<>()[\]\\,;:"]{1,64}@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]{2,63}$/;
/**
 * A file name, not a path: no separators, no C0 or C1 controls, and no
 * zero-width or bidi controls, which could make a name read as something
 * else in Sentry (`photo\u202Egnp.exe` shows as `photoexe.png`).
 */
const FILENAME = /^[^/\\\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]{1,128}$/;

export interface Attachment {
  filename: string;
  contentType: (typeof CONTENT_TYPES)[number];
  bytes: Uint8Array;
}

export interface Feedback {
  kind: (typeof KINDS)[number];
  message: string;
  email: string | null;
  appVersion: string;
  appBuild: string;
  devDescribe: string | null;
  macOS: string;
  model: string;
  locale: string | null;
  installId: string | null;
  attachments: Attachment[];
}

type Checked<T> = { ok: true; value: T } | { ok: false; reason: string };
const refuse = (reason: string): { ok: false; reason: string } => ({ ok: false, reason });

/** The request body, checked field by field. Decodes attachments (dropping each base64 string as it goes). */
export function parseFeedback(body: unknown): Checked<Feedback> {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return refuse('body must be a JSON object');
  const b = body as Record<string, unknown>;
  for (const key of Object.keys(b)) if (!FIELDS.has(key)) return refuse(`unknown field: ${key.slice(0, 40)}`);

  if (!KINDS.includes(b.kind as Feedback['kind'])) return refuse('kind must be idea, problem or other');
  const message = b.message;
  // Length in UTF-16 units first, so a huge string is refused before it is walked.
  if (typeof message !== 'string' || message.length > MAX_MESSAGE_CHARS * 2 || codePoints(message) > MAX_MESSAGE_CHARS) {
    return refuse(`message must be 1 to ${MAX_MESSAGE_CHARS} characters`);
  }
  if (!/\S/u.test(message)) return refuse(`message must be 1 to ${MAX_MESSAGE_CHARS} characters`);

  const email = optional(b.email, EMAIL, 254, true);
  if (email === undefined) return refuse('email is not an email address');
  const appVersion = required(b.appVersion, SHORT_VERSION, 20);
  if (!appVersion) return refuse('appVersion must be X.Y.Z');
  const appBuild = required(b.appBuild, BUILD, 20);
  if (!appBuild) return refuse('appBuild must be a build number');
  const devDescribe = optional(b.devDescribe, DEV_DESCRIBE, 80);
  if (devDescribe === undefined) return refuse('devDescribe is not a git describe');
  const macOS = required(b.macOS, MACOS, 24);
  if (!macOS) return refuse('macOS must be a version like 26.1');
  const model = required(b.model, MODEL, 32);
  if (!model) return refuse('model must be a Mac model identifier');
  const locale = optional(b.locale, LOCALE, 35);
  if (locale === undefined) return refuse('locale is not a locale identifier');
  const installId = optional(b.installId, INSTALL_ID, 64);
  if (installId === undefined) return refuse('installId is not an install id');

  const attachments: Attachment[] = [];
  if (b.attachments !== undefined && b.attachments !== null) {
    if (!Array.isArray(b.attachments)) return refuse('attachments must be a list');
    if (b.attachments.length > MAX_ATTACHMENTS) return refuse(`at most ${MAX_ATTACHMENTS} attachments`);
    for (const [i, raw] of b.attachments.entries()) {
      const checked = parseAttachment(raw, i + 1);
      if (!checked.ok) return checked;
      attachments.push(checked.value);
      // The decoded copy is all that is needed from here; let the text go.
      b.attachments[i] = null;
    }
  }
  return {
    ok: true,
    value: {
      kind: b.kind as Feedback['kind'],
      message,
      email,
      appVersion,
      appBuild,
      devDescribe,
      macOS,
      model,
      locale,
      installId,
      attachments,
    },
  };
}

function parseAttachment(raw: unknown, n: number): Checked<Attachment> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return refuse(`attachment ${n}: must be an object`);
  const a = raw as Record<string, unknown>;
  for (const key of Object.keys(a)) if (!ATTACHMENT_FIELDS.has(key)) return refuse(`attachment ${n}: unknown field: ${key.slice(0, 40)}`);
  const filename = a.filename;
  if (typeof filename !== 'string' || !FILENAME.test(filename) || filename === '.' || filename === '..') {
    return refuse(`attachment ${n}: filename must be a file name`);
  }
  if (!CONTENT_TYPES.includes(a.contentType as Attachment['contentType'])) {
    return refuse(`attachment ${n}: contentType must be one of ${CONTENT_TYPES.join(', ')}`);
  }
  const base64 = a.base64;
  if (typeof base64 !== 'string' || base64.length === 0 || base64.length % 4 !== 0) {
    return refuse(`attachment ${n}: base64 is not valid`);
  }
  // Refused by size before decoding anything.
  const padding = base64.endsWith('==') ? 2 : base64.endsWith('=') ? 1 : 0;
  const expected = (base64.length / 4) * 3 - padding;
  if (expected > MAX_ATTACHMENT_BYTES) return refuse(`attachment ${n}: larger than 8 MB`);
  const bytes = decodeBase64(base64);
  // A decoder that skips whitespace would yield fewer bytes than the text implies.
  if (!bytes || bytes.length !== expected || bytes.length === 0) return refuse(`attachment ${n}: base64 is not valid`);
  return { ok: true, value: { filename, contentType: a.contentType as Attachment['contentType'], bytes } };
}

/** Standard base64, padded. The runtime's native decoder (Uint8Array.fromBase64); a loop only where it is missing. */
export function decodeBase64(text: string): Uint8Array | null {
  const native = (Uint8Array as unknown as { fromBase64?: (s: string, o: object) => Uint8Array }).fromBase64;
  try {
    if (native) return native(text, { alphabet: 'base64', lastChunkHandling: 'strict' });
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return null;
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

/** A checked string field: the value, or null when it fails. */
function required(value: unknown, shape: RegExp, max: number): string | null {
  return typeof value === 'string' && value.length <= max && shape.test(value) ? value : null;
}

/** An optional string field: null when absent, the value when it passes, undefined when it fails. */
function optional(value: unknown, shape: RegExp, max: number, blankIsAbsent = false): string | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') return undefined;
  const v = blankIsAbsent ? value.trim() : value;
  if (blankIsAbsent && v === '') return null;
  return v.length <= max && shape.test(v) ? v : undefined;
}

function codePoints(text: string): number {
  let n = 0;
  for (const _ of text) n++;
  return n;
}

// ---------------------------------------------------------------------------
// The Sentry envelope

export interface DSN {
  key: string;
  host: string;
  projectId: string;
}

/** `https://<key>@<host>/<projectId>`, or null when it is not one. */
export function parseDsn(dsn: string | undefined): DSN | null {
  if (!dsn) return null;
  try {
    const url = new URL(dsn);
    const projectId = url.pathname.replace(/^\/+|\/+$/g, '');
    if (url.protocol !== 'https:' || !/^[0-9a-f]{32}$/.test(url.username) || !/^\d+$/.test(projectId)) return null;
    return { key: url.username, host: url.host, projectId };
  } catch {
    return null;
  }
}

export const envelopeUrl = (dsn: DSN) => `https://${dsn.host}/api/${dsn.projectId}/envelope/`;

export const SDK = { name: 'pacer.site-worker', version: '1.0.0' };

/**
 * A Sentry envelope with one `feedback` item and an attachment item per file
 * (develop.sentry.dev, envelopes): newline-separated JSON headers, each item's
 * payload exactly `length` bytes. Built from checked values only, with no
 * address anywhere: `user` carries the install id or nothing, and the SDK
 * settings tell Sentry not to infer one.
 */
export function buildEnvelope(f: Feedback, siteEnvironment: string, eventId: string, now: Date): Blob {
  const attachments = [...f.attachments];
  let message = f.message;
  if (codePoints(message) > SENTRY_MESSAGE_MAX) {
    const note = `\n\n[continues in ${FULL_MESSAGE_FILENAME}]`;
    message = Array.from(message).slice(0, SENTRY_MESSAGE_MAX - codePoints(note)).join('') + note;
    attachments.push({ filename: FULL_MESSAGE_FILENAME, contentType: 'text/plain', bytes: new TextEncoder().encode(f.message) });
  }
  const dev = f.devDescribe !== null;
  // No `name`: Sentry shows it as the reporter's name. The kind is a tag.
  const feedback: Record<string, unknown> = { message, source: 'website-proxy' };
  if (f.email) feedback.contact_email = f.email;
  const contexts: Record<string, unknown> = {
    feedback,
    os: { name: 'macOS', version: f.macOS.split(' ')[0], ...(f.macOS.includes('(') ? { build: f.macOS.slice(f.macOS.indexOf('(') + 1, -1) } : {}) },
    device: { family: 'Mac', model: f.model },
    app: { app_version: f.appVersion, app_build: f.appBuild, ...(dev ? { dev_describe: f.devDescribe } : {}) },
  };
  if (f.locale) contexts.culture = { locale: f.locale };
  const event: Record<string, unknown> = {
    event_id: eventId,
    timestamp: now.getTime() / 1000,
    // Not "cocoa": Sentry infers a missing address for some platforms.
    platform: 'other',
    level: 'info',
    // The app's own release names (TelemetryController.release), so a report
    // lands beside that build's crashes.
    release: dev ? `com.ericandrechek.pacer@dev+${f.appBuild}` : `com.ericandrechek.pacer@${f.appVersion}+${f.appBuild}`,
    environment: dev ? 'development' : 'production',
    sdk: { ...SDK, settings: { infer_ip: 'never' } },
    tags: {
      kind: f.kind,
      app_version: f.appVersion,
      macos: f.macOS.split(' ')[0],
      model: f.model,
      source: 'website-proxy',
      site_environment: siteEnvironment,
    },
    contexts,
  };
  if (f.installId) event.user = { id: f.installId };

  const encoder = new TextEncoder();
  const newline = encoder.encode('\n');
  const line = (header: object) => encoder.encode(`${JSON.stringify(header)}\n`);
  const payload = encoder.encode(JSON.stringify(event));
  const parts: ArrayBufferView[] = [
    line({ event_id: eventId, sent_at: now.toISOString(), sdk: SDK }),
    line({ type: 'feedback', length: payload.byteLength }),
    payload,
    newline,
  ];
  for (const a of attachments) {
    parts.push(
      line({ type: 'attachment', length: a.bytes.byteLength, filename: a.filename, content_type: a.contentType, attachment_type: 'event.attachment' }),
      a.bytes,
      newline,
    );
  }
  return new Blob(parts);
}

// ---------------------------------------------------------------------------
// The endpoint

function answer(status: number, body: Record<string, unknown>, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...extra },
  });
}

/** A refused request: logged (the reason, never the address or the body), and answered. */
function refused(status: number, error: string, extra: Record<string, string> = {}): Response {
  console.warn(JSON.stringify({ message: 'feedback refused', status, reason: error }));
  return answer(status, { ok: false, error }, extra);
}

/** The body as text, refusing more than `max` bytes whether or not Content-Length is sent. */
async function readCapped(request: Request, max: number): Promise<string | null> {
  const declared = request.headers.get('Content-Length');
  if (declared !== null) {
    if (!/^\d{1,12}$/.test(declared) || Number(declared) > max) return null;
    // The runtime holds the body to its declared length.
    return request.text();
  }
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) {
    all.set(chunk, at);
    at += chunk.byteLength;
  }
  return new TextDecoder().decode(all);
}

/** POST /api/feedback. Answers `{ok: true, id}` once Sentry has accepted the report, or `{ok: false, error}`. */
export async function feedback(request: Request, env: Env, siteEnvironment: string): Promise<Response> {
  if (request.method !== 'POST') return refused(405, 'POST only', { Allow: 'POST' });
  if (!(request.headers.get('User-Agent') ?? '').startsWith('Pacer/')) return refused(403, 'not a Pacer client');
  const type = (request.headers.get('Content-Type') ?? '').toLowerCase();
  if (!/^application\/json\s*(?:;\s*charset=utf-8\s*)?$/.test(type)) return refused(415, 'Content-Type must be application/json');
  const dsn = parseDsn(env.SENTRY_DSN);
  if (!dsn) return refused(503, 'feedback is not configured');

  let parsed: Checked<Feedback>;
  {
    // Scoped so the text and the parsed JSON can be collected once decoded.
    const text = await readCapped(request, MAX_BODY_BYTES);
    if (text === null) return refused(413, 'body larger than 12 MB');
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      return refused(400, 'body is not JSON');
    }
    parsed = parseFeedback(json);
  }
  if (!parsed.ok) return refused(400, parsed.reason);

  const eventId = crypto.randomUUID().replaceAll('-', '');
  const envelope = buildEnvelope(parsed.value, siteEnvironment, eventId, new Date());
  let upstream: Response;
  try {
    upstream = await fetch(envelopeUrl(dsn), {
      method: 'POST',
      // The Worker's own headers only: nothing of the client's request goes on.
      headers: {
        'Content-Type': 'application/x-sentry-envelope',
        'X-Sentry-Auth': `Sentry sentry_version=7, sentry_key=${dsn.key}, sentry_client=${SDK.name}/${SDK.version}`,
      },
      body: envelope,
      redirect: 'manual',
      signal: AbortSignal.timeout(SENTRY_TIMEOUT_MS),
    });
  } catch (err) {
    const timedOut = err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError');
    console.error(JSON.stringify({ message: 'feedback: sentry unreachable', error: String(err) }));
    return answer(502, { ok: false, error: timedOut ? 'Sentry took too long' : 'could not reach Sentry' });
  }
  if (upstream.ok) return answer(200, { ok: true, id: eventId });
  console.error(JSON.stringify({ message: 'feedback: sentry refused', status: upstream.status }));
  if (upstream.status === 429) {
    const retry = upstream.headers.get('Retry-After');
    return answer(429, { ok: false, error: 'Sentry is rate limiting reports' }, retry && /^\d{1,6}$/.test(retry) ? { 'Retry-After': retry } : {});
  }
  if (upstream.status === 413) return answer(413, { ok: false, error: 'Sentry refused the size' });
  return answer(502, { ok: false, error: 'Sentry refused the report' });
}
