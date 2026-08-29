#!/usr/bin/env node
// Assert Bastion behaves as a dual-era MCP server.
//
// The 2026-07-28 spec calls a "dual-era" server one that serves both modern
// clients (per-request `_meta`, no handshake) and legacy ones (an `initialize`
// handshake). Bastion is one, in front of children that are all legacy — every
// server in the manifest runs an SDK whose newest protocol is 2025-11-25.
//
// Almost everything here is a check on an exact number or an exact status
// code, because that is what the spec actually constrains and what a real
// client branches on. A dual-era client inspects the BODY of a 400 to decide
// whether it found a modern server to retry against or a legacy one to fall
// back to, so returning the right code with the wrong body is worse than
// failing outright: it sends a working client down the legacy path forever.
//
//   PROFILE=prod SERVER=shopify node scripts/dialect-check.mjs

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PORT = process.env.BASTION_PORT ?? "8720";
const PROFILE = process.env.PROFILE ?? "prod";
const SERVER = process.env.SERVER ?? "shopify";
const SUPPORT = join(homedir(), "Library/Application Support/io.mgcrea.bastion.debug");
const URL_RPC = `http://127.0.0.1:${PORT}/s/${PROFILE}/${SERVER}`;
const MODERN = "2026-07-28";

const token = readFileSync(join(SUPPORT, "dev-token"), "utf8").trim();

let failures = 0;
const pass = (what) => console.log(`  \x1b[32mok\x1b[0m    ${what}`);
const fail = (what, detail) => {
  console.log(`  \x1b[31mFAIL\x1b[0m  ${what}`);
  if (detail !== undefined) console.log(`          ${detail}`);
  failures += 1;
};

const check = (what, condition, detail) => (condition ? pass(what) : fail(what, detail));

/** Modern metadata, namespaced exactly as the spec writes it. */
const meta = (version = MODERN) => ({
  "io.modelcontextprotocol/protocolVersion": version,
  "io.modelcontextprotocol/clientInfo": { name: "dialect-check", version: "1.0.0" },
  "io.modelcontextprotocol/clientCapabilities": {},
});

const post = async (body, { headers = {}, method = "POST", url = URL_RPC } = {}) => {
  const init = {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      // The spec requires a client to list both; Bastion answers with JSON
      // today, and a client that only accepted JSON would be non-conforming.
      Accept: "application/json, text/event-stream",
      ...headers,
    },
  };
  // Assigned rather than passed as `undefined`: a fetch init carrying a `body`
  // key at all is invalid for GET and DELETE, whatever its value.
  if (method !== "GET" && method !== "DELETE") init.body = JSON.stringify(body);
  const response = await fetch(url, init);
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: response.status, json, text, headers: response.headers };
};

/** A conforming modern request: body `_meta` and the mirrored headers agree. */
const modern = (id, method, params = {}, { version = MODERN, headers = {} } = {}) => {
  const body = { jsonrpc: "2.0", id, method, params: { ...params, _meta: meta(version) } };
  const mirrored = { "MCP-Protocol-Version": version, "Mcp-Method": method };
  const name = params.name ?? params.uri;
  if (name !== undefined) mirrored["Mcp-Name"] = name;
  return post(body, { headers: { ...mirrored, ...headers } });
};

console.log("");
console.log("Modern era");

{
  const { status, json } = await modern("d1", "server/discover");
  const r = json?.result;
  check(
    "server/discover returns a result",
    status === 200 && r,
    `${status} ${JSON.stringify(json)?.slice(0, 160)}`,
  );
  check('  resultType is "complete"', r?.resultType === "complete", r?.resultType);
  check(
    `  supportedVersions includes ${MODERN}`,
    Array.isArray(r?.supportedVersions) && r.supportedVersions.includes(MODERN),
    JSON.stringify(r?.supportedVersions),
  );
  check(
    "  capabilities are the child's",
    r?.capabilities && "tools" in r.capabilities,
    JSON.stringify(r?.capabilities),
  );
  const info = r?._meta?.["io.modelcontextprotocol/serverInfo"];
  check(
    "  serverInfo names the child, not Bastion",
    info?.name && info.name !== "bastion",
    JSON.stringify(info),
  );
}

{
  const { status, json } = await modern(1, "tools/list");
  check(
    "tools/list works with no handshake at all",
    status === 200 && Array.isArray(json?.result?.tools),
    status,
  );
  check(
    '  the result carries resultType "complete"',
    json?.result?.resultType === "complete",
    json?.result?.resultType,
  );
}

{
  const { status, json } = await modern(2, "tools/call", { name: "get_shop", arguments: {} });
  check(
    "tools/call with a matching Mcp-Name",
    status === 200 && !json?.error,
    `${status} ${json?.error?.message ?? ""}`,
  );
}

{
  // The spec requires clients to Base64-encode a name that is not header-safe,
  // and servers to decode before comparing. A server that compares the raw
  // header rejects every conforming client that has a non-ASCII tool name.
  const encoded = `=?base64?${Buffer.from("get_shop", "utf8").toString("base64")}?=`;
  const { status, json } = await modern(
    3,
    "tools/call",
    { name: "get_shop", arguments: {} },
    {
      headers: { "Mcp-Name": encoded },
    },
  );
  check(
    "  a Base64-sentinel Mcp-Name is decoded before comparing",
    status === 200 && !json?.error,
    `${status} ${json?.error?.message ?? ""}`,
  );
}

console.log("");
console.log("Header validation (-32020, always 400)");

for (const [what, headers] of [
  ["a missing MCP-Protocol-Version", { "MCP-Protocol-Version": undefined }],
  ["a mismatched MCP-Protocol-Version", { "MCP-Protocol-Version": "2025-11-25" }],
  ["a mismatched Mcp-Method", { "Mcp-Method": "tools/call" }],
]) {
  const clean = Object.fromEntries(Object.entries(headers).filter(([, v]) => v !== undefined));
  const body = { jsonrpc: "2.0", id: 10, method: "tools/list", params: { _meta: meta() } };
  const base = { "MCP-Protocol-Version": MODERN, "Mcp-Method": "tools/list" };
  for (const key of Object.keys(headers)) if (headers[key] === undefined) delete base[key];
  const { status, json } = await post(body, { headers: { ...base, ...clean } });
  check(
    `${what} is rejected`,
    status === 400 && json?.error?.code === -32020,
    `${status} ${JSON.stringify(json?.error)}`,
  );
}

{
  const { status, json } = await modern(
    11,
    "tools/call",
    { name: "get_shop", arguments: {} },
    {
      headers: { "Mcp-Name": "list_products" },
    },
  );
  check(
    "a mismatched Mcp-Name is rejected",
    status === 400 && json?.error?.code === -32020,
    `${status} ${JSON.stringify(json?.error)}`,
  );
}

console.log("");
console.log("Version negotiation (-32022, always 400)");

{
  const { status, json } = await modern(20, "tools/list", {}, { version: "1900-01-01" });
  check(
    "an unknown version is rejected",
    status === 400 && json?.error?.code === -32022,
    `${status} ${JSON.stringify(json?.error)}`,
  );
  check(
    "  the error lists what Bastion supports",
    json?.error?.data?.supported?.includes(MODERN),
    JSON.stringify(json?.error?.data),
  );
  check(
    "  and echoes what was requested",
    json?.error?.data?.requested === "1900-01-01",
    JSON.stringify(json?.error?.data),
  );
}

console.log("");
console.log("Method and transport shape");

{
  const { status, json } = await modern(30, "nonsense/method");
  check(
    "an unknown method is 404 with -32601",
    status === 404 && json?.error?.code === -32601,
    `${status} ${JSON.stringify(json?.error)}`,
  );
}

{
  // "the server MUST return HTTP status code 202 Accepted with no body."
  const body = { jsonrpc: "2.0", method: "notifications/progress", params: { _meta: meta() } };
  const { status, text } = await post(body, {
    headers: { "MCP-Protocol-Version": MODERN, "Mcp-Method": "notifications/progress" },
  });
  check(
    "a notification is 202 with an empty body",
    status === 202 && text === "",
    `${status} body=${JSON.stringify(text)}`,
  );
}

for (const method of ["GET", "DELETE"]) {
  const { status } = await post(undefined, { method });
  check(`${method} on the MCP endpoint is 405`, status === 405, status);
}

{
  // The spec: ignore it, and do not mint or echo session ids. A session id is
  // per-client state on a shared instance, which is the thing the stateless
  // revision removed and the thing that makes this architecture possible.
  const { status, headers } = await modern(
    40,
    "tools/list",
    {},
    {
      headers: { "Mcp-Session-Id": "abc123", "Last-Event-ID": "7" },
    },
  );
  check(
    "Mcp-Session-Id is ignored, not echoed",
    status === 200 && !headers.get("mcp-session-id"),
    `${status} ${headers.get("mcp-session-id")}`,
  );
}

console.log("");
console.log("Legacy era, still served");

{
  const body = {
    jsonrpc: "2.0",
    id: 100,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "legacy-check", version: "1.0.0" },
    },
  };
  const { status, json } = await post(body);
  check(
    "initialize is answered with no mirrored headers at all",
    status === 200 && json?.result,
    `${status} ${JSON.stringify(json)?.slice(0, 140)}`,
  );
  check(
    "  and carries no resultType",
    json?.result?.resultType === undefined,
    json?.result?.resultType,
  );

  const list = await post({ jsonrpc: "2.0", id: 101, method: "tools/list" });
  check(
    "a legacy tools/list still works",
    list.status === 200 && Array.isArray(list.json?.result?.tools),
    list.status,
  );
  check(
    "  and is not modernised either",
    list.json?.result?.resultType === undefined,
    list.json?.result?.resultType,
  );
}

console.log("");
if (failures > 0) {
  console.log(`${failures} check(s) failed.`);
  process.exit(1);
}
console.log("All checks passed.");
