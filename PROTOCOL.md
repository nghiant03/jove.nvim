# jove bridge protocol, version 1

The sidecar runs as `python -m jove_bridge`. One process owns at most one
Jupyter kernel. The Lua client writes newline-delimited JSON to stdin and
reads newline-delimited JSON from stdout. Diagnostic text goes to stderr.
Every message occupies one line; newlines inside strings must be JSON-escaped.

## Envelopes

```json
{"id":1,"method":"execute","params":{"code":"print(42)","cell":"opaque-cell-key"}}
{"id":1,"result":{"status":"ok","execution_count":1}}
{"id":2,"error":{"code":"kernel_not_running","message":"No kernel running"}}
{"event":"ready","params":{"protocol":1,"version":"2.0.0"}}
```

Requests require an integer `id` (not a boolean) and a string `method`.
`params` is an object; omitted/null params mean an empty object. Responses
use the request's ID and contain either `result` or `error`. Events have no
request ID. Malformed request envelopes produce a `protocol_error` event;
invalid method parameters produce an error response. IDs must be unique
among outstanding requests within a process. Replies may arrive out of order.

## Methods

| Method | Parameters | Result |
| --- | --- | --- |
| `list_kernelspecs` | none | `{kernelspecs: {name: spec, ...}}` |
| `start_kernel` | `kernelspec: string` | `{}` after readiness; replaces any existing kernel |
| `execute` | `code: string`, `cell: string` | Kernel execute reply, including `status` and available `execution_count` |
| `complete` | `code: string`, `cursor_pos: integer` | Kernel completion reply |
| `inspect` | `code: string`, `cursor_pos: integer`, optional `detail_level: 0 or 1` | Kernel inspection reply |
| `variables` | none | `{variables: [{name, type, value, size}, ...]}`; Python namespace probe |
| `interrupt` | none | `{}` |
| `restart` | none | `{}` after restarting the kernel |
| `shutdown` | none | `{}`, followed by process cleanup/exit |

Shell-channel operations are deferred until the corresponding kernel reply.
Kernel replacement, death or restart fails outstanding operations rather
than replaying them. Unknown methods return `unknown_method`; parameter
validation returns `invalid_params`. Other error codes describe kernel or
bridge failures; clients should display `message` without relying on its text.

## Events

- `ready`: `{protocol: 1, version: string}`. Bridge startup, not kernel readiness.
- `kernel_status`: `{status: string}`; lifecycle states include `starting`,
  `busy`, `idle`, `restarting`, and `dead`.
- `output`: `{cell: string, kind: string, ...}`. The cell key is echoed
  unchanged from the originating execution request:
  - `stream`: `name` (`stdout`/`stderr`) and `mime["text/plain"]`.
  - `execute_result`: `mime` bundle and available `execution_count`.
  - `display_data`: `mime` bundle.
  - `error`: `ename`, `evalue`, and `traceback` (array of ANSI-bearing strings).
- `protocol_error`: `{error: string}` for malformed incoming requests.

Binary image MIME payloads are base64 strings. The Lua renderer strips ANSI
from error tracebacks; persistence retains the raw event representation.
The Lua client uses a unique wire key per execution and resolves it to a
content/occurrence key locally. Rerunning a cell invalidates the previous
run's route; reload invalidates pending execution routes and metadata.

IOPub and shell sockets have no cross-socket ordering guarantee. Output can
arrive after an execute reply; the sidecar retains cell routing for ten seconds
after that reply. A reply is not a guarantee that all output has arrived.

## Client lifecycle and limits

The Lua handle queues requests until `ready`, with a 20-second bridge startup
deadline. Ordinary sent requests time out after 15 seconds; kernel start and
restart use 30 seconds, variable inspection uses five seconds, and execution
has no client timeout. Client timeout does not cancel kernel execution.

Unexpected exits fail outstanding/queued requests. The Lua handle retries
startup up to three times with 1/2/4-second backoff, reset on readiness.
Intentional stop/shutdown suppresses respawn. The Lua-only `dead` event reports
process exit and is distinct from the wire `kernel_status: dead` event.
Kernel recovery starts a fresh namespace; variables are not restored.

The writer queue is bounded to 256 messages and applies producer backpressure.
A broken writer stops accepting messages and reports the failure on stderr.
The Lua output store applies `output.max_bytes` per cell and batches live
redraws. These are client retention limits, not Jupyter kernel memory limits.
