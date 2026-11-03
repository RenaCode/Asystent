// Minimalne proxy: apka -> (APP_TOKEN) -> proxy -> (ANTHROPIC_API_KEY) -> Claude API.
// Bez frameworka, żeby obraz był mały. Streaming SSE to faza 2 (patrz CLAUDE.md).
//
// Proxy, nie apka, wybiera model, effort i limity — klucz API należy do właściciela serwera,
// więc klient może przysłać tylko rozmowę (system, messages, własne narzędzia).
import http from "node:http";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";

const MAX_BODY = 512 * 1024;
const MAX_MESSAGES = 200;
const MAX_TOOLS = 32;
const MAX_SYSTEM_CHARS = 20_000;
const FALLBACK_BETA = "server-side-fallback-2026-07-01";
const EFFORTS = new Set(["low", "medium", "high", "xhigh", "max"]);

export function loadConfig(env = process.env) {
  const appToken = env.APP_TOKEN ?? "";
  if (!env.ANTHROPIC_API_KEY) throw new Error("Ustaw ANTHROPIC_API_KEY (np. w proxy/.env)");
  if (appToken.length < 32 || appToken === "change-me") {
    throw new Error("APP_TOKEN musi mieć co najmniej 32 znaki (np. `openssl rand -hex 32`)");
  }
  const effort = env.EFFORT ?? "low";
  if (!EFFORTS.has(effort)) throw new Error(`Nieznany EFFORT=${effort}`);
  return {
    port: Number(env.PORT ?? 8787),
    host: env.HOST ?? "0.0.0.0",
    appToken,
    model: env.MODEL ?? "claude-opus-5-5",
    effort,
    maxTokens: Number(env.MAX_TOKENS ?? 16000),
    rateLimit: Number(env.RATE_LIMIT_PER_MIN ?? 30),
  };
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/// Porównanie tokenów w stałym czasie (skróty sha256 mają równą długość).
function tokenMatches(header, appToken) {
  const given = crypto.createHash("sha256").update(header ?? "").digest();
  const expected = crypto.createHash("sha256").update(`Bearer ${appToken}`).digest();
  return crypto.timingSafeEqual(given, expected);
}

/// Prosty rate limit per IP (in-memory, wystarczy dla kilku użytkowników).
function makeRateLimiter(limit, windowMs = 60_000) {
  const hits = new Map();
  setInterval(() => {
    const now = Date.now();
    for (const [ip, arr] of hits) if (arr.every((t) => now - t >= windowMs)) hits.delete(ip);
  }, windowMs).unref();
  return (ip) => {
    const now = Date.now();
    const arr = (hits.get(ip) ?? []).filter((t) => now - t < windowMs);
    arr.push(now);
    hits.set(ip, arr);
    return arr.length > limit;
  };
}

function send(res, status, obj) {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(obj));
}

async function readJson(req) {
  let size = 0;
  const chunks = [];
  for await (const c of req) {
    size += c.length;
    if (size > MAX_BODY) throw new HttpError(413, "body too large");
    chunks.push(c);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

/// Przepuszczamy tylko to, co apka ma prawo ustawić. Narzędzia wyłącznie własne
/// (name/description/input_schema) — bez narzędzi serwerowych, które kosztują osobno.
export function sanitize(body) {
  const { system, messages, tools } = body ?? {};
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > MAX_MESSAGES) {
    throw new HttpError(400, "messages required");
  }
  for (const m of messages) {
    if (!m || (m.role !== "user" && m.role !== "assistant") || !Array.isArray(m.content)) {
      throw new HttpError(400, "invalid message");
    }
  }
  if (system !== undefined && (typeof system !== "string" || system.length > MAX_SYSTEM_CHARS)) {
    throw new HttpError(400, "invalid system");
  }
  if (tools !== undefined && (!Array.isArray(tools) || tools.length > MAX_TOOLS)) {
    throw new HttpError(400, "invalid tools");
  }
  const cleanTools = (tools ?? []).map((t) => {
    if (typeof t?.name !== "string" || typeof t?.input_schema !== "object") {
      throw new HttpError(400, "invalid tool");
    }
    return { name: t.name, description: String(t.description ?? ""), input_schema: t.input_schema };
  });
  return { system, messages, tools: cleanTools };
}

export function createServer(config, anthropic = new Anthropic()) {
  const rateLimited = makeRateLimiter(config.rateLimit);
  // Haiku 5.5 nie ma serwerowego fallbacku — tam parametru nie wysyłamy.
  const fallback = config.model.startsWith("claude-haiku")
    ? {}
    : { betas: [FALLBACK_BETA], fallbacks: "default" };

  return http.createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/healthz") return send(res, 200, { ok: true });
    if (req.method !== "POST" || req.url !== "/v1/chat") return send(res, 404, { error: "not found" });

    // Limit przed autoryzacją: hamuje też zgadywanie tokenu.
    if (rateLimited(req.socket.remoteAddress)) return send(res, 429, { error: "rate limited" });
    if (!tokenMatches(req.headers.authorization, config.appToken)) {
      return send(res, 401, { error: "unauthorized" });
    }

    try {
      const { system, messages, tools } = sanitize(await readJson(req));
      const started = Date.now();
      const msg = await anthropic.beta.messages.create({
        model: config.model,
        max_tokens: config.maxTokens,
        ...(system ? { system } : {}),
        messages,
        tools,
        output_config: { effort: config.effort },
        ...fallback,
      });
      // Logujemy tylko metadane — nigdy treści rozmowy.
      console.log(
        `${new Date().toISOString()} model=${msg.model} stop=${msg.stop_reason} ` +
          `in=${msg.usage?.input_tokens} out=${msg.usage?.output_tokens} ${Date.now() - started}ms`
      );
      send(res, 200, {
        content: msg.content,
        stop_reason: msg.stop_reason,
        stop_details: msg.stop_details ?? null,
        model: msg.model,
      });
    } catch (err) {
      if (err instanceof HttpError) return send(res, err.status, { error: err.message });
      if (err instanceof Anthropic.RateLimitError) return send(res, 429, { error: "upstream rate limited" });
      if (err instanceof Anthropic.BadRequestError) {
        console.error(`upstream 400: ${err.message}`);
        return send(res, 400, { error: "upstream rejected the request" });
      }
      console.error(err instanceof Anthropic.APIError ? `upstream ${err.status}: ${err.message}` : err);
      send(res, 502, { error: "upstream error" });
    }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let config;
  try {
    config = loadConfig();
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
  createServer(config).listen(config.port, config.host, () =>
    console.log(`asystent-proxy na ${config.host}:${config.port}, model ${config.model}, effort ${config.effort}`)
  );
}
