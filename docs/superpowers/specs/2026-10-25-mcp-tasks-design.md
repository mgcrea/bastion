# Long calls as MCP tasks

Status: draft design, 2026-10-25, not approved. Implementation plan: not yet
written.

## Problem

A call through Bastion lives exactly as long as its HTTP request. The gateway
serves it on the connection's own thread and blocks until the child answers
(`Gateway.swift:629-631`). The supervisor gives up after 180 s
(`Supervisor.swift:491`, enforced by the reaper at `:798-806`). So a call
fails in three ways that have nothing to do with the server's work:

- **It runs past 180 s.** Bastion answers `timedOut` while the child carries on.
- **The client gives up first.** Claude Code drops an HTTP MCP call that has
  been silent for five minutes, which is its default idle window.
- **The session ends.** Since 2.1.304, Claude Code moves any call still
  running after two minutes into the background, but only on its own side. The
  call stays a plain call, held open by one connection, and it dies when the
  session exits.

The `io.modelcontextprotocol/tasks` extension (github.com/modelcontextprotocol/
ext-tasks) is the protocol's answer to this. The server replies with a handle,
`resultType: "task"`, and the client polls `tasks/get` until the task reaches a
terminal status. Claude Code shipped client support as a public beta on
2026-10-23: CLI v2.1.304 or later, in interactive sessions, the Agent SDK and
GitHub Actions. VS Code, the desktop app and one-shot `claude -p` don't have it.
Bastion can't offer tasks today, for three reasons:

- it removes the client's capabilities before forwarding a request
  (`Dialect.swift:196`);
- it advertises no extensions in `server/discover` (`Dialect.swift:410`,
  `Supervisor.swift:1323`);
- an unknown method such as `tasks/get` gets a `404`.

Goal: a call from a client that supports tasks, and that is still running a
few seconds in, becomes a task that Bastion owns. It then gets its own longer
deadline, frees the HTTP connection, and survives the client exiting. Fast
calls, legacy clients and clients without the extension see no change at all.

## Demand, measured

Bastion's usage rollup for the 30 days to 2026-10-25 (`server_stats`, every
profile on this Mac) shows 6,347 calls, a p50 of 0.7 s and a p95 of 8 s. The
long tail is short:

| Server                         | Kind   | Slowest call | p95    |
| ------------------------------ | ------ | ------------ | ------ |
| `prod/appstore-connect`        | child  | 188.6 s      | 8.5 s  |
| `prod/cloudflare` (`execute`)  | remote | 164.5 s      | 55.5 s |
| `local/calque-dev`             | child  | 154.6 s      | 0.7 s  |
| `system/xcode` (RenderPreview) | system | 154.4 s      | 7.5 s  |

So one call reached the cap in a month, and three more passed the two-minute
mark. No `BuildProject` or `RunAllTests` call went through Bastion in the
window at all, so the motivating case ("Xcode builds exceed 180 s") is an
expectation, not an observation. The design below is sound, but whether it is
worth building depends on whether long jobs (Xcode builds and test runs, CI
waits, bulk uploads) are meant to go through Bastion. That is the decision this
document leaves to the user (see **Open decision**).

## Design

### Overview

```
client ──tools/call (+tasks ext)──▶ Gateway ──▶ Supervisor.call (worker thread)
                                     │  waits up to 10 s
                                     ├─ answered in time ─▶ plain result, as today
                                     └─ still running ────▶ TaskStore.create
                                                           ◀─ resultType "task"
client ──tasks/get──▶ Gateway ──▶ TaskStore (no child, no spawn)
worker thread: child replies ──▶ TaskStore.settle(result)
```

The child protocol doesn't change. Children stay legacy and never see a task.
Bastion turns a slow call into a task on the client's side and keeps the child
call it already knows how to make.

### What the client must have sent

Bastion makes a call into a task only when all of these hold:

1. The request is modern (2026-07-28) and is a `tools/call` with an id.
2. Its `params._meta["io.modelcontextprotocol/clientCapabilities"].extensions`
   contains `"io.modelcontextprotocol/tasks"`. The gateway reads this before
   anything strips it (`Dialect.stripModernMeta`, `Dialect.swift:196`). A new
   `Dialect.declaresTasks(_ frame:) -> Bool` beside the other `_meta` helpers.
3. The server's transport is `.child` or `.system` (`Supervisor.swift:194`).
   `.inProcess` answers instantly, and `.remote` is out of scope for v1
   (see **Out of scope**).
4. Fewer than `TaskStore.maxRunning` (32, my call) tasks are running. At the
   cap, the call runs exactly as it does today, with the 180 s deadline.

When any condition fails, nothing differs from today. That keeps the spec's
rule ("never return a task to a client that did not declare support") and the
anti-goal that legacy clients, Claude Desktop through the bridge, VS Code and
Codex are untouched.

### Grace period, then promotion

A call that is eligible goes to a worker thread (`onDedicatedThread`, which
the gateway already uses) running the same `Supervisor.call`. The connection
thread waits on it for up to **10 s** (my call):

- it must stay well under Claude Code's per-request timer, which is at least
  60 s;
- it must stay well over the p50 of 0.7 s and the p95 of 8 s, so nearly every
  call still comes back plain, with no polling round trip and with latency
  figures unchanged.

If the worker finishes in time, the connection answers exactly as it does
today, including streaming progress. If not, the gateway:

1. calls `TaskStore.create(owner:)` and gets back a `taskId`;
2. answers `{resultType: "task", taskId, status: "working", createdAt,
lastUpdatedAt, ttlMs, pollIntervalMs: 5000}`, and then
3. closes the connection, which releases its slot in the 64-connection budget
   (`Gateway.swift:68`).

The worker keeps running. When `Supervisor.call` returns or throws, it shapes
the reply exactly as `handleRPC` would (`modernise`, `Gateway.swift:672`, or
`rpcError`), then calls `TaskStore.settle(taskId, …)`.

A race is possible: the worker can finish in the instant the grace period
ends. `TaskStore` resolves it with one lock, and whichever side gets there
first wins. If the worker settles before `create` returns to the gateway, the
task is created already `completed`. That is legal, and the client's first
`tasks/get` returns it.

### The longer deadline

The waiter's deadline is fixed when `awaitReply` creates it
(`Supervisor.swift:1041`). Rather than extend it on promotion, the gateway
passes a `deadline` into `Supervisor.call` → `Instance.handle` →
`awaitReply`:

- **60 minutes** (`TaskStore.taskedCallTimeout`, my call) when the call is
  eligible for a task;
- `callTimeout` (180 s, unchanged) otherwise.

This is safe, because an eligible call either answers within the grace period
or becomes a task. It never sits on a connection for 60 minutes. The reaper
already reads each waiter's own `deadline`, so nothing changes there. Its
`timedOut(seconds:)` message has to report the waiter's actual limit, not the
constant.

### `tasks/get` and `tasks/cancel`

The gateway handles both in `handleRPC`, before `Supervisor.call`, so a poll
never spawns or wakes a child. Both are modern-only. On the legacy era they
fall through to the child as unknown methods, as today.

- **Ownership.** A task belongs to `(client, profile, server)`. `client` is
  the token's Keychain account, which `route` already resolves
  (`Gateway.swift:393`); `profile` and `server` come from the request path. A
  `tasks/get` whose task doesn't exist, has expired, or belongs to another
  owner gets one and the same error, so the error can't be used to probe
  other clients' task ids. That is the stance the 401 already takes
  (`Gateway.swift:404-409`). The message says the task is unknown, "or
  Bastion restarted since it was created". The builder takes the exact error
  code from ext-tasks.
- **`tasks/get`** returns the current state. When the task is terminal it
  also returns `result` (on `completed`) or `error` (on `failed`), as the
  extension specifies.
- **`tasks/cancel`** marks the task `cancelled`, then:
  - sends `notifications/cancelled` to the child with Bastion's internal
    request id. `TaskStore` keeps that id, so this skips the client-id search
    in `Dialect.cancelForChild`;
  - resolves the waiter, so the worker thread exits;
  - answers with an empty result.

  A late reply from the child is dropped. The spec allows a task to reach a
  different terminal status, but reporting `cancelled` after acknowledging the
  cancel is the less surprising answer (my call).

### `TaskStore`

A new file holding a `nonisolated final class TaskStore: Sendable` with an
`OSAllocatedUnfairLock` state, the same pattern as `Gateway` and `Instance`.
It must import nothing app-specific, so `scripts/unit-check.swift` can
compile it alone.

| Field                        | Notes                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------- |
| `taskId`                     | `bt-` + 32 hex chars from `SecRandomCopyBytes`; spec limit 128 ASCII, no spaces |
| owner                        | `(client, profile, server)`                                                     |
| `internalID`, child key      | for cancel                                                                      |
| `status`                     | `working` → `completed` / `failed` / `cancelled`; never `input_required`        |
| `statusMessage`              | latest progress message, see below                                              |
| `createdAt`, `lastUpdatedAt` | ISO 8601                                                                        |
| `result` or `error`          | the already-modernised JSON, held as `SendableJSON`                             |

**Retention.** A terminal task is kept for 15 minutes after it settles, then
evicted by a sweep. The store has its own timer at the reaper's 10 s cadence.
`ttlMs` reports what Bastion will really honour: the 60-minute deadline plus
15 minutes from creation. The builder confirms against ext-tasks that `ttlMs`
counts from creation.

**Memory.** Results can be megabytes (`DocumentationSearch` averages 39 KB,
and simulator screenshots are larger). Bounding running tasks at 32 and
evicting settled ones after 15 minutes is enough (my call). There is no byte
cap in v1.

Tasks live in memory only. A task can't outlive Bastion, because the child
running it is Bastion's own subprocess and dies with it (`stopAll`,
`Supervisor.swift:203`). A record on disk could only ever say "failed".

### Progress becomes `statusMessage`

When the client asked for progress (`Dialect.requestedProgressToken`), the
gateway builds the `ProgressSink` (`Gateway.swift:598-600`). After promotion the
stream has been answered and closed. The sink becomes a closure that checks
whether the call was promoted:

- if it was, it writes the notification's `message` (or "n of total") into
  the task's `statusMessage` and `lastUpdatedAt`;
- if not, it sends to the stream, as today.

Bastion doesn't mint its own progress token toward a child when the client
asked for none (my call, kept small for v1).

### Discovery

`Instance.discoverReply` (`Supervisor.swift:1323`) adds
`capabilities.extensions["io.modelcontextprotocol/tasks"] = {}` for `.child`
and `.system` servers. `Dialect.discoverResult` stays shared with
`RemoteInstance` and unchanged, so remote servers don't advertise tasks.

### Activity, stats and the audit log

- **One log row per call, unchanged.** The row is written in `Instance.handle`
  and the child's reply is attached by `received`, both before any task
  exists. Polls never reach the supervisor, so they write no rows.
- **`CallStats`.** For a task, the worker records the sample when the call
  settles, with `started` taken from the original request. The latency
  figure is the real duration, not the 10 s grace period.
- **Plumbing.** `tasks/get` and `tasks/cancel` join
  `CallStatsRollup.plumbingMethods` (`CallStatsRollup.swift:339`), so a
  2-second poll doesn't swamp the usage pane.

### Docs and copy

- `Gaps.astro` keeps its "Server-initiated" line (`:25`), which stays true:
  tasks never reach `input_required`, because elicitation is still refused.
  A new row says that a slow call from Claude Code's CLI becomes a task Bastion
  holds for up to an hour, and that other clients wait on the connection as
  before.
- `docs/clients.md` gets a short "Long calls" note covering:
  - the 10 s promotion;
  - the 60-minute deadline;
  - which clients get tasks;
  - what a restart does.
- The CHANGELOG comes through the release, as usual.

## Testing

- **`scripts/unit-check.swift`, against `TaskStore` alone:**
  - create, then settle, then get;
  - a get from the wrong owner returns the same error as an unknown id;
  - cancel, then a late settle, stays `cancelled`;
  - the create/settle race in both orders;
  - eviction after retention;
  - `maxRunning`;
  - `taskId` shape.
- **`Dialect.declaresTasks`** in the same file, next to the existing `Dialect`
  checks: present, absent, legacy frame, malformed `_meta`.
- **`make dialect`:**
  - a modern `tools/call` with the extension against a tool that sleeps
    past 10 s comes back as a task;
  - `tasks/get` settles it;
  - the same call without the extension blocks and returns plain;
  - a legacy-era `tasks/get` is forwarded as before.

  No catalog server has a tool that sleeps on demand. The builder chooses
  between a fixture child added with `add_custom_server` for the run, and
  driving a real slow tool.

- **Manual check:** Claude Code 2.1.310 CLI against `system/xcode` running
  `RunAllTests` on a suite slower than 10 s:
  - `/tasks` lists it;
  - exiting and running `claude --resume` reattaches to it;
  - the result arrives.

## Out of scope

- **Remote servers.** `RemoteInstance` has its own 180 s `URLSession` timeout
  (`RemoteInstance.swift:72`, `:138`, `:697`) and buffers the reply whole for
  the anti-rebinding check. Turning its calls into tasks is the same design
  with a per-call timeout added. Cloudflare's `execute` at 164 s would be the
  first beneficiary. That comes after v1.
- **Passing an upstream server's own tasks through.** A modern remote server
  that returns its own tasks would need Bastion to route `tasks/get` upstream.
- **`input_required`, `tasks/update`, `tasks/list` and `notifications/tasks`.**
  Claude Code uses none of the last three, and the first two need
  elicitation, which Bastion refuses.
- **Tasks surviving a restart of Bastion or a Sparkle update.** Deferring an
  update while tasks are running would be a separate change.
- **Per-server deadlines,** and a UI listing running tasks.

## Anti-goals

- A fast call answers any later than today, or a client that didn't declare
  the extension ever receives `resultType: "task"`.
- One client can learn anything about another client's task, including
  whether its id exists.
- Polling shows up as usage, or adds Activity rows.

## Open decision

Build now, or park until long jobs actually go through Bastion? On the measured
traffic (one call over the cap in 30 days), v1 mostly prepares for Xcode builds
and test runs that the agents don't route through Bastion today.
