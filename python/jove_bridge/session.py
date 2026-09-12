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

import threading
import time
import traceback
from typing import Any, Callable, Optional

from .kernel import KernelController, KernelError

# Sentinel returned by dispatch() when the response will be sent later by the
# poll thread (e.g. execute waits for the shell-channel execute_reply).
DEFERRED = object()


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

    # -- request dispatch ---------------------------------------------------

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

    # -- methods ------------------------------------------------------------

    def start_kernel(self, kernelspec: str) -> dict:
        # Validate before touching anything: a typo'd spec must not kill the
        # running kernel's in-flight requests (kernelspec_not_found leaves
        # the current kernel untouched).
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
            lambda client: client.inspect(
                code, cursor_pos, detail_level=detail_level
            ),
        )

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

    # -- poll thread ----------------------------------------------------------

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

    # -- message handlers -------------------------------------------------------

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
        with self._lock:
            pending = self.pending.get(parent)
        if pending is None or pending.kind != "execute":
            return
        cell = pending.cell
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
            self.conn.send_event(
                "output",
                {
                    "cell": cell,
                    "kind": msg_type,
                    "mime": dict(content.get("data") or {}),
                },
            )
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
        if pending.kind == "ready_probe":
            # Kernel answered the readiness probe: it is up and our iopub
            # subscription is registered — announce idle.
            self.conn.send_event("kernel_status", {"status": "idle"})
            self._ready.set()
            return
        msg_type = msg.get("msg_type")
        content = msg.get("content") or {}
        if msg_type == "execute_reply":
            if content.get("status") == "ok":
                self.conn.send_result(pending.reply_id, {"status": "ok"})
            else:
                status = content.get("status", "error")
                ename = content.get("ename", "")
                evalue = content.get("evalue", "")
                tb_lines = [str(line) for line in content.get("traceback") or []]
                if status in ("abort", "aborted"):
                    # An interrupt with queued execute requests aborts them:
                    # the reply carries no ename/evalue/traceback and *no*
                    # iopub error message is published. PROTOCOL.md makes an
                    # error result imply an error-kind output event, so
                    # synthesize one here.
                    self._emit_error_output(pending.cell, ename, evalue, tb_lines)
                self.conn.send_result(
                    pending.reply_id,
                    {"status": "error", "ename": ename, "evalue": evalue},
                )
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

    # -- helpers ---------------------------------------------------------------

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
            # Kernel never confirmed readiness.
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
