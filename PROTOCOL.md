# jove.nvim ↔ jove_bridge protocol (v1, stable)

This document defines the JSON-lines protocol on the bridge's stdio. One
Jupyter kernel is owned by one bridge process; the bridge speaks to it over
ZMQ, exposes a small async request/response surface to the editor on its
stdin/stdout, and keeps the editor-side state machine in lock-step with the
kernel.

The protocol is line-oriented and `UTF-8`. Every request is a single JSON
object terminated by `\n`. Replies and events share the same shape. The three
top-level kinds are distinguished by the presence of:

- `id`         → request, expecting a `result` reply
- `id`+`event` → notification, no reply expected
- (no `id`)    → reply/message

Lines that cannot be parsed are dropped silently.

## Frame schema

### Request

```jsonc
{
  "id":   <integer>,           // monotonic request id assigned by the editor
  "method": "<string>",        // see Methods
  "params": { ... }            // method-specific parameters
}
```

### Result (success)

```jsonc
{
  "id":     <integer>,         // echoes the request id
  "result": { ... }            // method-specific result (Methods)
}
```

### Error

```jsonc
{
  "id":    <integer>,
  "error": {
    "ename":   "<string>",
    "evalue":  "<string>",
    "traceback": ["<string>", ...]   // optional
  }
}
```

### Event

```jsonc
{
  "event":   "<string>",       // e.g. "output", "kernel_status"
  "params":  { ... }           // event-specific
}
```

`id` is **absent** on events.

## Methods

All methods are async on the editor side; the kernel-side work happens on the
bridge's worker thread. Where a method can be answered only after a kernel
round-trip, the bridge first replies with `_DEFERRED` indirectly: it queues the
request as "pending" and emits the actual `result` later — the editor knows
which reply id to expect because it issued the request.

### list_kernelspecs

```jsonc
// → request params: {}
// ← result: { "kernelspecs": { "<name>": { "name", "display_name", "language" }, ... } }
```

Returns one entry per installed kernelspec on the host.

### start_kernel

```jsonc
// → request params: { "kernelspec": "<name>" }
// ← result: { "kernelspec": { "name", "display_name", "language" } }
// + emits kernel_status events: "starting" → "busy" → "idle"
```

The `kernelspec.language` is also stashed as `entry.language` on the Lua
side (lowercased). The variable inspector and any python-only features gate
on this field.

### execute

```jsonc
// → request params: { "code": "<source>", "cell": "<opaque-key>" }
// ← result (no error):
//           { "status": "ok",                          // success
//             "execution_count": <integer>             // OPTIONAL — Phase A
//           }
// ← result (error):
//           { "status": "error",                       // failure / abort
//             "ename": "<string>",
//             "evalue": "<string>",
//             "execution_count": <integer>             // OPTIONAL — Phase A
//           }
```

`cell` is an opaque key (the content-hash of the cell as computed by the
editor) used to tag iopub events back to the originating cell. The bridge
stores it on a pending entry; iopub messages become `output` events for the
same cell until the shell `execute_reply` is processed. A late-iopub grace
window (default 10 s) keeps the cell resolvable after the shell reply so
trailing streams/errors aren't dropped.

`execution_count` is taken straight from the kernel's `execute_reply`. Editor
side uses it to render `In [n]` / `Out [n]` chrome and to persist real
counts into the saved `.ipynb` (gated by `config.persist_exec_counts`). Its
omission is tolerated: the editor falls back to `nil` (encoded as JSON
`null`).

### interrupt

```jsonc
// → request params: {}
// ← result: {}
```

Sends an interrupt signal to the kernel. Queued executes abort with a
synthesized error output (the iopub channel does not publish a message for
aborted executes).

### restart

```jsonc
// → request params: {}
// ← result: {}
// + emits kernel_status events: "restarting" → "busy" → "idle"
```

All in-flight shell requests fail with `kernel_not_running` and all
`execute` kind pendings emit a synthetic error output for their cell.

### shutdown

```jsonc
// → request params: {}
// ← result: {}
```

Replies first, then stops the bridge (which stops the kernel).

### complete

```jsonc
// → request params: { "code": "<prefix>", "cursor_pos": <integer> }
// ← result: { "matches": [ "<string>", ... ] }
```

Jupyter `complete_request`. Editor keymaps offering completion call this.

### inspect

```jsonc
// → request params: { "code": "<expr>", "cursor_pos": <integer> }
// ← result: { "mime": { "<mime-type>": "<rendered-data>" } }
```

Jupyter `inspect_request`. Editor sidebar `<CR>` on a variable calls this
to fetch a richer representation for the float.

### variables  (added in v1, Phase D)

```jsonc
// → request params: {}
//   editor-only: gate on entry.language == "python" before sending
// ← result:    { "variables": [ { "name", "type", "value", "size" }, ... ] }
// ← result:    { "variables": [], "unsupported": "<language>" }   // non-python
// ← error:     { "ename": "<msg>", "evalue": "<detail>" }        // when probe fails
```

Implemented as an `execute_request` with `silent=False, store_history=False,
code=""` and a single user-expression that snapshots the user namespace as a
JSON array (filter dunder/modules, truncate `repr` to 120 chars, look up
`len()` when defined). The bridge unwraps the kernel's `repr` quoting with
`ast.literal_eval` before `json.loads`, then replies.

Side effects: a busy/idle kernel_status pair may noticeably flicker because
the request is non-silent. The bridge discards its own iopub stream text
and does **not** emit `output` events for this probe — the busy/idle events
still pass through; a small kernel_status flicker is acceptable.

## Events

### `output`

```jsonc
{
  "event":  "output",
  "params": {
    "cell":  "<key>",
    "kind":  "stream" | "display_data" | "execute_result" | "error",
    ...                              // kind-specific fields, see below
  }
}
```

#### kind = "stream"

```jsonc
{ "name": "stdout" | "stderr",
  "mime": { "text/plain": "<text>" } }
```

#### kind = "display_data"

```jsonc
{ "mime": { "<mime-type>": "<data>", ... } }
```

#### kind = "execute_result"   (Phase A: execution_count added)

```jsonc
{
  "mime":            { "<mime-type>": "<data>", ... },
  "execution_count": <integer>          // OPTIONAL — Phase A
}
```

`execution_count` is taken from `content.execution_count` of the execute_result
iopub. Editor side uses it to label `Out [n]` outputs and to persist real
counts on cell outputs.

#### kind = "error"

```jsonc
{
  "ename":     "<string>",
  "evalue":    "<string>",
  "traceback": ["<string>", ... ],
  "mime":      { "text/plain": "<joined-traceback-or-summary>" }
}
```

### `kernel_status`

```jsonc
{ "event":  "kernel_status",
  "params": { "status": "starting" | "busy" | "idle" | "restarting" | "dead" } }
```

The first post-subscription `idle` is **synthesized** from a kernel_info
readiness roundtrip — early iopub status messages are racy (XPUB/PUB drops
messages published before the subscription registers, kernel-side). All
subsequent `idle`/`busy` events come from iopub `status` messages.

## Outstanding requests lifecycle

Each editor-issued request id is matched against `parent_header.msg_id`
on incoming shell and iopub messages:

- Pending entries are inserted on `dispatch()` and popped on the matching
  shell message.
- Answered executes live on in `_recent` for `LATE_IOPUB_GRACE` (10 s) so
  that late iopub `output` events (typically trailing stream/error text)
  remain taggable to their cell.

## Stability

This contract is **v1**. The additions in Phase A (`execution_count` on
result + execute_result events) and Phase D (`variables` method) are
backwards compatible: omitting new fields is tolerated by the editor and
represented as `null` / absent on the wire.
