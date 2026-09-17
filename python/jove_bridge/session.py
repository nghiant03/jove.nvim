"""Session logic: shell-channel requests, iopub collection, event routing.

One worker thread (see :meth:`BridgeSession.poll_forever`) polls the iopub and
shell channels and routes messages:

- iopub ``stream`` / ``display_data`` / ``execute_result`` / ``error`` become
  ``output`` events tagged with the opaque ``cell`` key of the originating
  ``execute`` request, in iopub arrival order.
- iopub ``status`` becomes ``kernel_status`` events (starting/busy/idle).
- shell ``execute_reply`` completes the deferred ``execute`` response.
"""

from __future__ import annotations

import ast
import json
import threading
import time
import traceback
from typing import Any, Callable, Optional

from .kernel import KernelController, KernelError

# Isolate repr/len failures so one object cannot discard the variable listing.
# Underscore-prefixed helpers are hidden from the listing.
_VARIABLES_HELPERS = (
    "def _jv_repr(v):\n"
    "    try:\n"
    "        return repr(v)[:120]\n"
    "    except Exception:\n"
    "        return '<repr failed>'\n"
    "def _jv_size(v):\n"
    "    try:\n"
    "        return len(v)\n"
    "    except Exception:\n"
    "        return None\n"
)

# Evaluated via user_expressions in the kernel's user namespace. Use builtins
# and explicit imports so inspection does not depend on the user's imports.
VARIABLES_EXPR = (
    "exec(" + repr(_VARIABLES_HELPERS) + ", globals()) or __import__('json').dumps(["
    "{'name': _jv_n, 'type': type(_jv_v).__name__, "
    "'value': _jv_repr(_jv_v), "
    "'size': _jv_size(_jv_v)}"
    " for _jv_n, _jv_v in list(globals().items())"
    " if not _jv_n.startswith('_') and type(_jv_v).__name__ != 'module'"
    "])"
)

# Sentinel returned by dispatch() when the response will be sent later by the
# poll thread (e.g. execute waits for the shell-channel execute_reply).
DEFERRED = object()

# ZMQ does not order messages across sockets. Retain cell routing for this
# many seconds after a shell reply so late iopub outputs can still be delivered.
LATE_IOPUB_GRACE = 10.0


class _Pending:
    """An in-flight shell request awaiting its reply."""

    __slots__ = ("kind", "reply_id", "cell")

    def __init__(
        self, kind: str, reply_id: Optional[int], cell: Optional[str] = None
    ) -> None:
        self.kind = kind
        self.reply_id = reply_id  # None for internal probes
        self.cell = cell


class BridgeSession:
    """Bridges protocol requests onto one Jupyter kernel."""

    def __init__(self, conn: Any) -> None:
        # ``conn`` is a thread-safe object with send_result/send_error/
        # send_event (see jove_bridge.__main__.Connection).
        self.conn = conn
        self.kernel = KernelController()
        # msg_id -> _Pending, shared between the main thread (insert) and the
        # poll thread (pop); guard mutations with the lock.
        self.pending: dict = {}
        # msg_id -> (cell, expiry): answered executes whose late iopub
        # messages (delivered after the shell reply) are still tagged to
        # their cell; see LATE_IOPUB_GRACE.
        self._recent: dict = {}
        self._lock = threading.Lock()
        # libzmq sockets are not thread-safe and jupyter_client's
        # ZMQSocketChannel has no locking of its own: serialize every
        # shell-channel send (main thread) and recv (poll thread).
        self._shell_lock = threading.Lock()
        self._stop = threading.Event()
        self._restarting = False
        self._shutting_down = False
        # Set once the kernel_info readiness roundtrip completes (or times
        # out); early iopub status messages are racy (ZMQ PUB drops messages
        # published before our subscription registers kernel-side), so the
        # initial idle status is synthesized from the shell roundtrip instead.
        self._ready = threading.Event()
        # Set once the kernel confirmed our iopub subscription (iopub_welcome,
        # ipykernel >= 7): from this point iopub delivery is dependable.
        self._iopub_live = threading.Event()

    def dispatch(self, method: str, params: Any, reply_id: int) -> Any:
        """Handle one protocol request; returns a result dict or DEFERRED."""
        if not isinstance(params, dict):
            raise KernelError("invalid_params", f"{method}: params must be an object")
        if method == "list_kernelspecs":
            return {"kernelspecs": self.kernel.list_kernelspecs()}
        if method == "start_kernel":
            self._param(params, "kernelspec", str, method)
            return self.start_kernel(params["kernelspec"])
        if method == "interrupt":
            self.kernel.interrupt()
            return {}
        if method == "restart":
            return self.restart()
        if method == "shutdown":
            # Reply immediately; __main__ stops the kernel after responding.
            self._shutting_down = True
            return {}
        if method == "execute":
            self._param(params, "code", str, method)
            self._param(params, "cell", str, method)
            return self.execute(params["code"], params["cell"], reply_id)
        if method == "complete":
            self._param(params, "code", str, method)
            self._param(params, "cursor_pos", int, method)
            return self.complete(params["code"], params["cursor_pos"], reply_id)
        if method == "inspect":
            self._param(params, "code", str, method)
            self._param(params, "cursor_pos", int, method)
            detail = params.get("detail_level", 0)
            if isinstance(detail, bool) or detail not in (0, 1):
                raise KernelError(
                    "invalid_params", "inspect: 'detail_level' must be 0 or 1"
                )
            return self.inspect(params["code"], params["cursor_pos"], detail, reply_id)
        if method == "variables":
            return self.variables(reply_id)
        raise KernelError("unknown_method", f"unknown method: {method!r}")

    @staticmethod
    def _param(params: dict, key: str, types: Any, method: str) -> None:
        value = params.get(key)
        if isinstance(value, bool) or not isinstance(value, types):
            name = getattr(types, "__name__", str(types))
            raise KernelError(
                "invalid_params",
                f"{method}: {key!r} is required and must be a {name}",
            )

    def start_kernel(self, kernelspec: str) -> dict:
        # Validate first so an invalid spec leaves the running kernel and requests intact.
        self.kernel.require_kernelspec(kernelspec)
        # The existing kernel is being replaced; its in-flight requests will
        # never come back on the new kernel, so fail them now.
        self._fail_pending("kernel_not_running", "kernel was replaced")
        self.kernel.start(kernelspec)
        self.conn.send_event("kernel_status", {"status": "starting"})
        # Wait for kernel readiness (kernel_info roundtrip + iopub welcome)
        # before replying, then announce idle; see _probe_ready for why the
        # initial idle must not rely on early iopub status messages.
        if not self._probe_ready():
            # Keep the bridge's state consistent with the error: no kernel.
            self.kernel.shutdown()
            raise KernelError(
                "kernel_start_failed",
                "kernel did not become ready within 25s",
            )
        return {}

    def execute(self, code: str, cell: str, reply_id: int) -> Any:
        return self._submit_shell(
            "execute", reply_id, lambda client: client.execute(code), cell
        )

    def complete(self, code: str, cursor_pos: int, reply_id: int) -> Any:
        return self._submit_shell(
            "complete", reply_id, lambda client: client.complete(code, cursor_pos)
        )

    def inspect(
        self, code: str, cursor_pos: int, detail_level: int, reply_id: int
    ) -> Any:
        return self._submit_shell(
            "inspect",
            reply_id,
            lambda client: client.inspect(code, cursor_pos, detail_level=detail_level),
        )

    def variables(self, reply_id: int) -> Any:
        """Snapshot user-namespace variables (python kernels only).

        Runs an empty (non-history) execute carrying a user_expression that
        returns a JSON list; the reply is parsed in
        :meth:`_finish_variables`. Non-python kernels short-circuit with an
        ``unsupported`` marker rather than running Python-only code.
        """
        language = self._kernel_language()
        if language and language != "python":
            return {"variables": [], "unsupported": language}
        return self._submit_shell(
            "variables",
            reply_id,
            lambda client: client.execute(
                "",
                # ipykernel 7 drops user_expressions with silent=True. Empty code
                # avoids output; store_history=False keeps the probe out of history.
                silent=False,
                store_history=False,
                user_expressions={"__jove__": VARIABLES_EXPR},
            ),
        )

    def _kernel_language(self) -> Optional[str]:
        """Language of the kernelspec backing the running kernel, if known."""
        km = self.kernel.km
        name = getattr(km, "kernel_name", None) if km is not None else None
        if not name:
            return None
        try:
            spec = self.kernel.list_kernelspecs().get(name) or {}
        except Exception:
            return None
        language = spec.get("language")
        return language or None

    def _finish_variables(
        self, pending: _Pending, msg_type: Any, content: dict
    ) -> None:
        """Parse the user_expressions JSON out of an execute_reply and reply."""
        empty: dict = {"variables": []}
        if msg_type != "execute_reply" or content.get("status") != "ok":
            self.conn.send_result(pending.reply_id, empty)
            return
        ue = (content.get("user_expressions") or {}).get("__jove__") or {}
        if ue.get("status") != "ok":
            self.conn.send_result(pending.reply_id, empty)
            return
        text = (ue.get("data") or {}).get("text/plain") or ""
        if not isinstance(text, str):
            self.conn.send_result(pending.reply_id, empty)
            return
        # IPython renders a str user_expression as its repr (quoted and
        # escaped), so `text` is a Python string literal wrapping the JSON.
        # Accept both the raw JSON and the repr-wrapped form.
        try:
            raw = json.loads(text)
        except Exception:
            try:
                unwrapped = ast.literal_eval(text)
            except Exception:
                self.conn.send_result(pending.reply_id, empty)
                return
            if isinstance(unwrapped, str):
                try:
                    raw = json.loads(unwrapped)
                except Exception:
                    self.conn.send_result(pending.reply_id, empty)
                    return
            else:
                raw = unwrapped
        if not isinstance(raw, list):
            self.conn.send_result(pending.reply_id, empty)
            return
        variables = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            variables.append(
                {
                    "name": item.get("name"),
                    "type": item.get("type"),
                    "value": item.get("value"),
                    "size": item.get("size"),
                }
            )
        self.conn.send_result(pending.reply_id, {"variables": variables})

    def _submit_shell(
        self,
        kind: str,
        reply_id: int,
        send: Callable[[Any], str],
        cell: Optional[str] = None,
    ) -> Any:
        """Send a shell-channel request and register it atomically.

        The pending insert and the kernel-liveness check share ``self._lock``
        with the kernel-death path (``_check_alive`` nils the client *before*
        ``_fail_pending`` clears the table), so a kernel dying during
        submission can never yield two responses for ``reply_id``: either the
        liveness check raises before anything is registered, or the pending
        entry is visible to ``_fail_pending`` and the error comes from there
        alone.
        """
        with self._lock:
            client = self.kernel.require_client()
            with self._shell_lock:
                msg_id = send(client)
            self.pending[msg_id] = _Pending(kind, reply_id, cell)
        return DEFERRED

    def restart(self) -> dict:
        km = self.kernel.require_km()
        self._fail_pending("kernel_not_running", "kernel is restarting")
        self.conn.send_event("kernel_status", {"status": "restarting"})
        self._restarting = True
        try:
            km.restart_kernel()
        finally:
            self._restarting = False
        if not self._probe_ready():
            self.kernel.shutdown()
            raise KernelError(
                "kernel_start_failed",
                "kernel did not become ready within 25s after restart",
            )
        return {}

    def stop(self) -> None:
        self._stop.set()

    def shutdown_kernel(self) -> None:
        """Best-effort kernel teardown used on exit paths."""
        self._shutting_down = True
        self.kernel.shutdown()

    def poll_forever(self) -> None:
        """Worker loop: drain iopub + shell, watch for kernel death."""
        while not self._stop.is_set():
            client = self.kernel.client
            if client is None:
                self._stop.wait(0.1)
                continue
            progress = False
            try:
                msg = client.get_iopub_msg(timeout=0.1)
            except Exception:
                msg = None
                if self._stop.is_set() or self.kernel.client is None:
                    continue
                self._stop.wait(0.05)
            if msg is not None:
                try:
                    self._handle_iopub(msg)
                except BaseException:
                    traceback.print_exc()
                progress = True
            try:
                with self._shell_lock:
                    msg = client.get_shell_msg(timeout=0)
            except Exception:
                msg = None
            if msg is not None:
                try:
                    self._handle_shell(msg)
                except BaseException:
                    traceback.print_exc()
                progress = True
            self._check_alive()
            if not progress:
                self._stop.wait(0.05)

    def _handle_iopub(self, msg: dict) -> None:
        msg_type = msg.get("msg_type")
        content = msg.get("content") or {}
        if msg_type == "iopub_welcome":
            # Kernel-side XPUB processed our subscription; iopub is live now.
            self._iopub_live.set()
            return
        if msg_type == "status":
            state = content.get("execution_state")
            if state in ("starting", "busy", "idle"):
                self.conn.send_event("kernel_status", {"status": state})
            return
        parent = (msg.get("parent_header") or {}).get("msg_id")
        cell = None
        with self._lock:
            pending = self.pending.get(parent)
            if pending is not None and pending.kind == "execute":
                cell = pending.cell
            else:
                entry = self._recent.get(parent)
                if entry is not None:
                    entry_cell, expiry = entry
                    if time.monotonic() <= expiry:
                        cell = entry_cell
                    else:
                        del self._recent[parent]
        if cell is None:
            return
        if msg_type == "stream":
            self.conn.send_event(
                "output",
                {
                    "cell": cell,
                    "kind": "stream",
                    "name": content.get("name", "stdout"),
                    "mime": {"text/plain": content.get("text", "")},
                },
            )
        elif msg_type in ("display_data", "execute_result"):
            out = {
                "cell": cell,
                "kind": msg_type,
                "mime": dict(content.get("data") or {}),
            }
            # execute_result carries the cell's execution_count; display_data
            # doesn't. Forwarded here so the Lua side can render `Out [n]`
            # labels without a second iopub round-trip.
            if msg_type == "execute_result" and "execution_count" in content:
                out["execution_count"] = content["execution_count"]
            self.conn.send_event("output", out)
        elif msg_type == "error":
            self._emit_error_output(
                cell,
                content.get("ename", ""),
                content.get("evalue", ""),
                [str(line) for line in content.get("traceback") or []],
            )

    def _emit_error_output(
        self, cell: str, ename: str, evalue: str, tb_lines: list
    ) -> None:
        """Emit an error-kind output event (raw ANSI traceback preserved)."""
        self.conn.send_event(
            "output",
            {
                "cell": cell,
                "kind": "error",
                "ename": ename,
                "evalue": evalue,
                "traceback": tb_lines,
                "mime": {
                    "text/plain": "\n".join(tb_lines)
                    or (f"{ename}: {evalue}".strip(": ") or "interrupted")
                },
            },
        )

    def _handle_shell(self, msg: dict) -> None:
        parent = (msg.get("parent_header") or {}).get("msg_id")
        with self._lock:
            pending = self.pending.pop(parent, None)
        if pending is None:
            return
        # Keep the answered execute's msg_id resolvable for late iopub
        # messages (see LATE_IOPUB_GRACE) before dropping the pending entry.
        if pending.kind == "execute" and pending.cell is not None:
            now = time.monotonic()
            with self._lock:
                self._recent[parent] = (pending.cell, now + LATE_IOPUB_GRACE)
                for msg_id in [
                    m for m, (_, expiry) in self._recent.items() if expiry < now
                ]:
                    del self._recent[msg_id]
        if pending.kind == "ready_probe":
            # Kernel answered the readiness probe: it is up and our iopub
            # subscription is registered — announce idle.
            self.conn.send_event("kernel_status", {"status": "idle"})
            self._ready.set()
            return
        msg_type = msg.get("msg_type")
        content = msg.get("content") or {}
        # Variable probes return user_expressions rather than an execution status.
        if pending.kind == "variables":
            self._finish_variables(pending, msg_type, content)
            return
        if msg_type == "execute_reply":
            if content.get("status") == "ok":
                result = {"status": "ok"}
                if "execution_count" in content:
                    result["execution_count"] = content["execution_count"]
                self.conn.send_result(pending.reply_id, result)
            else:
                status = content.get("status", "error")
                ename = content.get("ename", "")
                evalue = content.get("evalue", "")
                tb_lines = [str(line) for line in content.get("traceback") or []]
                if status in ("abort", "aborted") and pending.cell is not None:
                    # An interrupt with queued execute requests aborts them:
                    # the reply carries no ename/evalue/traceback and *no*
                    # iopub error message is published. An error result
                    # implies an error-kind output event, so synthesize one
                    # here.
                    self._emit_error_output(pending.cell, ename, evalue, tb_lines)
                err_result = {
                    "status": "error",
                    "ename": ename,
                    "evalue": evalue,
                }
                if "execution_count" in content:
                    err_result["execution_count"] = content["execution_count"]
                self.conn.send_result(pending.reply_id, err_result)
        elif msg_type == "complete_reply":
            self.conn.send_result(
                pending.reply_id, {"matches": list(content.get("matches") or [])}
            )
        elif msg_type == "inspect_reply":
            self.conn.send_result(
                pending.reply_id, {"mime": dict(content.get("data") or {})}
            )
        else:
            self.conn.send_error(
                pending.reply_id,
                "internal_error",
                f"unexpected shell message: {msg_type!r}",
            )

    def _check_alive(self) -> None:
        km = self.kernel.km
        if km is None or self._restarting or self._shutting_down:
            return
        try:
            alive = bool(km.is_alive())
        except Exception:
            return
        if not alive:
            self.conn.send_event("kernel_status", {"status": "dead"})
            self.kernel.mark_dead()
            self._fail_pending("kernel_not_running", "kernel died")

    def _probe_ready(self, timeout: float = 25.0) -> bool:
        """Wait until the kernel is reachable and iopub is dependable.

        Two signals, both best-effort with fallback timeouts so exotic
        kernels without an ``iopub_welcome`` still work:

        - the ``kernel_info`` reply on the shell channel (DEALER/ROUTER
          queues it, so it is never dropped);
        - ``iopub_welcome`` on iopub, sent by ipykernel >= 7 exactly when the
          kernel's XPUB socket processes our subscription. Everything
          published on iopub before that point may be dropped (classic PUB
          semantics), which is why the bridge waits for it before answering
          ``start_kernel``.

        Returns False on timeout so callers can answer ``kernel_start_failed``
        instead of reporting success with a stuck "starting" status. The
        total wait is bounded by ``timeout`` (the two waits share a deadline)
        so it stays inside the parent's request timeout.
        """
        client = self.kernel.client
        if client is None:
            return False
        self._ready.clear()
        self._iopub_live.clear()
        try:
            with self._shell_lock:
                msg_id = client.kernel_info()
        except Exception:
            self._ready.set()
            self._iopub_live.set()
            return True
        with self._lock:
            self.pending[msg_id] = _Pending("ready_probe", None)
        deadline = time.monotonic() + timeout
        # Welcome first: it must be processed by the kernel before any later
        # iopub (including the probe's own busy/idle) is guaranteed through.
        if not self._iopub_live.wait(timeout):
            self._iopub_live.set()  # no welcome support; proceed optimistically
        remaining = deadline - time.monotonic()
        if not self._ready.wait(max(remaining, 0.0)):
            with self._lock:
                self.pending.pop(msg_id, None)
            self._ready.set()
            return False
        return True

    def _fail_pending(self, code: str, message: str) -> None:
        with self._lock:
            items = list(self.pending.values())
            self.pending.clear()
        for pending in items:
            if pending.reply_id is None:
                continue  # internal probe, no reply to fail
            self.conn.send_error(pending.reply_id, code, message)
