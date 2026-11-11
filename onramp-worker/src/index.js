// Crescent onramp: mints short-lived Arc Onramp widget sessions for chordotc.com/crescent/.
//
// The Circle API key lives here as a Cloudflare secret and never reaches a browser. The page asks this
// Worker for a session (POST /session); the Worker checks the request came from Crescent, cleans the
// input, and forwards it to Circle with the key. The widget then handles identity checks, payment and
// delivery of USDC/EURC to the buyer's own wallet on Arc. Nothing here touches money or personal data.
//
//   GET  /config   { enabled, env, public, widgetBaseUrl }  so the page always matches sandbox / production
//   POST /session  { appUserId, destinationAddress, token, amount }  ->  Onramp session (JSON)

import { createOnrampServerKit, createSessionRouteHandler } from "@circle-fin/onramp-kit/server";

const ENVS = {
  sandbox: { baseUrl: "https://api-test.circle.com", widgetBaseUrl: "https://onramp-sandbox.arc.io" },
  production: { baseUrl: "https://api.circle.com", widgetBaseUrl: "https://onramp.arc.io" },
};
const TOKENS = new Set(["USDC", "EURC"]); // what the Onramp sells on Arc
const MAX_AMOUNT = 10000;                 // pre-fill cap; the widget and provider apply their own limits
const RATE = { windowMs: 60_000, max: 10 }; // per IP, per isolate: a speed bump, not a guarantee

const hits = new Map();
function limited(ip) {
  const now = Date.now();
  const h = (hits.get(ip) || []).filter(t => now - t < RATE.windowMs);
  h.push(now); hits.set(ip, h);
  if (hits.size > 5000) hits.clear();
  return h.length > RATE.max;
}

function cors(env, origin) {
  const ok = origin === env.ALLOWED_ORIGIN;
  return {
    "access-control-allow-origin": ok ? origin : env.ALLOWED_ORIGIN,
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}
const json = (o, status, headers) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });

// Only well-formed, Crescent-shaped requests reach Circle. Returns the cleaned body or an error message.
export function cleanRequest(b) {
  if (!b || typeof b !== "object") return { error: "bad request" };
  const appUserId = typeof b.appUserId === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(b.appUserId) ? b.appUserId : null;
  const destinationAddress = typeof b.destinationAddress === "string" && /^0x[0-9a-fA-F]{40}$/.test(b.destinationAddress) ? b.destinationAddress : null;
  const token = typeof b.token === "string" && TOKENS.has(b.token.toUpperCase()) ? b.token.toUpperCase() : null;
  if (!appUserId || !destinationAddress || !token) return { error: "bad request" };
  const out = { appUserId, destinationAddress, assets: { pairs: [{ token, chain: "arc" }] }, metadata: { source: "crescent" } };
  if (b.amount !== undefined) {
    const s = String(b.amount);
    if (!/^\d{1,6}(\.\d{1,6})?$/.test(s) || Number(s) <= 0 || Number(s) > MAX_AMOUNT) return { error: "bad amount" };
    out.amount = String(Number(s)); // "25.0" -> "25"
    out.currency = token === "EURC" ? "EUR" : "USD"; // the widget pre-fills the amount in this fiat currency
  }
  return { body: out };
}

let kit = null, kitKey = null;
function getHandler(env) {
  const e = ENVS[env.ONRAMP_ENV] || ENVS.sandbox;
  const key = env.CIRCLE_API_KEY + "|" + env.ONRAMP_ENV;
  if (!kit || kitKey !== key) {
    const server = createOnrampServerKit({ apiKey: env.CIRCLE_API_KEY, baseUrl: e.baseUrl, widgetBaseUrl: e.widgetBaseUrl, referrerDomain: env.REFERRER_DOMAIN });
    kit = createSessionRouteHandler(server, { authorize: () => true }); // origin and input are checked below, before this runs
    kitKey = key;
  }
  return kit;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const origin = req.headers.get("origin") || "";
    const h = cors(env, origin);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: h });
    const e = ENVS[env.ONRAMP_ENV] || ENVS.sandbox;

    if (url.pathname === "/config" && req.method === "GET") {
      // public: false keeps the box hidden except on links with &onramp=test (sandbox is never public).
      const live = env.ONRAMP_ENV === "production";
      return json({ enabled: Boolean(env.CIRCLE_API_KEY), env: live ? "production" : "sandbox", public: live && env.ONRAMP_PUBLIC === "true", widgetBaseUrl: e.widgetBaseUrl }, 200, h);
    }
    if (url.pathname === "/session" && req.method === "POST") {
      if (origin !== env.ALLOWED_ORIGIN) return json({ error: "not allowed" }, 403, h);
      if (!env.CIRCLE_API_KEY) return json({ error: "onramp not configured" }, 503, h);
      if (limited(req.headers.get("cf-connecting-ip") || "unknown")) return json({ error: "too many requests, try again in a minute" }, 429, h);
      let raw; try { raw = await req.json(); } catch { return json({ error: "bad request" }, 400, h); }
      const c = cleanRequest(raw);
      if (c.error) return json({ error: c.error }, 400, h);
      const fwd = new Request(req.url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(c.body) });
      const res = await getHandler(env)(fwd);
      const out = new Response(res.body, res);
      for (const [k, v] of Object.entries(h)) out.headers.set(k, v);
      return out;
    }
    return json({ name: "crescent-onramp", endpoints: ["GET /config", "POST /session"] }, url.pathname === "/" ? 200 : 404, h);
  },
};
