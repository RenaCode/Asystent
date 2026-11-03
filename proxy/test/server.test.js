// Testy proxy z atrapą Anthropic API (lokalny serwer HTTP) — bez prawdziwego klucza i bez kosztów.
import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import Anthropic from "@anthropic-ai/sdk";
import { createServer, loadConfig, sanitize } from "../server.js";

const TOKEN = "t".repeat(40);
let upstream, upstreamUrl, calls, reply;

function listen(server) {
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r(`http://127.0.0.1:${server.address().port}`)));
}

const okMessage = (over = {}) => ({
  id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5-5",
  content: [{ type: "thinking", thinking: "", signature: "sig" }, { type: "text", text: "Cześć" }],
  stop_reason: "end_turn", stop_sequence: null, stop_details: null,
  usage: { input_tokens: 5, output_tokens: 7 }, ...over,
});

before(async () => {
  upstream = http.createServer(async (req, res) => {
    let body = "";
    for await (const c of req) body += c;
    calls.push({ url: req.url, headers: req.headers, body: JSON.parse(body) });
    const [status, obj] = reply();
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(obj));
  });
  upstreamUrl = await listen(upstream);
});
after(() => upstream.close());
beforeEach(() => {
  calls = [];
  reply = () => [200, okMessage()];
});

async function withProxy(over, fn) {
  const config = { port: 0, appToken: TOKEN, model: "claude-opus-5-5", effort: "low", maxTokens: 16000, rateLimit: 100, ...over };
  const anthropic = new Anthropic({ apiKey: "test-key-not-real", baseURL: upstreamUrl, maxRetries: 0 });
  const server = createServer(config, anthropic);
  const url = await listen(server);
  try {
    await fn(url);
  } finally {
    server.close();
  }
}

const chat = (url, body, token = TOKEN) =>
  fetch(`${url}/v1/chat`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

const validBody = {
  system: "sys",
  messages: [{ role: "user", content: [{ type: "text", text: "hej" }] }],
  tools: [{ name: "a", description: "d", input_schema: { type: "object", properties: {} } }],
};

test("healthz", () =>
  withProxy({}, async (url) => {
    const r = await fetch(`${url}/healthz`);
    assert.equal(r.status, 200);
  }));

test("brak lub zły token = 401, bez zapytania do Anthropic", () =>
  withProxy({}, async (url) => {
    assert.equal((await chat(url, validBody, null)).status, 401);
    assert.equal((await chat(url, validBody, "zly")).status, 401);
    assert.equal((await chat(url, validBody, TOKEN + "x")).status, 401);
    assert.equal(calls.length, 0);
  }));

test("przekazuje rozmowę z modelem, effort i fallbackiem wybranymi przez proxy", () =>
  withProxy({}, async (url) => {
    const r = await chat(url, {
      ...validBody,
      model: "claude-fable-5-1", // klient nie wybiera modelu
      temperature: 1,
      tools: [{ ...validBody.tools[0], type: "web_search_20260209", cache_control: { type: "ephemeral" } }],
    });
    assert.equal(r.status, 200);
    const out = await r.json();
    assert.equal(out.stop_reason, "end_turn");
    assert.deepEqual(out.content, okMessage().content); // thinking wraca bez zmian

    assert.equal(calls.length, 1);
    const { url: path, headers, body } = calls[0];
    assert.match(path, /^\/v1\/messages/);
    assert.equal(headers["anthropic-version"], "2026-10-21");
    assert.match(headers["anthropic-beta"], /server-side-fallback-2026-07-01/);
    assert.equal(body.model, "claude-opus-5-5");
    assert.equal(body.fallbacks, "default");
    assert.deepEqual(body.output_config, { effort: "low" });
    assert.equal(body.max_tokens, 16000);
    assert.equal(body.system, "sys");
    for (const k of ["temperature", "top_p", "top_k", "thinking", "tool_choice"]) assert.equal(body[k], undefined, k);
    assert.deepEqual(body.tools, [validBody.tools[0]]);
  }));

test("Haiku bez parametru fallbacks", () =>
  withProxy({ model: "claude-haiku-5-5" }, async (url) => {
    assert.equal((await chat(url, validBody)).status, 200);
    assert.equal(calls[0].body.fallbacks, undefined);
    assert.doesNotMatch(calls[0].headers["anthropic-beta"] ?? "", /server-side-fallback/);
  }));

test("refusal i stop_details przechodzą do apki", () =>
  withProxy({}, async (url) => {
    reply = () => [200, okMessage({ content: [], stop_reason: "refusal",
      stop_details: { type: "refusal", category: "cyber", explanation: null } })];
    const out = await (await chat(url, validBody)).json();
    assert.equal(out.stop_reason, "refusal");
    assert.equal(out.stop_details.category, "cyber");
  }));

test("złe ciało zapytania = 400/413, bez zapytania do Anthropic", () =>
  withProxy({}, async (url) => {
    assert.equal((await chat(url, "{nie json")).status, 400);
    assert.equal((await chat(url, { messages: [] })).status, 400);
    assert.equal((await chat(url, { messages: [{ role: "system", content: [] }] })).status, 400);
    assert.equal((await chat(url, { ...validBody, tools: [{ type: "bash_20250124", name: "bash" }] })).status, 400);
    assert.equal((await chat(url, { ...validBody, system: "x".repeat(600_000) })).status, 413);
    assert.equal(calls.length, 0);
  }));

test("błędy Anthropic: 429 przechodzi, 5xx = 502 bez szczegółów", () =>
  withProxy({}, async (url) => {
    reply = () => [429, { type: "error", error: { type: "rate_limit_error", message: "slow down" } }];
    assert.equal((await chat(url, validBody)).status, 429);
    reply = () => [500, { type: "error", error: { type: "api_error", message: "internal secret detail" } }];
    const r = await chat(url, validBody);
    assert.equal(r.status, 502);
    assert.doesNotMatch(await r.text(), /secret/);
  }));

test("rate limit per IP, także dla błędnych tokenów", () =>
  withProxy({ rateLimit: 2 }, async (url) => {
    assert.equal((await chat(url, validBody, "zly")).status, 401);
    assert.equal((await chat(url, validBody)).status, 200);
    assert.equal((await chat(url, validBody)).status, 429);
  }));

test("brak nagłówków CORS i 404 na preflight", () =>
  withProxy({}, async (url) => {
    const r = await fetch(`${url}/v1/chat`, { method: "OPTIONS", headers: { origin: "https://evil.example" } });
    assert.equal(r.status, 404);
    assert.equal(r.headers.get("access-control-allow-origin"), null);
  }));

test("loadConfig odrzuca słaby token i brak klucza", () => {
  assert.throws(() => loadConfig({ APP_TOKEN: TOKEN }), /ANTHROPIC_API_KEY/);
  assert.throws(() => loadConfig({ ANTHROPIC_API_KEY: "k", APP_TOKEN: "change-me" }), /APP_TOKEN/);
  assert.throws(() => loadConfig({ ANTHROPIC_API_KEY: "k", APP_TOKEN: TOKEN, EFFORT: "turbo" }), /EFFORT/);
  const c = loadConfig({ ANTHROPIC_API_KEY: "k", APP_TOKEN: TOKEN });
  assert.equal(c.model, "claude-opus-5-5");
  assert.equal(c.effort, "low");
});

test("sanitize przepuszcza tylko dozwolone pola", () => {
  const s = sanitize({ ...validBody, model: "x", max_tokens: 99999 });
  assert.deepEqual(Object.keys(s).sort(), ["messages", "system", "tools"]);
});
