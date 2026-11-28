// The part of @wave-rf/cloudflare-md-router (0.6.0, src/worker.ts) the Worker uses.
export interface MdRouterOptions {
  botUserAgents?: RegExp | false;
  mdPathFor?: (pathname: string) => string;
  acceptMarkdown?: string[];
  advertiseTwin?: boolean;
  vary?: boolean;
  checkTwin?: boolean;
  advertiseLlmsTxt?: boolean | string;
  canonicalOrigin?: string;
}
/** The LLM crawlers the router serves Markdown to (src/bots.ts). */
export declare const LLM_BOT_UA: RegExp;
export declare function createMdRouter<Env extends { ASSETS: Fetcher }>(options?: MdRouterOptions): ExportedHandler<Env>;
