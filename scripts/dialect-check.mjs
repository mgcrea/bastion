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
  // Bastion must NOT pass a child's `listChanged: true` through. It drops child
  // notifications on purpose — one instance serves several clients, so there is
  // no single client a `list_changed` belongs to — and a client that believes
  // the advertisement opens `subscriptions/listen`, gets -32601, and drops the
  // whole connection rather than the one subscription. The symptom is a server
  // that connects cleanly and then registers no tools at all.
  check(
    "  listChanged is not advertised on any capability",
    ["tools", "prompts", "resources"].every(
      (k) => !(k in (r?.capabilities ?? {})) || r.capabilities[k]?.listChanged === false,
    ),
    JSON.stringify(r?.capabilities),
  );
  check(
    "  resources.subscribe is not advertised either",
    r?.capabilities?.resources === undefined || !("subscribe" in r.capabilities.resources),
    JSON.stringify(r?.capabilities?.resources),
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
  // A modern list result MUST say how long it may be cached and by whom. The
  // client validates the whole result against that schema, so a missing field
  // does not degrade caching — it throws the tool list away. Claude Code
  // reports it as "Invalid result for tools/list: ttlMs expected number".
  check(
    "  it carries a numeric ttlMs",
    typeof json?.result?.ttlMs === "number",
    JSON.stringify(json?.result?.ttlMs),
  );
  check(
    "  and a cacheScope of public or private",
    ["public", "private"].includes(json?.result?.cacheScope),
    JSON.stringify(json?.result?.cacheScope),
  );
}

{
  const { status, json } = await modern(2, "tools/call", {
    name: "shopify_get_shop",
    arguments: {},
  });
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
  const encoded = `=?base64?${Buffer.from("shopify_get_shop", "utf8").toString("base64")}?=`;
  const { status, json } = await modern(
    3,
    "tools/call",
    { name: "shopify_get_shop", arguments: {} },
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
    { name: "shopify_get_shop", arguments: {} },
    {
      headers: { "Mcp-Name": "shopify_list_products" },
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
console.log("Streaming a reply (inbound SSE)");

// Bastion may answer a POST with `text/event-stream` carrying the child's
// `notifications/progress` ahead of the result. That is the CURRENT transport,
// not the deprecated HTTP+SSE one: still one POST, one response, no session,
// and GET/DELETE above are still 405 — which is why those checks stay where
// they are rather than moving in here.
//
// It is opted into TWICE: `Accept` must name the media type AND the request
// must carry a `progressToken`. The gate checks below are unconditional, and
// they are the ones that matter — they pin the promise that nothing about a
// call that did not ask for a stream has changed.
{
  const withToken = (progressToken = "check-1") => ({
    ...meta(),
    progressToken,
  });
  // `tools/list` by default, because every server has one and no server emits
  // progress for it — which makes the gate checks below universal and the shape
  // check a skip. Point this at a call that DOES emit progress to run the shape
  // check for real, e.g.
  //
  //   PROGRESS_TOOL=app_store_connect_get_analytics_status \
  //   PROGRESS_ARGS='{"appId":"6761669031"}' \
  //   PROFILE=prod SERVER=appstore-connect node scripts/dialect-check.mjs
  const PROGRESS_TOOL = process.env.PROGRESS_TOOL;
  const method = PROGRESS_TOOL ? "tools/call" : "tools/list";
  const args = PROGRESS_TOOL
    ? { name: PROGRESS_TOOL, arguments: JSON.parse(process.env.PROGRESS_ARGS ?? "{}") }
    : {};
  const call = (headers, _meta) =>
    post(
      {
        jsonrpc: "2.0",
        id: 60,
        method,
        params: { ...args, _meta: _meta ?? meta() },
      },
      {
        headers: {
          "MCP-Protocol-Version": MODERN,
          "Mcp-Method": method,
          ...(PROGRESS_TOOL ? { "Mcp-Name": PROGRESS_TOOL } : {}),
          ...headers,
        },
      },
    );

  {
    // The gate that keeps every existing client's every existing call exactly
    // as it was: every conforming client already sends this Accept, so without
    // the token requirement this would restyle the whole product overnight.
    const { headers } = await call({}, meta());
    check(
      "no progress token means no stream, whatever Accept says",
      headers.get("content-type")?.startsWith("application/json") === true,
      headers.get("content-type"),
    );
  }

  {
    const { headers } = await call({ Accept: "application/json" }, withToken());
    check(
      "a client that only reads JSON is never sent a stream",
      headers.get("content-type")?.startsWith("application/json") === true,
      headers.get("content-type"),
    );
  }

  {
    // curl's default. A wildcard means "I'll take anything", not "I asked for a
    // stream", and answering JSON to a client that would have read one is safe
    // where the reverse is not.
    const { headers } = await call({ Accept: "*/*" }, withToken());
    check(
      "a wildcard Accept is not an SSE Accept",
      headers.get("content-type")?.startsWith("application/json") === true,
      headers.get("content-type"),
    );
  }

  {
    const { status, headers, text } = await call({}, withToken("check-shape"));
    const streamed = headers.get("content-type")?.startsWith("text/event-stream") === true;
    if (!streamed) {
      // Not a failure. Most servers emit no progress at all, and this suite has
      // to run against whichever one the machine has installed. The framing and
      // the token round trip are asserted without a server in `make unit`.
      console.log(
        `  \x1b[33mskip\x1b[0m  the stream shape — ${SERVER} sent no progress for ${method}`,
      );
    } else {
      const events = text
        .split(/\n\n/)
        .map((block) =>
          block
            .split(/\n/)
            .filter((l) => l.startsWith("data:"))
            .map((l) => l.replace(/^data: ?/, ""))
            .join("\n"),
        )
        .filter(Boolean)
        .map((payload) => {
          try {
            return JSON.parse(payload);
          } catch {
            return null;
          }
        });
      check("a streamed reply is still a 200", status === 200, status);
      check("it carries no content-length", !headers.get("content-length"));
      check("and mints no session id", !headers.get("mcp-session-id"));
      check("no event carries an SSE id, which would invite Last-Event-ID", !/\nid:/.test(text));
      check("every event parses as JSON", events.length > 0 && events.every(Boolean));
      const last = events[events.length - 1];
      check(
        "the last event is the response, under the client's own id",
        last?.id === 60 && (last?.result !== undefined || last?.error !== undefined),
        JSON.stringify(last)?.slice(0, 120),
      );
      const progress = events.slice(0, -1);
      check(
        "everything before it is a progress notification",
        progress.every((e) => e?.method === "notifications/progress"),
      );
      // The negative that catches a half-finished remap. Bastion rewrites the
      // token on the way out so two clients cannot collide on a shared child,
      // and the client must never see the id it minted.
      check(
        "each one carries the token the CLIENT chose, not Bastion's",
        progress.every((e) => e?.params?.progressToken === "check-shape"),
        JSON.stringify(progress.map((e) => e?.params?.progressToken)),
      );
    }
  }
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
  // The cache annotation is a modern field. A legacy client validates against
  // the 2025-11-25 schema, and handing it fields from a later revision is the
  // same category of mistake as omitting them from a modern one.
  check(
    "  and carries no cache annotation",
    list.json?.result?.ttlMs === undefined && list.json?.result?.cacheScope === undefined,
    JSON.stringify({ ttlMs: list.json?.result?.ttlMs, cacheScope: list.json?.result?.cacheScope }),
  );
}

console.log("");
if (failures > 0) {
  console.log(`${failures} check(s) failed.`);
  process.exit(1);
}
console.log("All checks passed.");
