// The FAQ, used by the page and its FAQPage JSON-LD. Answers are small HTML
// fragments (links, code, emphasis only); JSON-LD gets them as plain text.
// Every answer is sourced from README.md, Skills/pacer or docs/release-notes.
import { BREW_COMMAND, REQUIREMENTS } from './site';

export interface Faq {
  id: string;
  q: string;
  a: string;
}

export const FAQ: Faq[] = [
  {
    id: 'price',
    q: 'Is Pacer free?',
    a: 'Yes. Pacer is free and open source under the <a href="https://github.com/EricAndrechek/Pacer/blob/main/LICENSE">MIT license</a>. There is no paid version.',
  },
  {
    id: 'requirements',
    q: 'What do I need to run it?',
    a: `${REQUIREMENTS}, and Claude Code. One build serves every supported macOS version. On macOS 26 and newer Pacer uses the system's Liquid Glass design.`,
  },
  {
    id: 'install',
    q: 'How do I install it?',
    a: `Download the DMG, open it and drag Pacer into Applications. Or run <code>${BREW_COMMAND}</code>. Pacer lives in the menu bar, with no Dock icon. The first time, macOS asks whether Pacer may read Claude Code's files: click Allow, because that is how Pacer sees your usage.`,
  },
  {
    id: 'updates',
    q: 'How does it update?',
    a: 'By itself. When a new version ships, Pacer downloads it and installs it while you are not using Pacer. Updates download only what changed, usually a few megabytes.',
  },
  {
    id: 'data',
    q: 'Does my usage data leave my Mac?',
    a: 'No. Your usage data stays on your Mac. Pacer reads Claude Code\'s own files and uses your Claude Code login only to ask Anthropic for your rate limits. Crash reports and anonymous usage stats are sent, and each can be turned off: see <a href="/privacy/">Privacy</a>.',
  },
  {
    id: 'limits-source',
    q: 'Where do the rate-limit percentages come from?',
    a: 'From Anthropic, using your Claude Code login, refreshed every few minutes. Between readings Pacer estimates the meter from what you have spent since the last one: an estimate has a decimal (42.6%), a reading does not (42%).',
  },
  {
    id: 'ccusage',
    q: 'Why don\'t Pacer\'s numbers match ccusage?',
    a: 'Mostly on purpose. Pacer counts a streamed reply\'s finished copy, prices each request at the rate in effect when it was made, and keeps the two kinds of cache write apart. <a href="/how-pacer-counts/">How Pacer counts</a> lists each difference.',
  },
  {
    id: 'accounts',
    q: 'Does it work with more than one Claude account?',
    a: 'Yes. Every token and dollar is attributed to the account that used it, and a toolbar menu scopes the whole app to one account or all of them. Rate limits show the account you are signed into. Pacer follows a switch made with <a href="https://github.com/realiti4/claude-swap">claude-swap</a>, <code>/logout</code> or a <code>CLAUDE_CONFIG_DIR</code> profile.',
  },
  {
    id: 'ultra',
    q: 'I\'m on an Ultra plan. Where is my 5-hour window?',
    a: 'Ultra plans have no 5-hour limit, so Pacer shows the weekly and per-model windows only.',
  },
  {
    id: 'desktop',
    q: 'Does it count Claude Desktop?',
    a: 'Claude Desktop\'s agent-mode (Cowork) sessions count, under a "Claude Desktop (agent)" project, and on the account Desktop is signed into. Pacer does not track tools other than Claude Code and Claude Desktop.',
  },
  {
    id: 'cli',
    q: 'How do I get the pacer command?',
    a: 'A Homebrew install puts <code>pacer</code> on your PATH. With the download, use Settings → Integrations → Command line. The Claude Code skill installs from Settings too. See <a href="/cli/">For agents</a>.',
  },
  {
    id: 'notifications',
    q: 'Will it send me notifications?',
    a: 'Only if you turn them on. Pacer can alert you when a rate-limit window crosses 50, 75 or 90%, on any window, or when you pass a daily spending limit you set. Notifications are off by default.',
  },
  {
    id: 'anthropic',
    q: 'Is Pacer made by Anthropic?',
    a: 'No. Pacer reads data from Anthropic\'s Claude Code but is not affiliated with or endorsed by Anthropic.',
  },
  {
    id: 'early',
    q: 'Is it stable?',
    a: 'Pacer is before 1.0 and under active development. It works and is useful today, but expect the occasional rough edge. Report problems from the app (Report a Problem) or on <a href="https://github.com/EricAndrechek/Pacer/issues">GitHub</a>.',
  },
];

/** Plain text of an answer, for JSON-LD and llms.txt. */
export const faqText = (html: string) =>
  html
    .replace(/<[^>]+>/g, '')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
