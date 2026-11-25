import z from "@deepseek-ai/schemastery";
import { WebError } from "@deepseek-ai/dsh-web";
//#region lib/types/types.js
/**
* Shared vocabulary for the localxng direct-engine search plugin.
* @module @deepseek-ai/dsh-web-search-localxng/types
*/
/** Failure of one engine (the aggregator turns it into cooldown + status). */
var SearchEngineError = class extends Error {
	engineId;
	kind;
	constructor(engineId, kind, message) {
		super(message);
		this.engineId = engineId;
		this.kind = kind;
		this.name = "SearchEngineError";
	}
};
/** Known engine ids, in default priority order. */
const DIRECT_ENGINE_IDS = [
	"bing_cn",
	"baidu",
	"sogou",
	"so360",
	"quark",
	"chinaso"
];
/** Realistic browser UA pool for session-level rotation. */
const USER_AGENT_POOL = [
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
	"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
];
/** Classify a 3xx response into an error, or `undefined` when not a redirect. */
function redirectError(status, location, engineId) {
	if (status < 300 || status >= 400) return void 0;
	const loc = (location ?? "").trim();
	const lower = loc.toLowerCase();
	const blocked = lower.includes("wappass") || lower.includes("antispider") || lower.includes("captcha") || lower.includes("verify") || lower.includes(" passport.");
	return new SearchEngineError(engineId, blocked ? "blocked" : "network", blocked ? `被重定向到风控页：${loc}` : `HTTP ${status} 重定向到 ${loc}`);
}
/**
* Per-engine cookie/UA session store producing {@link FetchPage} functions.
* One instance serves all engines (each engine gets its own jar and identity).
*/
var EngineHttpSession = class {
	states = /* @__PURE__ */ new Map();
	rng;
	requestTimeoutMs;
	retryDelayMs;
	constructor(options = {}, rng = Math.random) {
		this.requestTimeoutMs = options.requestTimeoutMs ?? 12e3;
		this.retryDelayMs = options.retryDelayMs ?? 400;
		this.rng = rng;
	}
	/** FetchPage for one engine; `seed` preheats the host homepage once for cookies. */
	forEngine(engineId, seed = false) {
		return async (url, extraHeaders) => {
			const state = this.stateOf(engineId);
			if (seed && !state.seeded) {
				state.seeded = true;
				try {
					await this.get(engineId, new URL("/", url), void 0);
				} catch {}
			}
			try {
				return await this.get(engineId, url, extraHeaders);
			} catch (error) {
				if (error instanceof SearchEngineError) throw error;
				await delay(this.retryDelayMs);
				return this.get(engineId, url, extraHeaders);
			}
		};
	}
	/** Drop one engine's cookie session and rotate its UA (a fresh identity). */
	clearSession(engineId) {
		this.states.delete(engineId);
	}
	stateOf(engineId) {
		let state = this.states.get(engineId);
		if (state === void 0) {
			state = {
				cookies: /* @__PURE__ */ new Map(),
				userAgent: USER_AGENT_POOL[Math.floor(this.rng() * USER_AGENT_POOL.length)] ?? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
				seeded: false
			};
			this.states.set(engineId, state);
		}
		return state;
	}
	async get(engineId, url, extraHeaders) {
		const state = this.stateOf(engineId);
		const headers = {
			"user-agent": state.userAgent,
			"accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
			"accept-language": "zh-CN,zh;q=0.9",
			...cookieHeader(state.cookies),
			...extraHeaders
		};
		const timeout = AbortSignal.timeout(this.requestTimeoutMs);
		const response = await fetch(url, {
			redirect: "manual",
			headers,
			signal: timeout
		});
		absorbCookies(state.cookies, response);
		const status = response.status;
		const redirect = redirectError(status, response.headers.get("location"), engineId);
		if (redirect !== void 0) throw redirect;
		if (status >= 400) throw new SearchEngineError(engineId, "network", `HTTP ${status}（${url.host}）`);
		return response.text();
	}
};
function cookieHeader(jar) {
	if (jar.size === 0) return {};
	return { cookie: [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ") };
}
function absorbCookies(jar, response) {
	const setCookies = response.headers.getSetCookie?.call(response.headers) ?? [];
	for (const sc of setCookies) {
		const pair = sc.split(";")[0]?.trim() ?? "";
		const eq = pair.indexOf("=");
		if (eq <= 0) continue;
		jar.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
	}
}
function delay(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}
//#endregion
//#region lib/types/link-resolver.js
/**
* Redirect-link resolver: turns search-engine redirect links into real target
* URLs. Field-tested shapes (TongYi-Lite `docs/websearch_direct_2026-10-02.md` §1.1):
* - `baidu.com/link?url=` / `chinaso.com/link?url=` → **302 Location** carries
*   the real URL;
* - `sogou.com/link?url=` / `so.com/link?m=` → HTTP 200 whose body embeds the
*   target in a meta-refresh / `URL='...'` JS snippet.
* href values parsed from HTML attributes must be entity-decoded before use
* (`&amp;`→`&`), or the 302 Location comes back garbled.
*
* Resolution is best-effort: any failure returns `undefined` and the caller
* keeps the redirect link.
* @module @deepseek-ai/dsh-web-search-localxng/link-resolver
*/
/** True when the URL is a redirect link that needs resolving. */
function isRedirectLink(url) {
	return url.includes("/link?") && (url.includes("baidu.com/link") || url.includes("sogou.com/link") || url.includes("so.com/link") || url.includes("chinaso.com/link"));
}
/** Resolve redirect links (≤2 hops). Never throws. */
var LinkResolver = class {
	timeoutMs;
	userAgent;
	constructor(options = {}) {
		this.timeoutMs = options.timeoutMs ?? 6e3;
		this.userAgent = options.userAgent || "Mozilla/5.0";
	}
	async resolve(rawUrl) {
		let url = rawUrl;
		for (let hop = 0; hop < 2; hop++) {
			let next;
			try {
				next = await this.probe(url);
			} catch {
				return;
			}
			if (next === void 0) return void 0;
			if (!isRedirectLink(next)) return next;
			url = next;
		}
	}
	/** One probe: return the next-hop URL, or `undefined` when none is found. */
	async probe(url) {
		const response = await fetch(url, {
			redirect: "manual",
			headers: {
				"user-agent": this.userAgent,
				"accept-language": "zh-CN,zh;q=0.9"
			},
			signal: AbortSignal.timeout(this.timeoutMs)
		});
		const status = response.status;
		if (status >= 300 && status < 400) {
			const location = response.headers.get("location")?.trim();
			return location === void 0 || location === "" ? void 0 : absolute(location, url);
		}
		const body = await response.text();
		if (body === "") return void 0;
		const match = /URL\s*=\s*'?([^'">]+)/i.exec(body) ?? /location(?:\.href)?\s*[=.]\s*["']([^"']+)["']/i.exec(body) ?? /http-equiv=["']?refresh["']?[^>]*url=([^"'>]+)/i.exec(body);
		if (match === null) return void 0;
		return absolute(match[1].trim(), url);
	}
};
function absolute(next, base) {
	try {
		return new URL(next, base).toString();
	} catch {
		return;
	}
}
//#endregion
//#region lib/types/engines/html.js
/**
* HTML/XML text-cleaning helpers shared by every engine parser.
*
* Faithful port of TongYi-Lite `lib/websearch/src/html_text.dart` — keep the
* entity-decoding ORDER intact: the named pass runs before the numeric pass
* and `&amp;` is decoded inside it, so `&amp;lt;` collapses to `<` exactly
* like the Dart original.
* @module @deepseek-ai/dsh-web-search-localxng/engines/html
*/
/** Remove comments, then strip all tags, keeping text content only. */
function stripTags(html) {
	return html.replaceAll(/<!--[\s\S]*?-->/g, "").replaceAll(/<[^>]+>/g, "");
}
/**
* Decode the named entities that dominate search-result pages plus a numeric
* (decimal/hex) fallback. Sequential replacements mirror the Dart original —
* do not reorder them.
*/
function decodeEntities(s) {
	let out = s.replaceAll("&nbsp;", " ").replaceAll("&ensp;", " ").replaceAll("&emsp;", " ").replaceAll("&amp;", "&").replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&quot;", "\"").replaceAll("&#39;", "'").replaceAll("&apos;", "'").replaceAll("&mdash;", "—").replaceAll("&ndash;", "–").replaceAll("&hellip;", "…").replaceAll("&middot;", "·").replaceAll("&#0183;", "·").replaceAll("&#183;", "·").replaceAll("&#8203;", "");
	out = out.replaceAll(/&#(\d+);/g, (m, d) => {
		const v = Number.parseInt(d, 10);
		return Number.isNaN(v) ? m : String.fromCharCode(v);
	});
	out = out.replaceAll(/&#x([0-9a-fA-F]+);/g, (m, h) => {
		const v = Number.parseInt(h, 16);
		return Number.isNaN(v) ? m : String.fromCharCode(v);
	});
	return out;
}
/** Collapse all whitespace runs (snippets ship with newlines / multi-space). */
function collapseWhitespace(s) {
	return s.replaceAll(/\s+/g, " ").trim();
}
/** The triple: strip tags → decode entities → collapse whitespace. */
function htmlToText(html) {
	return collapseWhitespace(decodeEntities(stripTags(html)));
}
//#endregion
//#region lib/types/engines/common.js
/**
* Parsing helpers shared by the engine result-page parsers (regex block
* splitting / attribute extraction / snippet-element lookup).
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/common.dart`.
*
* Constraints/pitfalls carried over from the Dart original:
* - Result-page snippet elements are always "leaves" (no nested same-name
*   tag inside), so grabbing content up to the first `</tag>` is safe; truly
*   nested containers (e.g. 360's `res-rich` block) only appear on fallback
*   paths where clipping a bit is acceptable.
* - Attribute values may be single- or double-quoted (360's templates lean
*   heavily on single-quote classes), so both forms are extracted.
* @module @deepseek-ai/dsh-web-search-localxng/engines/common
*/
/** Escape a literal for embedding into a RegExp (Dart `RegExp.escape`). */
function escapeRegExp(s) {
	return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
/** Strip HTML comments. Result blocks carry markers like `<!--s-text-->`, `<!--VR OK-->`; removing them first keeps regexes clean (sogou titles have `<!--awbg1-->` right before the anchor). */
function stripHtmlComments(html) {
	return html.replaceAll(/<!--[\s\S]*?-->/g, "");
}
/**
* Split `body` into blocks at every match of [startPattern]:
* block i runs from match i's start to match i+1's start (last one to EOF).
* Accepts a literal string or a RegExp; both match non-overlapping like
* Dart's `Pattern.allMatches`.
*/
function splitBlocks(body, startPattern) {
	const starts = [];
	if (typeof startPattern === "string") {
		let i = body.indexOf(startPattern);
		while (i !== -1) {
			starts.push(i);
			i = body.indexOf(startPattern, i + startPattern.length);
		}
	} else {
		const flags = startPattern.flags.includes("g") ? startPattern.flags : `${startPattern.flags}g`;
		for (const m of body.matchAll(new RegExp(startPattern.source, flags))) starts.push(m.index);
	}
	const blocks = [];
	for (let i = 0; i < starts.length; i++) {
		const end = i + 1 < starts.length ? starts[i + 1] : body.length;
		blocks.push(body.slice(starts[i], end));
	}
	return blocks;
}
/**
* Extract an attribute value. The attribute name must be preceded by
* whitespace or string start (so `mu` cannot hit a `xxmu=` tail); both quote
* styles supported; HTML entities are decoded (baidu `mu`, 360 `mdurl` carry
* `&amp;`). Returns `null` when absent.
*/
function attrValue(html, name) {
	const m = new RegExp(`(?:^|[\\s])${escapeRegExp(name)}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`).exec(html);
	if (m === null) return null;
	return decodeEntities(m[1] ?? m[2] ?? "").trim();
}
/**
* First `<[tag]...><a href="...">title</a>` inside a chunk.
* Title anchors often nest `<em>` highlights / spans — cleaned via
* {@link htmlToText}. Returns `null` for missing link or empty title
* (callers skip such "noise blocks").
*/
function firstTitleLink(chunk, tag = "h3") {
	const h = new RegExp(`<${tag}(?=[\\s>])[^>]*>`, "i").exec(chunk);
	if (h === null) return null;
	const rest = chunk.slice(h.index + h[0].length);
	const a = /<a(?=[\s>])[^>]*>/i.exec(rest);
	if (a === null) return null;
	const href = attrValue(a[0], "href");
	if (href === null || href === "") return null;
	const close = rest.indexOf("</a>", a.index + a[0].length);
	if (close < 0) return null;
	const title = htmlToText(rest.slice(a.index + a[0].length, close));
	if (title === "") return null;
	return {
		href,
		title
	};
}
/** {@link firstTitleLink} with `h3` (the title carrier on so360/sogou/baidu). */
function firstH3Link(chunk) {
	return firstTitleLink(chunk, "h3");
}
/**
* First [tag] element whose class has a token starting with one of
* [prefixes]; returns its cleaned text. Snippet classes carry hash suffixes
* (baidu `summary-text_15QGa`) or suffix variants (360 `res-desc` /
* `res-list-summary`), so prefix matching is required.
*/
function firstClassTokenText(chunk, tag, prefixes) {
	const openRe = new RegExp(`<${tag}(?=[\\s>])[^>]*>`, "gi");
	for (const m of chunk.matchAll(openRe)) {
		const cls = attrValue(m[0], "class");
		if (cls === null || cls === "") continue;
		if (!cls.split(/\s+/).some((c) => prefixes.some((p) => c.startsWith(p)))) continue;
		const close = chunk.indexOf(`</${tag}>`, m.index + m[0].length);
		if (close < 0) continue;
		const text = htmlToText(chunk.slice(m.index + m[0].length, close));
		if (text !== "") return text;
	}
	return null;
}
/** Lowercased host of a URL; '' when unparseable (redirect links are entity-decoded before parsing). */
function hostOf(url) {
	try {
		return new URL(url).hostname.toLowerCase();
	} catch {
		return "";
	}
}
/** Whether [host] equals [domain] or is a subdomain of it (stops `evilbing.com` matching bing.com). */
function hostMatchesDomain(host, domain) {
	return host === domain || host.endsWith(`.${domain}`);
}
/**
* Uniform fetch wrapper: {@link SearchEngineError} thrown by the injected
* fetch passes through untouched; anything else (network stacks, exotic
* statuses) is wrapped as `network`.
*/
async function fetchPageOrNetworkError(engineId, fetch, url, extraHeaders) {
	try {
		return await fetch(url, extraHeaders);
	} catch (error) {
		if (error instanceof SearchEngineError) throw error;
		throw new SearchEngineError(engineId, "network", `抓取失败: ${String(error)}`);
	}
}
/** Clamp parsed [hits] to the caller's limit (multi-block parsing may over-produce). */
function takeLimit(hits, limit) {
	return hits.length <= limit ? hits : hits.slice(0, limit);
}
/**
* Unix seconds → `YYYY-MM-DD` in the LOCAL timezone — faithful to Dart's
* `DateTime.fromMillisecondsSinceEpoch(...).toIso8601String().substring(0, 10)`.
*/
function unixSecondsToIsoDate(seconds) {
	const d = /* @__PURE__ */ new Date(seconds * 1e3);
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
//#endregion
//#region lib/types/engines/baidu.js
/**
* Baidu (www.baidu.com) adapter.
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/baidu_engine.dart`.
*
* Primary path = the `tn=json` structured endpoint
* (`/s?wd=&rn=&pn=0&tn=json`, aligned with SearXNG's baidu.py general form),
* returning `data.feed.entry[]` (title/url/abs/time) — far more stable than
* HTML; only when the response is not JSON (redesign / risk-control variant)
* does it fall back to HTML parsing. Under risk control it 302s to the
* wappass captcha page; the HTTP layer's redirect classification marks that
* `blocked` (redirects are NOT followed).
*
* Constraints/pitfalls carried over from the Dart original:
* - Baidu is the least stable engine and this adapter is deliberately thin:
*   when parsing fails it throws and lets the aggregator circuit-break;
* - On the HTML path the real URL sits in the block's `mu="..."` attribute
*   (attribute extraction must be word-bounded, otherwise it hits tails like
*   `m-name=`); without it the href is kept (baidu.com/link redirect form);
* - Snippet classes must be prefix-matched (`summary-text_15QGa` hash
*   suffixes); summary-text span first, then content-right/c-abstract;
* - Navigation blocks (image.baidu.com/video.baidu.com/top.baidu.com or
*   titles ending in "百度图片" etc.) and ad blocks (block class starting
*   with `ec-`) are always skipped.
* @module @deepseek-ai/dsh-web-search-localxng/engines/baidu
*/
const BAIDU_ENGINE_ID = "baidu";
var BaiduEngine = class BaiduEngine {
	id = BAIDU_ENGINE_ID;
	displayName = "百度";
	fetch;
	constructor(fetch) {
		this.fetch = fetch;
	}
	async search(query, limit = 8) {
		const n = Math.min(Math.max(limit, 1), 50);
		const url = new URL("https://www.baidu.com/s");
		url.searchParams.set("wd", query);
		url.searchParams.set("rn", String(n));
		url.searchParams.set("pn", "0");
		url.searchParams.set("tn", "json");
		const body = await fetchPageOrNetworkError(this.id, this.fetch, url);
		if (body.trimStart().startsWith("{")) return takeLimit(BaiduEngine.parseJsonPage(body), limit);
		return takeLimit(BaiduEngine.parsePage(body), limit);
	}
	/** Parse a `tn=json` response. Shape (field-tested / SearXNG-aligned): `{"data":{"feed":{"entry":[{"title","url","abs","time"},...]}}}`; time is Unix seconds (may be absent). Risk-control pages can also come wrapped in JSON (status!=0). */
	static parseJsonPage(body) {
		let decoded;
		try {
			decoded = JSON.parse(body);
		} catch {
			throw new SearchEngineError(BAIDU_ENGINE_ID, "parse", "tn=json 响应不是合法 JSON");
		}
		if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) throw new SearchEngineError(BAIDU_ENGINE_ID, "parse", "tn=json 顶层不是对象");
		const root = decoded;
		const status = root["status"];
		if (typeof status === "number" && status !== 0) throw new SearchEngineError(BAIDU_ENGINE_ID, "blocked", `tn=json 返回 status=${status}（疑似风控/异常）`);
		const feed = asPlainObject(asPlainObject(root["data"])?.["feed"]) ?? {};
		const entries = Array.isArray(feed["entry"]) ? feed["entry"] : [];
		const hits = [];
		for (const e of entries) {
			if (typeof e !== "object" || e === null || Array.isArray(e)) continue;
			const entry = e;
			const title = htmlToText(dynString$2(entry["title"]));
			const url = dynString$2(entry["url"]).trim();
			if (title === "" || url === "") continue;
			const abs = htmlToText(dynString$2(entry["abs"]));
			const time = tryParseInt$1(dynString$2(entry["time"]).trim());
			const hit = {
				title,
				url,
				engine: BAIDU_ENGINE_ID
			};
			if (abs !== "") hit.snippet = abs;
			if (time !== null && time > 0) hit.publishedAt = unixSecondsToIsoDate(time);
			hits.push(hit);
		}
		if (hits.length === 0) throw new SearchEngineError(BAIDU_ENGINE_ID, "empty", "tn=json 0 条结果");
		return hits;
	}
	/** Parse an HTML result page (tn=json fallback). Block-split on `<div class="result c-container">`. */
	static parsePage(body) {
		if (body.includes("百度安全验证")) throw new SearchEngineError(BAIDU_ENGINE_ID, "blocked", "百度触发安全验证");
		const blocks = splitBlocks(stripHtmlComments(body), /<div[^>]*class="result c-container/);
		if (blocks.length === 0) throw new SearchEngineError(BAIDU_ENGINE_ID, "parse", "百度页面结构不认识（无 result c-container）");
		const hits = [];
		for (const block of blocks) {
			const gt = block.indexOf(">");
			if ((attrValue(gt < 0 ? block : block.slice(0, gt + 1), "class") ?? "").split(/\s+/).some((c) => c.startsWith("ec-"))) continue;
			const h3 = firstH3Link(block);
			if (h3 === null) continue;
			const href = h3.href;
			if (href.includes("image.baidu.com") || href.includes("video.baidu.com") || href.includes("top.baidu.com")) continue;
			if (h3.title.includes("百度图片") || h3.title.includes("百度视频") || h3.title.includes("百度热榜")) continue;
			const url = attrValue(block, "mu") ?? href;
			const snippet = firstClassTokenText(block, "span", ["summary-text"]) ?? firstClassTokenText(block, "div", ["content-right", "c-abstract"]) ?? firstClassTokenText(block, "span", ["content-right", "c-abstract"]);
			hits.push({
				title: h3.title,
				url,
				...snippet !== null ? { snippet } : {},
				engine: BAIDU_ENGINE_ID
			});
		}
		if (hits.length === 0) throw new SearchEngineError(BAIDU_ENGINE_ID, "empty", "百度 0 条结果（全部为导航/广告块）");
		return hits;
	}
};
/** Dart `'${x ?? ''}'` string interpolation over a dynamic JSON value. */
function dynString$2(v) {
	return v === null || v === void 0 ? "" : String(v);
}
/** Dart `int.tryParse` equivalent (optional sign, decimal digits only). */
function tryParseInt$1(s) {
	return /^[+-]?\d+$/.test(s) ? Number.parseInt(s, 10) : null;
}
function asPlainObject(v) {
	return typeof v === "object" && v !== null && !Array.isArray(v) ? v : null;
}
//#endregion
//#region lib/types/engines/bing-cn.js
/**
* Bing (cn.bing.com) adapter.
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/bing_cn_engine.dart`.
*
* Constraints/pitfalls carried over from the Dart original:
* - The RSS endpoint (format=rss) is the most stable in the field: direct
*   links + snippets + dates all present, so it goes first;
* - RSS occasionally serves 0 `<item>`s (soft risk-control failure, HTTP
*   still 200) → fall back to fetching the same query's HTML page (without
*   format=rss; `b_algo` blocks);
* - pubDate uses Chinese month names (`周四, 01 10月 2026 21:29:00 GMT`),
*   which standard parsers choke on — the "day month year" trio is picked
*   out by hand;
* - Bing's risk-control page is not a captcha (text says "异常流量"),
*   classified as kind=parse per spec.
* @module @deepseek-ai/dsh-web-search-localxng/engines/bing-cn
*/
const BING_CN_ENGINE_ID = "bing_cn";
var BingCnEngine = class BingCnEngine {
	id = BING_CN_ENGINE_ID;
	displayName = "必应";
	fetch;
	constructor(fetch) {
		this.fetch = fetch;
	}
	async search(query, limit = 8) {
		const count = Math.min(Math.max(limit, 1), 20);
		const url = new URL("https://cn.bing.com/search");
		url.searchParams.set("q", query);
		url.searchParams.set("format", "rss");
		url.searchParams.set("mkt", "zh-CN");
		url.searchParams.set("count", String(count));
		const body = await fetchPageOrNetworkError(this.id, this.fetch, url);
		const hits = takeLimit(BingCnEngine.parseRss(body), limit);
		if (hits.length > 0) return hits;
		const htmlUrl = new URL(url.href);
		htmlUrl.searchParams.delete("format");
		const htmlBody = await fetchPageOrNetworkError(this.id, this.fetch, htmlUrl);
		return takeLimit(BingCnEngine.parseHtml(htmlBody), limit);
	}
	/** Parse an RSS body. 0 `<item>`s → empty list (search() handles the HTML fallback). Risk-control: body contains "异常流量" → kind=parse. */
	static parseRss(body) {
		if (body.includes("异常流量")) throw new SearchEngineError(BING_CN_ENGINE_ID, "parse", "必应返回异常流量拦截页");
		const hits = [];
		for (const item of splitBlocks(body, "<item>")) {
			const title = tagText(item, "title");
			const link = tagText(item, "link");
			if (title === null || title === "" || link === null || link === "") continue;
			const hit = {
				title,
				url: link,
				engine: BING_CN_ENGINE_ID
			};
			const snippet = tagText(item, "description");
			if (snippet !== null) hit.snippet = snippet;
			const publishedAt = formatPubDate(tagText(item, "pubDate") ?? "");
			if (publishedAt !== null) hit.publishedAt = publishedAt;
			hits.push(hit);
		}
		return hits;
	}
	/**
	* Parse an HTML result page (RSS fallback path): `<li class="b_algo">`
	* blocks, `<h2><a href="direct-link">` for title/link, first
	* `<p class="b_lineclamp...">` (or any `<p>`) inside the block for snippet.
	*/
	static parseHtml(body) {
		if (body.includes("异常流量")) throw new SearchEngineError(BING_CN_ENGINE_ID, "parse", "必应返回异常流量拦截页");
		const titleTag = /<title>([\s\S]*?)<\/title>/.exec(body);
		const looksResultPage = (titleTag === null ? "" : htmlToText(titleTag[1])).includes("必应") || body.includes("b_algo");
		const blocks = splitBlocks(stripHtmlComments(body), /<li class="b_algo/);
		if (blocks.length === 0) {
			if (!looksResultPage) throw new SearchEngineError(BING_CN_ENGINE_ID, "parse", "必应返回页面不像结果页（无 b_algo）");
			throw new SearchEngineError(BING_CN_ENGINE_ID, "empty", "必应 0 条结果");
		}
		const hits = [];
		for (const block of blocks) {
			const h2 = firstTitleLink(block, "h2");
			if (h2 === null) continue;
			const snippet = firstClassTokenText(block, "p", ["b_lineclamp"]) ?? firstPTagText(block);
			hits.push({
				title: h2.title,
				url: h2.href,
				...snippet !== null ? { snippet } : {},
				engine: BING_CN_ENGINE_ID
			});
		}
		if (hits.length === 0) throw new SearchEngineError(BING_CN_ENGINE_ID, "empty", "必应 0 条结果");
		return hits;
	}
};
/** Extract a single XML tag's text (CDATA-aware), cleaned of embedded HTML. */
function tagText(xml, name) {
	const m = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(xml);
	if (m === null) return null;
	let v = m[1];
	const cdata = /<!\[CDATA\[([\s\S]*?)\]\]>/.exec(v);
	if (cdata !== null) v = cdata[1];
	return htmlToText(v);
}
/** First `<p>` text inside a chunk (fallback when b_lineclamp matching misses). */
function firstPTagText(chunk) {
	const m = /<p(?=[\s>])[^>]*>/i.exec(chunk);
	if (m === null) return null;
	const close = chunk.indexOf("</p>", m.index + m[0].length);
	if (close < 0) return null;
	const text = htmlToText(chunk.slice(m.index + m[0].length, close));
	return text === "" ? null : text;
}
/** `周四, 01 10月 2026 21:29:00 GMT` → `2026-10-01`; English month names (`Thu, 01 Oct 2026 ...`) also handled; unparseable input is returned verbatim. */
function formatPubDate(raw) {
	if (raw === "") return null;
	const zh = /(\d{1,2})\s+(\d{1,2})月\s+(\d{4})/.exec(raw);
	if (zh !== null) return ymd(Number.parseInt(zh[3], 10), Number.parseInt(zh[2], 10), Number.parseInt(zh[1], 10));
	const en = {
		jan: 1,
		feb: 2,
		mar: 3,
		apr: 4,
		may: 5,
		jun: 6,
		jul: 7,
		aug: 8,
		sep: 9,
		oct: 10,
		nov: 11,
		dec: 12
	};
	const en1 = /(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})/.exec(raw);
	if (en1 !== null) {
		const mo = en[en1[2].toLowerCase().slice(0, 3)];
		if (mo !== void 0) return ymd(Number.parseInt(en1[3], 10), mo, Number.parseInt(en1[1], 10));
	}
	return raw;
}
function ymd(y, m, d) {
	return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}
//#endregion
//#region lib/types/engines/chinaso.js
/**
* Chinaso (www.chinaso.com, official state aggregator) adapter.
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/chinaso_engine.dart`.
*
* Official JSON API, key-free:
* `GET /v5/general/v1/web/search?q=&pn=1&ps=10`
* → `{"status":0,"msg":"success","data":{"data":[{title,url,snippet,timestamp}]}}`
*
* Constraints/pitfalls (field-tested 2026-10-02, carried over from Dart):
* - A random `uid` Cookie is REQUIRED (`uid=base64(16 random bytes)`,
*   aligned with SearXNG's chinaso.py) — without it the endpoint answers
*   `{"status":2,"msg":"ip control"}`;
* - `status:2` / msg containing "ip control" is classified `blocked`
*   (IP-dimension risk control, circuit-breaker cooldown);
* - Result urls are `chinaso.com/link?url=...` redirects (official design);
*   the real address is resolved by the aggregator's link resolver via 302;
*   title/snippet embed `<em>` highlight tags, cleaned via htmlToText;
*   timestamp is a Unix-seconds string.
* @module @deepseek-ai/dsh-web-search-localxng/engines/chinaso
*/
const CHINASO_ENGINE_ID = "chinaso";
var ChinasoEngine = class ChinasoEngine {
	id = CHINASO_ENGINE_ID;
	displayName = "中国搜索";
	fetch;
	random;
	constructor(fetch, options = {}) {
		this.fetch = fetch;
		this.random = options.random ?? secureByte;
	}
	/** Random uid Cookie generated per request (SearXNG's same trick). */
	buildUidCookie() {
		const bytes = [];
		for (let i = 0; i < 16; i++) bytes.push(Math.floor(this.random() * 256));
		let binary = "";
		for (const b of bytes) binary += String.fromCharCode(b);
		return `uid=${btoa(binary)}`;
	}
	async search(query, limit = 8) {
		const n = Math.min(Math.max(limit, 1), 20);
		const url = new URL("https://www.chinaso.com/v5/general/v1/web/search");
		url.searchParams.set("q", query);
		url.searchParams.set("pn", "1");
		url.searchParams.set("ps", String(n));
		const body = await fetchPageOrNetworkError(this.id, this.fetch, url, {
			"Cookie": this.buildUidCookie(),
			"Referer": "https://www.chinaso.com/"
		});
		return takeLimit(ChinasoEngine.parsePage(body), limit);
	}
	static parsePage(body) {
		let decoded;
		try {
			decoded = JSON.parse(body);
		} catch {
			throw new SearchEngineError(CHINASO_ENGINE_ID, "parse", "响应不是合法 JSON");
		}
		if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) throw new SearchEngineError(CHINASO_ENGINE_ID, "parse", "顶层不是 JSON 对象");
		const root = decoded;
		const status = root["status"];
		const msg = dynString$1(root["msg"]);
		if (typeof status === "number" && status !== 0) throw new SearchEngineError(CHINASO_ENGINE_ID, msg.toLowerCase().includes("ip control") || status === 2 ? "blocked" : "network", `chinaso 返回 status=${status} msg=${msg}`);
		const inner = root["data"];
		if (typeof inner !== "object" || inner === null || Array.isArray(inner)) throw new SearchEngineError(CHINASO_ENGINE_ID, "empty", "chinaso 0 条结果");
		const entries = Array.isArray(inner["data"]) ? inner["data"] : [];
		const hits = [];
		for (const e of entries) {
			if (typeof e !== "object" || e === null || Array.isArray(e)) continue;
			const entry = e;
			const title = htmlToText(dynString$1(entry["title"]));
			const url = dynString$1(entry["url"]).trim();
			if (title === "" || url === "") continue;
			const snippet = htmlToText(dynString$1(entry["snippet"]));
			const ts = tryParseInt(dynString$1(entry["timestamp"]).trim());
			const hit = {
				title,
				url,
				engine: CHINASO_ENGINE_ID
			};
			if (snippet !== "") hit.snippet = snippet;
			if (ts !== null && ts > 0) hit.publishedAt = unixSecondsToIsoDate(ts);
			hits.push(hit);
		}
		if (hits.length === 0) throw new SearchEngineError(CHINASO_ENGINE_ID, "empty", "chinaso 0 条结果");
		return hits;
	}
};
function secureByte() {
	return crypto.getRandomValues(new Uint8Array(1))[0] / 256;
}
/** Dart `int.tryParse` equivalent (optional sign, decimal digits only). */
function tryParseInt(s) {
	return /^[+-]?\d+$/.test(s) ? Number.parseInt(s, 10) : null;
}
/** Dart `'${x ?? ''}'` string interpolation over a dynamic JSON value. */
function dynString$1(v) {
	return v === null || v === void 0 ? "" : String(v);
}
//#endregion
//#region lib/types/engines/quark.js
/**
* Quark search (quark.sm.cn, Alibaba / Shenma index) adapter.
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/quark_engine.dart`.
*
* Field facts (endpoint/structure aligned with SearXNG's quark.py, parsing
* written from scratch):
* - Endpoint `https://quark.sm.cn/s?q=&layout=html&page=1`, no special
*   cookies needed;
* - Results are NOT in HTML tags but in the hydrate JSON blocks of
*   `<script type="application/json" id="s-data-..." data-used-by="hydrate">`,
*   organized by `extraData.sc` into ~20 card types whose field names vary
*   per type — this parser therefore RECURSIVELY COLLECTS by field-name
*   sets (url-like: normal_url/dest_url/url/title_url/sourceProps.dest_url;
*   title-like: title/titleProps.content etc.), staying robust to type
*   changes;
* - Alibaba x5sec risk control: triggered after ~9 requests in a short
*   window; the `"action": "captcha"` JSON fragment appearing means blocked
*   for ~15 minutes — matching the circuit-breaker cooldown.
* @module @deepseek-ai/dsh-web-search-localxng/engines/quark
*/
const QUARK_ENGINE_ID = "quark";
var QuarkEngine = class QuarkEngine {
	id = QUARK_ENGINE_ID;
	displayName = "夸克";
	fetch;
	constructor(fetch) {
		this.fetch = fetch;
	}
	async search(query, limit = 8) {
		const n = Math.min(Math.max(limit, 1), 20);
		const url = new URL("https://quark.sm.cn/s");
		url.searchParams.set("q", query);
		url.searchParams.set("layout", "html");
		url.searchParams.set("page", "1");
		const body = await fetchPageOrNetworkError(this.id, this.fetch, url);
		return takeLimit(QuarkEngine.parsePage(body), n);
	}
	static parsePage(body) {
		const lower = body.toLowerCase();
		if (lower.includes("\"action\":\"captcha\"") || lower.includes("\"action\": \"captcha\"") || lower.includes("x5sec")) throw new SearchEngineError(QUARK_ENGINE_ID, "blocked", "夸克触发 x5sec 验证码");
		const blobRe = /<script[^>]*type="application\/json"[^>]*>([\s\S]*?)<\/script>/gi;
		const hits = [];
		const seen = /* @__PURE__ */ new Set();
		for (const m of body.matchAll(blobRe)) {
			let decoded;
			try {
				decoded = JSON.parse(m[1]);
			} catch {
				continue;
			}
			collect(decoded, hits, seen);
		}
		if (hits.length === 0) throw new SearchEngineError(QUARK_ENGINE_ID, "parse", "夸克页面无 hydrate 结果（结构变化或被拦）");
		return hits;
	}
};
/** Recursively collect nodes that carry BOTH a valid external url and a title. */
function collect(node, out, seen) {
	if (Array.isArray(node)) {
		for (const item of node) collect(item, out, seen);
		return;
	}
	if (typeof node !== "object" || node === null) return;
	const map = node;
	const url = pickUrl(map);
	const title = pickTitle(map);
	if (url !== null && title !== null && title !== "") {
		const host = hostOf(url);
		const isSelf = hostMatchesDomain(host, "quark.sm.cn") || hostMatchesDomain(host, "sm.cn");
		const key = normalizeUrlKey(url);
		if (!isSelf && key !== "" && !seen.has(key)) {
			seen.add(key);
			const snippet = pickSummary(map);
			out.push({
				title,
				url,
				...snippet !== null ? { snippet } : {},
				engine: QUARK_ENGINE_ID
			});
		}
	}
	for (const v of Object.values(map)) collect(v, out, seen);
}
function pickUrl(node) {
	const sp = node["sourceProps"];
	if (typeof sp === "object" && sp !== null && !Array.isArray(sp)) {
		const dest = dynString(sp["dest_url"]).trim();
		if (dest.startsWith("http")) return dest;
	}
	for (const key of [
		"normal_url",
		"url",
		"title_url",
		"dest_url"
	]) {
		const v = dynString(node[key]).trim();
		if (v.startsWith("http")) return v;
	}
	return null;
}
function pickTitle(node) {
	const t = node["title"];
	if (typeof t === "string" && t.trim() !== "") return htmlToText(t);
	const tp = node["titleProps"];
	if (typeof tp === "object" && tp !== null && !Array.isArray(tp)) for (const key of ["content", "text"]) {
		const v = dynString(tp[key]).trim();
		if (v !== "") return htmlToText(v);
	}
	return null;
}
function pickSummary(node) {
	const sp = node["summaryProps"];
	if (typeof sp === "object" && sp !== null && !Array.isArray(sp)) {
		const record = sp;
		const v = htmlToText(dynString(record["content"] ?? record["text"]));
		if (v !== "") return v;
	}
	for (const key of [
		"summary",
		"desc",
		"replyContent"
	]) {
		const v = htmlToText(dynString(node[key]));
		if (v !== "") return v;
	}
	return null;
}
/** Lightweight same-origin dedup key (quark-only within this module; the aggregator normalizes URLs its own way). */
function normalizeUrlKey(raw) {
	let uri;
	try {
		uri = new URL(raw.trim());
	} catch {
		return "";
	}
	if (uri.hostname === "") return "";
	return `${uri.hostname.toLowerCase()}${uri.pathname}`;
}
/** Dart `'${x ?? ''}'` string interpolation over a dynamic JSON value. */
function dynString(v) {
	return v === null || v === void 0 ? "" : String(v);
}
//#endregion
//#region lib/types/engines/so360.js
/**
* 360 Search (www.so.com) adapter.
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/so360_engine.dart`.
*
* Constraints/pitfalls carried over from the Dart original:
* - The real URL hides in the `data-mdurl` attribute (on the title anchor);
*   `href` is a so.com/link redirect — fall back to href when mdurl is
*   missing (the redirect form is still acceptable);
* - The snippet carrier is not fixed: both `<p class="res-desc">` and
*   `<span class="res-list-summary">` appear (class names sometimes carry a
*   hash suffix), so prefix matching is used;
* - Noise blocks must be filtered: `data-mohe-type` vertical aggregation
*   cards (news_ai/short_video etc.), title links pointing at news.so.com/ns?
*   aggregation entries, and mdurl landing on navigation domains
*   (hao.360.com/360kan.com/bing.com).
* @module @deepseek-ai/dsh-web-search-localxng/engines/so360
*/
const SO360_ENGINE_ID = "so360";
var So360Engine = class So360Engine {
	id = SO360_ENGINE_ID;
	displayName = "360搜索";
	fetch;
	constructor(fetch) {
		this.fetch = fetch;
	}
	async search(query, limit = 8) {
		const url = new URL("https://www.so.com/s");
		url.searchParams.set("q", query);
		url.searchParams.set("pn", "1");
		const body = await fetchPageOrNetworkError(this.id, this.fetch, url);
		return takeLimit(So360Engine.parsePage(body), limit);
	}
	/** Parse a result page, block-split on `<li class="res-list">`. */
	static parsePage(body) {
		const lower = body.toLowerCase();
		if (body.includes("验证码") || lower.includes("captcha")) throw new SearchEngineError(SO360_ENGINE_ID, "blocked", "360搜索触发验证码");
		const blocks = splitBlocks(stripHtmlComments(body), /<li class="res-list/);
		if (blocks.length === 0) throw new SearchEngineError(SO360_ENGINE_ID, "parse", "360页面结构不认识（无 res-list）");
		const hits = [];
		for (const block of blocks) {
			if (block.includes("data-mohe-type")) continue;
			const h3 = firstH3Link(block);
			if (h3 === null) continue;
			if (h3.href.includes("news.so.com/ns?")) continue;
			const url = attrValue(block, "data-mdurl") ?? h3.href;
			const host = hostOf(url);
			if ([
				"hao.360.com",
				"360kan.com",
				"bing.com"
			].some((d) => hostMatchesDomain(host, d))) continue;
			const snippet = firstClassTokenText(block, "p", ["res-desc", "mh-news-desc"]) ?? firstClassTokenText(block, "span", ["res-list-summary"]) ?? firstClassTokenText(block, "div", ["res-rich"]);
			hits.push({
				title: h3.title,
				url,
				...snippet !== null ? { snippet } : {},
				engine: SO360_ENGINE_ID
			});
		}
		if (hits.length === 0) throw new SearchEngineError(SO360_ENGINE_ID, "empty", "360 0 条结果（全部为噪声块）");
		return hits;
	}
};
//#endregion
//#region lib/types/engines/sogou.js
/**
* Sogou (www.sogou.com) adapter.
*
* Faithful port of TongYi-Lite `lib/websearch/src/engines/sogou_engine.dart`.
*
* Constraints/pitfalls carried over from the Dart original:
* - The real URL sits in the block's `data-url` attribute (every result has
*   one in the field; it hangs off the r-sech extension div inside vrwrap —
*   take the FIRST occurrence in the block, which is this result's real
*   address; the second one belongs to an in-block recommendation slot);
* - The title href is a /link?url=... redirect; the direct link can only
*   come from data-url;
* - The snippet lives in the div with `class="fz-mid space-txt ..."`
*   (space-txt wins over fz-mid — the latter also matches in-block image
*   captions and other stray elements);
* - vrwrap blocks without an h3 anchor ("everyone also searched" hints /
*   recommendation slots) are skipped outright.
* @module @deepseek-ai/dsh-web-search-localxng/engines/sogou
*/
const SOGOU_ENGINE_ID = "sogou";
var SogouEngine = class SogouEngine {
	id = SOGOU_ENGINE_ID;
	displayName = "搜狗";
	fetch;
	constructor(fetch) {
		this.fetch = fetch;
	}
	async search(query, limit = 8) {
		const url = new URL("https://www.sogou.com/web");
		url.searchParams.set("query", query);
		const body = await fetchPageOrNetworkError(this.id, this.fetch, url);
		return takeLimit(SogouEngine.parsePage(body), limit);
	}
	/** Parse a result page, block-split on `<div class="vrwrap">`. */
	static parsePage(body) {
		const lower = body.toLowerCase();
		const title = titleText(body);
		if (body.includes("验证码") || lower.includes("antispider") || title === "搜狗搜索" && body.length < 10 * 1024) throw new SearchEngineError(SOGOU_ENGINE_ID, "blocked", "搜狗触发反爬拦截");
		const blocks = splitBlocks(stripHtmlComments(body), /<div class="vrwrap/);
		if (blocks.length === 0) throw new SearchEngineError(SOGOU_ENGINE_ID, "parse", "搜狗页面结构不认识（无 vrwrap）");
		const hits = [];
		for (const block of blocks) {
			const h3 = firstH3Link(block);
			if (h3 === null) continue;
			const dataUrl = attrValue(block, "data-url");
			const href = h3.href;
			const url = dataUrl ?? (href.startsWith("/") ? `https://www.sogou.com${href}` : href);
			const snippet = firstClassTokenText(block, "div", ["space-txt"]) ?? firstClassTokenText(block, "div", ["fz-mid"]) ?? firstClassTokenText(block, "p", ["space-txt", "fz-mid"]);
			hits.push({
				title: h3.title,
				url,
				...snippet !== null ? { snippet } : {},
				engine: SOGOU_ENGINE_ID
			});
		}
		if (hits.length === 0) throw new SearchEngineError(SOGOU_ENGINE_ID, "empty", "搜狗 0 条结果（全部为噪声块）");
		return hits;
	}
};
function titleText(body) {
	const m = /<title>([\s\S]*?)<\/title>/.exec(body);
	return m === null ? "" : htmlToText(m[1]);
}
//#endregion
//#region lib/types/multi-engine-search.js
/**
* Multi-engine aggregator: parallel fan-out → per-engine circuit breaker and
* window budgets → smooth weighted round-robin merge with cross-engine dedup
* → time-query demotion of encyclopedias → redirect-link resolution.
*
* Field-tested design (TongYi-Lite `docs/websearch_direct_2026-10-02.md`):
* - **Circuit breaker per engine**: `blocked` (anti-bot) cools exponentially
*   2min × 2^n capped at 15min, `parse` (page redesign) 5min, `network` 45s;
*   `empty` cools nothing (it is query-specific). Mobile IPs drift (CGNAT),
*   and minute-level cooldowns self-heal without user action.
* - **Window budgets (细水长流)**: each engine gets at most N real requests per
*   fixed 10-minute window; exhausted → skip for that search (`budget`), no
*   error. High-risk engines (sogou/baidu/quark — captcha after 4-9 rapid
*   requests) default to 2/window; tolerant ones (bing/so360/chinaso) are loose.
* - **Identity rotation**: on `blocked` the callback clears the engine's cookie
*   session; the HTTP layer also rotates its UA — Sogou/Baidu penalties bind to
*   the session, and a fresh identity usually recovers.
* - **Time-query demotion**: for 今天/新闻/最新-style queries, encyclopedias are
*   stably demoted to the tail — Bing RSS ranking encyclopedias first is its
*   chronic weakness (reproduced on-device).
* - The aggregator never throws: when every engine fails it returns empty hits
*   plus per-engine statuses for an actionable diagnostic.
* @module @deepseek-ai/dsh-web-search-localxng/multi-engine-search
*/
/** Cooldown durations (exponential backoff grows from the blocked base). */
const COOLDOWN_BLOCKED_BASE_MS = 2 * 6e4;
const COOLDOWN_BLOCKED_CAP_MS = 15 * 6e4;
const COOLDOWN_PARSE_MS = 5 * 6e4;
const COOLDOWN_NETWORK_MS = 45e3;
/** Merge weights: bing/baidu/sogou take 2 shares, the rest 1. */
const DEFAULT_ENGINE_WEIGHTS = {
	bing_cn: 2,
	baidu: 2,
	sogou: 2,
	so360: 1,
	quark: 1,
	chinaso: 1
};
/** Default per-window request budgets (safety governance, 细水长流). */
const DEFAULT_ENGINE_BUDGETS = {
	bing_cn: 8,
	so360: 6,
	chinaso: 6,
	sogou: 2,
	baidu: 2,
	quark: 2
};
/** Time-sensitive query markers: hit → demote encyclopedias to the tail. */
const TIME_SENSITIVE_QUERY = /今天|今日|昨日|刚刚|最新|最近|新闻|消息|动态|现在|实时|热点/;
/** Demoted hosts under time-sensitive queries ("XX市_百度百科" is Bing's chronic #1). */
const DEMOTED_HOSTS = [
	"baike.baidu.com",
	"wenku.baidu.com",
	"baike.sogou.com",
	"zhidao.baidu.com"
];
var MultiEngineSearch = class {
	engines;
	maxResults;
	resolver;
	engineWeights;
	engineBudgets;
	budgetWindowMs;
	onEngineBlocked;
	now;
	states = /* @__PURE__ */ new Map();
	budgets = /* @__PURE__ */ new Map();
	constructor(options) {
		this.engines = options.engines;
		this.maxResults = options.maxResults ?? 8;
		if (options.resolver !== void 0) this.resolver = options.resolver;
		this.engineWeights = options.engineWeights ?? DEFAULT_ENGINE_WEIGHTS;
		this.engineBudgets = options.engineBudgets ?? DEFAULT_ENGINE_BUDGETS;
		this.budgetWindowMs = options.budgetWindowMs ?? 6e5;
		if (options.onEngineBlocked !== void 0) this.onEngineBlocked = options.onEngineBlocked;
		this.now = options.now ?? (() => /* @__PURE__ */ new Date());
	}
	get engineIds() {
		return this.engines.map((engine) => engine.id);
	}
	/** True while the engine is cooling down (diagnostics). */
	isCooling(engineId) {
		const state = this.states.get(engineId);
		return state !== void 0 && this.now().getTime() < state.coolingUntil.getTime();
	}
	/** Run one aggregated search. Never throws; failures land in `engineStatus`. */
	async search(query, limit) {
		const cap = limit ?? this.maxResults;
		const status = /* @__PURE__ */ new Map();
		const futures = /* @__PURE__ */ new Map();
		for (const engine of this.engines) {
			const state = this.stateOf(engine.id);
			const now = this.now();
			if (now.getTime() < state.coolingUntil.getTime()) {
				status.set(engine.id, `cooling(${Math.ceil((state.coolingUntil.getTime() - now.getTime()) / 1e3)}s)`);
				continue;
			}
			if (!this.takeBudget(engine.id, now)) {
				status.set(engine.id, "budget");
				continue;
			}
			status.set(engine.id, "pending");
			futures.set(engine.id, engine.search(query, cap > 10 ? cap : 10));
		}
		await Promise.allSettled([...futures.values()]);
		const perEngine = /* @__PURE__ */ new Map();
		for (const [engineId, future] of futures) try {
			const hits = await future;
			perEngine.set(engineId, hits);
			status.set(engineId, `ok:${hits.length}`);
			this.markSuccess(engineId);
		} catch (error) {
			const kind = error instanceof SearchEngineError ? error.kind : "network";
			const message = error instanceof Error ? error.message : String(error);
			status.set(engineId, kind === "network" ? `network:${message}` : `${kind}:${message}`);
			this.markFailure(engineId, kind);
		}
		const merged = this.mergeRoundRobin(perEngine, cap);
		let hits = this.demoteForTimeQuery(query, merged.hits);
		const truncated = merged.truncated;
		if (this.resolver !== void 0 && hits.length > 0) hits = await this.resolveLinks(hits);
		return {
			hits,
			truncated,
			engineStatus: status
		};
	}
	/** Actionable diagnostic for an all-failed outcome (model/human readable). */
	static diagnosticsText(engineStatus) {
		if (engineStatus.size === 0) return "没有可用的搜索引擎";
		return "各引擎状态：" + [...engineStatus.entries()].map(([id, s]) => `${id}: ${s}`).join("；") + "。budget=本轮请求预算已用完（安全管控，窗口到期自动恢复）；blocked/network=当前网络出口被该引擎风控，稍后自动恢复；多数为 empty 时说明关键词确实无结果，可更换关键词。";
	}
	stateOf(engineId) {
		let state = this.states.get(engineId);
		if (state === void 0) {
			state = {
				blockedStreak: 0,
				coolingUntil: /* @__PURE__ */ new Date(0)
			};
			this.states.set(engineId, state);
		}
		return state;
	}
	/** Budget gate: consume one slot; `false` = window exhausted (skip this search). */
	takeBudget(engineId, now) {
		const budget = this.engineBudgets[engineId];
		if (budget === void 0 || budget <= 0) return true;
		let state = this.budgets.get(engineId);
		if (state === void 0) {
			state = {
				used: 0,
				windowStart: /* @__PURE__ */ new Date(0)
			};
			this.budgets.set(engineId, state);
		}
		if (now.getTime() > state.windowStart.getTime() + this.budgetWindowMs) {
			state.used = 0;
			state.windowStart = now;
		}
		if (state.used >= budget) return false;
		state.used += 1;
		return true;
	}
	markSuccess(engineId) {
		const state = this.states.get(engineId);
		if (state === void 0) return;
		state.blockedStreak = 0;
		state.coolingUntil = /* @__PURE__ */ new Date(0);
	}
	markFailure(engineId, kind) {
		const state = this.stateOf(engineId);
		switch (kind) {
			case "blocked": {
				state.blockedStreak += 1;
				this.onEngineBlocked?.(engineId);
				const seconds = Math.min(COOLDOWN_BLOCKED_BASE_MS / 1e3 * 2 ** (state.blockedStreak - 1), COOLDOWN_BLOCKED_CAP_MS / 1e3);
				state.coolingUntil = new Date(this.now().getTime() + seconds * 1e3);
				break;
			}
			case "parse":
				state.coolingUntil = new Date(this.now().getTime() + COOLDOWN_PARSE_MS);
				break;
			case "network":
				state.coolingUntil = new Date(this.now().getTime() + COOLDOWN_NETWORK_MS);
				break;
			default: break;
		}
	}
	/** Smooth weighted round-robin merge with cross-engine URL dedup. */
	mergeRoundRobin(perEngine, cap) {
		const queues = /* @__PURE__ */ new Map();
		for (const engine of this.engines) {
			const hits = perEngine.get(engine.id);
			if (hits !== void 0 && hits.length > 0) queues.set(engine.id, hits);
		}
		let total = 0;
		for (const hits of queues.values()) total += hits.length;
		const cursors = new Map([...queues.keys()].map((id) => [id, 0]));
		const credits = new Map([...queues.keys()].map((id) => [id, 0]));
		const weightOf = (id) => {
			const w = this.engineWeights[id];
			return w !== void 0 && w >= 1 ? w : 1;
		};
		const out = [];
		const seen = /* @__PURE__ */ new Set();
		while (out.length < cap) {
			let progress = false;
			for (const engine of this.engines) {
				const queue = queues.get(engine.id);
				if (queue === void 0) continue;
				credits.set(engine.id, credits.get(engine.id) + weightOf(engine.id));
				while (credits.get(engine.id) >= 1 && cursors.get(engine.id) < queue.length && out.length < cap) {
					credits.set(engine.id, credits.get(engine.id) - 1);
					const hit = queue[cursors.get(engine.id)];
					cursors.set(engine.id, cursors.get(engine.id) + 1);
					progress = true;
					const key = normalizeUrl(hit.url);
					if (!seen.has(key)) {
						seen.add(key);
						out.push(hit);
					}
				}
				if (out.length >= cap) break;
			}
			if (!progress) break;
		}
		return {
			hits: out,
			truncated: total > out.length
		};
	}
	/** Time-sensitive queries stably demote encyclopedia/wenku hits to the tail. */
	demoteForTimeQuery(query, hits) {
		if (!TIME_SENSITIVE_QUERY.test(query)) return hits;
		const isDemoted = (hit) => {
			let host = "";
			try {
				host = new URL(hit.url).host.toLowerCase();
			} catch {
				return false;
			}
			return DEMOTED_HOSTS.some((demoted) => host.endsWith(demoted));
		};
		return [...hits.filter((hit) => !isDemoted(hit)), ...hits.filter(isDemoted)];
	}
	/** Resolve redirect links only for the hits that will be returned (save requests). */
	async resolveLinks(hits) {
		const resolver = this.resolver;
		return Promise.all(hits.map(async (hit) => {
			if (!isRedirectLink(hit.url)) return hit;
			const real = await resolver.resolve(hit.url).catch(() => void 0);
			return real === void 0 ? hit : {
				...hit,
				url: real
			};
		}));
	}
};
/** Cross-engine same-source dedup key: lowercase host, no fragment/trailing slash, tracking params dropped. */
function normalizeUrl(raw) {
	let uri;
	try {
		uri = new URL(raw.trim());
	} catch {
		return raw.trim();
	}
	const params = [...uri.searchParams.entries()].filter(([key]) => {
		const lower = key.toLowerCase();
		return !lower.startsWith("utm_") && lower !== "from" && lower !== "ie" && lower !== "tn";
	}).sort(([a], [b]) => a.localeCompare(b));
	let path = uri.pathname;
	if (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
	uri.search = "";
	uri.hash = "";
	uri.pathname = path === "" ? "/" : path;
	for (const [key, value] of params) uri.searchParams.append(key, value);
	const port = uri.port === "" ? "" : `:${uri.port}`;
	return `${uri.protocol}//${uri.hostname.toLowerCase()}${port}${uri.pathname}${uri.search}`;
}
/** Build the default engine set (priority order) over one HTTP session. */
function createDefaultEngines(session) {
	const byId = {
		bing_cn: new BingCnEngine(session.forEngine("bing_cn")),
		baidu: new BaiduEngine(session.forEngine("baidu", true)),
		sogou: new SogouEngine(session.forEngine("sogou", true)),
		so360: new So360Engine(session.forEngine("so360")),
		quark: new QuarkEngine(session.forEngine("quark")),
		chinaso: new ChinasoEngine(session.forEngine("chinaso"))
	};
	return DIRECT_ENGINE_IDS.map((id) => byId[id]);
}
//#endregion
//#region lib/types/provider.js
/**
* `LocalXngSearchProvider`: a `WebSearchProvider` backed by direct-access
* Chinese search engines (bing_cn/baidu/sogou/so360/quark/chinaso) with
* circuit breakers, window budgets, identity rotation, weighted merging and
* time-query encyclopedia demotion. No API keys, no SearXNG instance — the
* client talks to the engines directly.
* @module @deepseek-ai/dsh-web-search-localxng/provider
*/
/** Stable id this provider registers under (pin it via `web.searchProvider`). */
const LOCALXNG_PROVIDER_ID = "localxng";
/**
* Provider over the aggregator. The aggregator never throws — an all-failed
* search surfaces as `WEB_PROVIDER_ERROR` carrying the per-engine actionable
* diagnostic (`budget` / `blocked` / `cooling` / …) so the model can stop
* retrying instead of hallucinating a "no results" answer.
*/
var LocalXngSearchProvider = class {
	aggregator;
	id = LOCALXNG_PROVIDER_ID;
	constructor(aggregator) {
		this.aggregator = aggregator;
	}
	/** Cheap local check: usable while at least one engine is configured. */
	available() {
		return this.aggregator.engineIds.length > 0;
	}
	async search(request, signal) {
		const outcome = await this.aggregator.search(request.query, request.maxResults);
		if (outcome.hits.length === 0) throw new WebError(`localxng 直连搜索全部引擎失败：${MultiEngineSearch.diagnosticsText(outcome.engineStatus)}`, "WEB_PROVIDER_ERROR");
		return {
			sources: outcome.hits.map((hit) => ({
				url: hit.url,
				...hit.title !== "" ? { title: hit.title } : {},
				...hit.snippet !== void 0 ? { snippet: hit.snippet } : {},
				...hit.publishedAt !== void 0 ? { publishedAt: hit.publishedAt } : {}
			})),
			truncated: outcome.truncated
		};
	}
};
//#endregion
//#region lib/types/index.js
/**
* `@deepseek-ai/dsh-web-search-localxng`: registers a direct-access multi-engine
* `WebSearchProvider` (bing_cn/baidu/sogou/so360/quark/chinaso) with `ctx.web`.
* A function/namespace plugin (NOT a default-export service): it registers INTO
* the seam's provider registry, exactly as `@deepseek-ai/dsh-web-search-exa`
* does. The seam key is owned by `@deepseek-ai/dsh-web`.
*
* All configuration lives in the plugin conf (no UI): engine toggles, risk-tier
* window budgets (细水长流), merge weights, cooldowns and timeouts. Pin the
* provider via the web seam's `searchProvider: localxng` (or env
* `$DSH_WEB_SEARCH_PROVIDER`) — that is the DSH-sanctioned "highest priority"
* mechanism, not a hidden chain.
* @module @deepseek-ai/dsh-web-search-localxng
*/
/** Cordis plugin name used by loader diagnostics. */
const name = "web-search-localxng";
/** The web seam this provider registers into. */
const inject = ["web"];
const Config = z.object({
	engines: z.object({
		bing_cn: z.boolean(),
		baidu: z.boolean(),
		sogou: z.boolean(),
		so360: z.boolean(),
		quark: z.boolean(),
		chinaso: z.boolean()
	}),
	lowRiskPerWindow: z.number().step(1).min(1).max(10),
	highRiskPerWindow: z.number().step(1).min(1).max(6),
	budgetWindowMinutes: z.number().step(1).min(1),
	weights: z.dict(z.number().min(1)),
	maxResults: z.number().step(1).min(1).max(20),
	resolveLinks: z.boolean(),
	requestTimeoutMs: z.number().step(1).min(1e3)
});
const LOW_RISK = [
	"bing_cn",
	"so360",
	"chinaso"
];
const HIGH_RISK = [
	"sogou",
	"baidu",
	"quark"
];
/** Register the localxng search provider with `ctx.web`. */
function apply(ctx, config) {
	const session = new EngineHttpSession({ requestTimeoutMs: config.requestTimeoutMs ?? 12e3 });
	const toggles = config.engines ?? {};
	const enabled = DIRECT_ENGINE_IDS.filter((id) => toggles[id] !== false);
	const budgets = {};
	for (const id of LOW_RISK) budgets[id] = config.lowRiskPerWindow ?? 6;
	for (const id of HIGH_RISK) budgets[id] = config.highRiskPerWindow ?? 2;
	const aggregator = new MultiEngineSearch({
		engines: createDefaultEngines(session).filter((engine) => enabled.includes(engine.id)),
		maxResults: config.maxResults ?? 8,
		...config.resolveLinks !== false ? { resolver: new LinkResolver() } : {},
		...config.weights !== void 0 ? { engineWeights: config.weights } : {},
		engineBudgets: budgets,
		budgetWindowMs: (config.budgetWindowMinutes ?? 10) * 6e4,
		onEngineBlocked: (engineId) => session.clearSession(engineId)
	});
	ctx.web.registerSearchProvider(new LocalXngSearchProvider(aggregator));
}
//#endregion
export { Config, DEFAULT_ENGINE_BUDGETS, DEFAULT_ENGINE_WEIGHTS, DIRECT_ENGINE_IDS, LOCALXNG_PROVIDER_ID, LocalXngSearchProvider, MultiEngineSearch, apply, inject, name };

//# sourceMappingURL=index.mjs.map