// One place for the facts every page repeats. Copy here is sourced from the
// repo's README.md, AGENTS.md, Skills/pacer and docs/release-notes; keep it
// in step with those rather than inventing new claims.
import { latestVersion } from './releases';
import { BREW_COMMAND, REPO } from '../../scripts/discovery.mjs';

export const SITE_NAME = 'Pacer';
export const VERSION = latestVersion();

// The repository and the Homebrew command live in scripts/discovery.mjs, which
// the discovery files (the skill's description among them) are built from.
export { BREW_COMMAND, REPO };
export const RELEASES = `${REPO}/releases`;
export const LATEST_RELEASE = `${REPO}/releases/latest`;
/** The Worker redirects this to the latest release's DMG and counts it (worker/index.ts). */
export const DOWNLOAD_PATH = '/download/';
export const README_PRIVACY = `${REPO}#privacy`;
export const LICENSE_URL = `${REPO}/blob/main/LICENSE`;
export const ISSUES = `${REPO}/issues`;

/**
 * The PostHog project the app reports to (project.yml: PACER_POSTHOG_TOKEN).
 * One project for both surfaces, decided by the owner; web events carry
 * `surface: 'website'` so they never mix with the app's. A project token is
 * public by design: it is compiled into the app. PUBLIC_POSTHOG_TOKEN at build
 * time overrides it, and an empty one turns the site's analytics off.
 */
export const POSTHOG_PROJECT_TOKEN = 'phc_rCT9m6F6y7DwcDSJ5BgHpZECFyvpmsPoyUiLx5pa693A';
export const POSTHOG_HOST = 'https://us.i.posthog.com';

export const REQUIREMENTS = 'macOS 15 (Sequoia) or newer, on Apple silicon or Intel';

export const DEFAULT_TITLE = 'Pacer: Claude Code usage and rate limits in your Mac menu bar';
export const DEFAULT_DESCRIPTION =
  'Pacer is a free, open-source macOS menu-bar app that tracks your Claude Code usage: tokens, cost, ' +
  'and how close you are to your 5-hour, weekly and per-model rate limits. Your usage data stays on your Mac.';

export const OG_IMAGE = {
  path: 'og-card.png',
  width: 1200,
  height: 630,
  alt: "Pacer's dashboard: today's Claude Code cost and the 5-hour and 7-day rate-limit pace charts.",
};

/** For JSON-LD's featureList and llms.txt. Plain, one line each. */
export const FEATURES = [
  'Pace charts for the 5-hour, weekly and per-model rate-limit windows Anthropic reports for your account, with a forecast for each',
  "Cost as Claude Code reports it, or priced by Pacer from tokens at the rate in effect when each request was made",
  'Usage by project (with your own collections), by model and by day, and a six-month activity heatmap',
  'A live burn rate and an end-of-day cost projection',
  'Several Claude accounts, each token attributed to the account that used it; works with claude-swap',
  'A configurable menu-bar readout and six home-screen and Notification Center widgets',
  'Optional local notifications at rate-limit thresholds or a daily spending limit',
  'A pacer command and a Claude Code skill that pause agents before a rate limit and resume them after',
  'CSV export',
];

export const NAV = [
  { href: '/features/', label: 'Features' },
  { href: '/cli/', label: 'For agents' },
  { href: '/how-pacer-counts/', label: 'How it counts' },
  { href: '/privacy/', label: 'Privacy' },
  { href: '/faq/', label: 'FAQ' },
  { href: '/changelog/', label: 'Changelog' },
];
