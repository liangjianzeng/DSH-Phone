import z from "@deepseek-ai/schemastery";
import { WebError } from "@deepseek-ai/dsh-web";

/**
 * SearXNG-backed search provider for the DeepSeek Harness web capability seam
 * (`ctx.web`). Queries a self-hosted SearXNG JSON API — no API key required.
 * @module web-search-searxng
 */

/** Stable id this provider registers under. */
const SEARXNG_PROVIDER_ID = "searxng";

/** Default SearXNG endpoint (assumes the remote instance is reachable on the VPN). */
const SEARXNG_DEFAULT_BASE_URL = "http://100.81.83.59:8080";
const SEARXNG_DEFAULT_SEARCH_PATH = "/search";
/** Default upper bound on one search's wall-clock time (SearXNG waits on engines). */
const SEARXNG_DEFAULT_TIMEOUT_MS = 30000;

/**
 * Map a SearXNG JSON response to the normalized seam result shape.
 * `results[]` carry `title`/`url`/`content`/`publishedDate`; `answers[]`
 * optionally provide a generated answer we surface as `content`.
 * @param data - the parsed SearXNG JSON body.
 * @returns the normalized result (empty `sources` when nothing matched).
 */
function mapSearxngResponse(data) {
	const results = Array.isArray(data?.results) ? data.results : [];
	const sources = [];
	for (const item of results) {
		if (item == null || typeof item !== "object") continue;
		const url = typeof item.url === "string" ? item.url : void 0;
		if (url === void 0 || url.length === 0) continue;
		const title = typeof item.title === "string" && item.title.length > 0 ? item.title : void 0;
		const snippet = typeof item.content === "string" && item.content.length > 0 ? item.content : void 0;
		const publishedAt = typeof item.publishedDate === "string" && item.publishedDate.length > 0 ? item.publishedDate : void 0;
		sources.push({
			url,
			...title !== void 0 ? { title } : {},
			...snippet !== void 0 ? { snippet } : {},
			...publishedAt !== void 0 ? { publishedAt } : {}
		});
	}
	let content;
	const answer = Array.isArray(data?.answers) && data.answers.length > 0 ? data.answers[0] : void 0;
	if (answer != null && typeof answer === "object" && typeof answer.answer === "string" && answer.answer.length > 0) {
		content = answer.answer;
	}
	return {
		...content !== void 0 ? { content } : {},
		sources,
		truncated: false
	};
}

/** The SearXNG-backed search provider; HTTP failures surface as `WEB_PROVIDER_ERROR`. */
var SearxNGProvider = class {
	resolveOptions;
	id = SEARXNG_PROVIDER_ID;
	/**
	 * @param resolveOptions - thunk returning the options for the NEXT operation,
	 *   so one search never mixes two config snapshots.
	 */
	constructor(resolveOptions) {
		this.resolveOptions = resolveOptions;
	}
	available() {
		const options = this.resolveOptions();
		return URL.canParse(options.baseURL + options.searchPath) && Number.isInteger(options.timeoutMs) && options.timeoutMs > 0;
	}
	async search(request, signal) {
		const options = this.resolveOptions();
		const endpoint = new URL(options.baseURL + options.searchPath);
		endpoint.searchParams.set("q", request.query);
		endpoint.searchParams.set("format", "json");
		if (options.engines != null && options.engines.length > 0) endpoint.searchParams.set("engines", options.engines.join(","));
		if (options.language != null && options.language.length > 0) endpoint.searchParams.set("language", options.language);
		// Cooperative cancellation: caller signal + a hard wall-clock timeout.
		const controller = new AbortController();
		const onAbort = () => controller.abort();
		signal?.addEventListener("abort", onAbort, { once: true });
		const timer = setTimeout(() => controller.abort(), options.timeoutMs);
		let response;
		try {
			response = await fetch(endpoint, {
				method: "GET",
				redirect: "follow",
				signal: controller.signal,
				headers: {
					"accept": "application/json",
					"user-agent": "deepseek-harness/0.0.1"
				}
			});
		} catch (error) {
			if (signal?.aborted === true) throw new WebError("SearXNG search aborted", "WEB_ABORTED", { cause: error });
			throw new WebError(`SearXNG search request failed: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		} finally {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
		}
		if (!response.ok) {
			let message = `SearXNG error (HTTP ${response.status})`;
			try {
				const parsed = await response.json();
				if (typeof parsed?.message === "string" && parsed.message.length > 0) message = parsed.message;
			} catch {
				// keep the status-based message when the body is not JSON
			}
			throw new WebError(message, "WEB_PROVIDER_ERROR");
		}
		try {
			return mapSearxngResponse(await response.json());
		} catch (error) {
			if (error instanceof WebError) throw error;
			throw new WebError(`SearXNG returned an unprocessable response body: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		}
	}
};

/** Cordis plugin name used by loader diagnostics. */
const name = "web-search-searxng";
/** The web seam this provider registers into. */
const inject = ["web"];

const Config = z.object({
	baseURL: z.string().default(SEARXNG_DEFAULT_BASE_URL),
	searchPath: z.string().default(SEARXNG_DEFAULT_SEARCH_PATH),
	engines: z.array(z.string()).default([]),
	language: z.string().default(""),
	timeoutMs: z.number().step(1).min(1).default(SEARXNG_DEFAULT_TIMEOUT_MS)
});

/** Project one config section into the options the provider serves its next search with. */
function resolveOptions(config) {
	return {
		baseURL: config.baseURL ?? SEARXNG_DEFAULT_BASE_URL,
		searchPath: config.searchPath ?? SEARXNG_DEFAULT_SEARCH_PATH,
		engines: config.engines,
		language: config.language,
		timeoutMs: config.timeoutMs ?? SEARXNG_DEFAULT_TIMEOUT_MS
	};
}

/** Register the SearXNG search provider with `ctx.web`. */
function apply(ctx, config) {
	let current = () => config;
	ctx.web.registerSearchProvider(new SearxNGProvider(() => resolveOptions(current())));
}

export { Config, SEARXNG_PROVIDER_ID, SearxNGProvider, apply, inject, name };
