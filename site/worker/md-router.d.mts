// The part of @wave-rf/cloudflare-md-router (0.5.0, src/worker.ts) the Worker uses.
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
export declare function createMdRouter<Env extends { ASSETS: Fetcher }>(options?: MdRouterOptions): ExportedHandler<Env>;
