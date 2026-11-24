// The deploy gate on the update feed and the price history (scripts/feeds.mjs,
// run on dist/ by `pnpm build`): it must pass the files on main and refuse
// every way a copy has gone, or could go, wrong.
import { describe, expect, it } from 'vitest';
import { appcastProblems, priceHistoryProblems, xmlProblems } from '../scripts/feeds.mjs';
import liveAppcast from '../public/appcast.xml?raw';
import livePrices from '../public/price-history.json?raw';

const SIG = 'sparkle:edSignature="' + 'A'.repeat(86) + '=="';
const DMG = 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3.dmg';
const DELTA = 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3-from-0.9.2.delta';
const FEED = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Pacer</title>
        <item>
        <title>Version 0.9.3</title>
        <description><![CDATA[<p>Notes may quote <item> and <sparkle:deltas> & such.</p>]]></description>
        <sparkle:version>1795528779</sparkle:version>
        <sparkle:shortVersionString>0.9.3</sparkle:shortVersionString>
        <enclosure
            url="${DMG}"
            length="158198699"
            type="application/octet-stream"
            ${SIG} />
        <sparkle:deltas>
            <enclosure url="${DELTA}" sparkle:deltaFrom="1794840834" length="6500000" type="application/octet-stream" ${SIG} />
        </sparkle:deltas>
    </item>
        </channel>
</rss>
`;

describe('the files on main', () => {
  it('public/appcast.xml is fit to deploy', () => {
    expect(appcastProblems(liveAppcast)).toEqual([]);
    expect((liveAppcast.match(/<item>/g) ?? []).length).toBeGreaterThan(0);
  });

  it('public/price-history.json is fit to deploy', () => {
    expect(priceHistoryProblems(livePrices)).toEqual([]);
  });
});

describe('appcastProblems', () => {
  it('passes a feed with a full update and a delta, notes quoting markup', () => {
    expect(appcastProblems(FEED)).toEqual([]);
  });

  const broken: Record<string, string> = {
    'a truncated feed (a partial write)': FEED.slice(0, -30),
    'an attribute given twice': FEED.replace('length="158198699"', 'length="158198699" length="158198699"'),
    'a bare ampersand outside CDATA': FEED.replace('<title>Pacer</title>', '<title>Pacer & co</title>'),
    'no signature on the full update': FEED.replace(/(url="[^"]+\.dmg"[\s\S]*?)sparkle:edSignature="[^"]*"/, '$1'),
    'no signature on a delta': FEED.replace(/(sparkle:deltaFrom="\d+"[^>]*?)sparkle:edSignature="[^"]*"/, '$1'),
    'a DMG somewhere else': FEED.replace(DMG, 'https://evil.example/Pacer-0.9.3.dmg'),
    'a delta somewhere else': FEED.replace(DELTA, 'https://evil.example/x.delta'),
    'a zero length': FEED.replace('length="158198699"', 'length="0"'),
    'no build number': FEED.replace('<sparkle:version>1795528779</sparkle:version>', ''),
    'a marketing version that is not X.Y.Z': FEED.replace('>0.9.3</sparkle:shortVersionString>', '>0.9</sparkle:shortVersionString>'),
    'the same build twice': FEED.replace('    </item>', '    </item>\n' + /<item>[\s\S]*?<\/item>/.exec(FEED)![0]),
    'no items': FEED.replace(/<item>[\s\S]*?<\/item>/, ''),
    'two roots': FEED + '<rss></rss>',
    'an HTML error page': '<!doctype html><html><body>Not found</body></html>',
    'GitHub Pages’ 404 page with a 200': '<html><head><title>404</title></head></html>',
    'an empty file': '',
    'JSON': '{"schema":1}',
  };
  for (const [what, text] of Object.entries(broken)) {
    it(`refuses ${what}`, () => {
      expect(text).not.toBe(FEED); // the fixture really is broken
      expect(appcastProblems(text)).not.toEqual([]);
    });
  }
});

describe('xmlProblems', () => {
  it('treats CDATA, comments and the declaration as opaque', () => {
    expect(xmlProblems('<?xml version="1.0"?><a><!-- <b> & --><![CDATA[ <c> & ]]><d x="1"/></a>')).toEqual([]);
  });

  it('accepts entities and refuses mismatched or unclosed tags', () => {
    expect(xmlProblems('<a t="&amp;&#38;&#x26;">&lt;&gt;&quot;&apos;</a>')).toEqual([]);
    expect(xmlProblems('<a><b></a></b>')).not.toEqual([]);
    expect(xmlProblems('<a><b>')).not.toEqual([]);
    expect(xmlProblems('<a t="x & y"/>')).not.toEqual([]);
  });
});

describe('priceHistoryProblems', () => {
  const row = {
    model: 'claude-sonnet-5',
    effectiveFrom: '2026-06-30',
    perMTok: { input: 2, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4 },
  };
  const file = (over: Record<string, unknown> = {}) => JSON.stringify({ schema: 1, asOf: '2026-11-11', records: [row], ...over });

  it('passes what CuratedPriceHistory decodes', () => {
    expect(priceHistoryProblems(file())).toEqual([]);
  });

  const broken: Record<string, string> = {
    'not JSON': '{"schema":',
    'another schema': file({ schema: 2 }),
    'no asOf': file({ asOf: undefined }),
    'no records': file({ records: [] }),
    'a record without rates': file({ records: [{ ...row, perMTok: { input: 2 } }] }),
    'a record without a model': file({ records: [{ ...row, model: '' }] }),
    'an array': '[]',
  };
  for (const [what, text] of Object.entries(broken)) {
    it(`refuses ${what}`, () => {
      expect(priceHistoryProblems(text)).not.toEqual([]);
    });
  }
});
