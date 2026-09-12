# jove bridge protocol

Wire contract between `lua/jove/bridge.lua` (Neovim) and `python -m jove_bridge`
(sidecar). This document is the single source of truth; the pytest conformance
suite in `python/tests/` doubles as the executable contract.

- Transport: the child process's stdin/stdout, one JSON object per line
  (newline-delimited, UTF-8). stderr is never part of the protocol — the parent
  may log it.
- One kernel per bridge process: the sidecar manages exactly one kernel, spawned
  on `start_kernel`. Neovim spawns one bridge per buffer that needs a kernel.
- Protocol version: 1 (announced in the `ready` event).

## Messages → Neovim (requests)

```jsonc
{"id": 7, "method": "execute", "params": {"code": "print(1)", "cell": "a1b2..."}}
```

- `id`: integer, unique per process, chosen by Neovim.
- `params` keys per method below; a request with no `params` key is treated as
  `{}` — clients SHOULD omit `params` rather than send an empty object, because
  some JSON encoders render an empty table as `[]` rather than `{}`.
  Unknown method → error response with code `"unknown_method"`.
  Malformed JSON line → `{"event": "protocol_error", "params": {"error": "<reason>"}}`.

## Methods

| Method | Params | Result |
|---|---|---|
| `list_kernelspecs` | `{}` | `{kernelspecs: {name: {display_name, language}}}` |
| `start_kernel` | `{kernelspec: "<name>"}` | `{}` |
| `interrupt` | `{}` | `{}` |
| `restart` | `{}` | `{}` |
| `shutdown` | `{}` | `{}` — bridge replies, then stops the kernel and exits 0 |
| `execute` | `{code: "<str>", cell: "<opaque key>"}` | `{status: "ok"}` or `{status: "error", ename, evalue}` — response is deferred until the shell-channel `execute_reply` arrives (iopub events stream in the meantime) |
| `complete` (optional, v2) | `{code: "<str>", cursor_pos: <int>}` | `{matches: [<str>]}` |
| `inspect` (optional, v2) | `{code: "<str>", cursor_pos: <int>, detail_level: 0\|1}` | `{mime: {<mime>: <str>}}` |

`cell` is opaque: Neovim passes the cell content-hash it uses for output
attachment; the bridge echoes it back verbatim in every `output` event for the
execution. Multiple `execute` requests may be in flight; events carry the `cell`
key so outputs route correctly.

## Responses ← Neovim

```jsonc
{"id": 7, "result": {"status": "ok"}}
{"id": 8, "error": {"code": "kernel_not_running", "message": "start a kernel first"}}
```

Error codes (non-exhaustive, always snake_case strings): `unknown_method`,
`invalid_params`, `kernel_not_running`, `kernelspec_not_found`,
`kernel_start_failed`, `internal_error`.

The error object is for transport/lifecycle failures only. An *execution*
failure (user code raised) is reported as a normal response whose result carries
`{status: "error", ename, evalue}` — every `execute` gets exactly one response,
result or error object, never both and never neither. Because an error result
implies an error-kind output event, an interrupted/aborted execution
(`execute_reply status: "abort" | "aborted"`, which carries no iopub error of
its own) is answered with a *synthesized* error output event before the result.

## Events ← Neovim

```jsonc
{"event": "ready", "params": {"protocol": 1, "version": "<package version>"}}
{"event": "kernel_status", "params": {"status": "starting" | "busy" | "idle" | "restarting" | "dead"}}
{"event": "output", "params": {
  "cell": "<opaque key from execute>",
  "kind": "stream" | "display_data" | "execute_result" | "error",
  "name": "stdout" | "stderr",              // kind=stream only
  "mime": {"text/plain": "1\n"},             // stream: text/plain; display_data/
                                              // execute_result: full mime bundle
  "ename": "...", "evalue": "...",            // kind=error only; mime.text/plain
  "traceback": ["...ANSI lines..."]           // carries the raw ANSI traceback
}}
```

- `output` events are emitted in iopub arrival order.
- `kernel_status` mirrors kernel execution state transitions. The bridge *tracks
  and synthesizes* the initial sequence (`starting` on `start_kernel`, `idle`
  once readiness is confirmed via a shell roundtrip): kernels may silently drop
  early iopub messages (XPUB subscribe race), so the first iopub status cannot
  be relied on.
- Every `execute` is answered by exactly one response; a response with
  `status: "error"` implies the `error` kind output event was also emitted.

## Lifecycle rules

- On start, the bridge emits `ready` first. Neovim must not send requests
  before `ready` (it may queue them).
- stdin EOF or SIGTERM/SIGINT → bridge shuts the kernel down (best effort) and
  exits 0.
- `shutdown` method → respond `{}`, then best-effort kernel stop, exit 0.
- `start_kernel` while a kernel is already running has replacement semantics:
  pending requests are failed with `kernel_not_running`, the old kernel is shut
  down (best effort), and the new one started.
- If the kernel dies with execute requests in flight, the bridge answers each
  with `{"error": {"code": "kernel_not_running"}}` — the exactly-one-response
  invariant holds unconditionally.
- Kernel death at any other time → `kernel_status` event with
  `status: "dead"`, then the bridge stays alive to answer requests with
  `kernel_not_running` errors (parent decides whether to respawn).
