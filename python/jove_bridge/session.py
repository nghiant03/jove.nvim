"""Request dispatch and routing."""

from __future__ import annotations

import ast
import json
import threading
import time
import traceback
from typing import Any, Callable, Optional

from .kernel import KernelController, KernelError
from .languages import DisplayProbe, lookup

# Sentinel returned by dispatch(): the reply will be sent asynchronously from
# the poll thread once the kernel answers, not by the stdin loop.
DEFERRED = object()

# Seconds after an execute_reply during which late iopub outputs are still
# routed to the cell that executed. The Lua client keeps its side of the
# route alive for the same window.
LATE_IOPUB_GRACE = 10.0


class _Pending:
    """An in-flight shell request awaiting its reply."""

    __slots__ = ("kind", "reply_id", "cell")

    def __init__(
        self, kind: str, reply_id: Optional[int], cell: Optional[str] = None
    ) -> None:
        self.kind = kind
        self.reply_id = reply_id
        self.cell = cell


VARIABLES_TIMEOUT = 12.0
MAX_VARIABLE_BYTES = 1024 * 1024
MAX_VARIABLE_ROWS = 4096
MAX_VARIABLE_REQUESTS = 8


def _bounded_text(text: str) -> None:
    if len(text) > MAX_VARIABLE_BYTES or len(text.encode("utf-8")) > MAX_VARIABLE_BYTES:
        raise ValueError("variable snapshot is too large")


def _variable_rows(payload: Any) -> list[dict]:
    """Normalize a JSON MIME value (array or serialized array) for the wire."""
    if isinstance(payload, str):
        _bounded_text(payload)
        try:
            payload = json.loads(payload)
        except (ValueError, RecursionError) as exc:
            raise ValueError("invalid variable snapshot JSON") from exc
    if not isinstance(payload, list):
        raise ValueError("expected an array of variable rows")
    if len(payload) > MAX_VARIABLE_ROWS:
        raise ValueError("too many variable rows")
    rows = []
    size = 2
    for item in payload:
        if not isinstance(item, dict) or not all(
            isinstance(item.get(k), str) for k in ("name", "type", "value")
        ):
            raise ValueError("invalid variable row")
        length = item.get("size")
        if length is not None and (
            type(length) is not int or not 0 <= length <= 2**63 - 1
        ):
            raise ValueError("invalid variable size")
        row = {
            "name": item["name"],
            "type": item["type"],
            "value": item["value"],
            "size": length,
        }
        if any(len(row[k]) > MAX_VARIABLE_BYTES for k in ("name", "type", "value")):
            raise ValueError("variable snapshot is too large")
        size += len(json.dumps(row)) + 1
        if size > MAX_VARIABLE_BYTES:
            raise ValueError("variable snapshot is too large")
        rows.append(row)
    return rows


def _python_rows(content: dict) -> list[dict]:
    expressions = content.get("user_expressions")
    expr = expressions.get("__jove__") if isinstance(expressions, dict) else None
    if not isinstance(expr, dict) or expr.get("status") != "ok":
        raise ValueError("kernel did not return a successful variable expression")
    data = expr.get("data")
    text = data.get("text/plain") if isinstance(data, dict) else None
    if not isinstance(text, str):
        raise ValueError("missing text/plain variable expression")
    _bounded_text(text)
    if text.lstrip().startswith(("'", '"')):
        try:
            text = ast.literal_eval(text)
        except (SyntaxError, ValueError, RecursionError) as exc:
            raise ValueError("invalid quoted variable expression") from exc
        if not isinstance(text, str):
            raise ValueError("invalid quoted variable expression")
    return _variable_rows(text)


class _Variables(_Pending):
    """Collect the shell reply and IOPub messages for one inspector request."""

    __slots__ = ("deadline", "idle", "replied", "rows", "error")

    def __init__(self, kind: str, reply_id: int) -> None:
        super().__init__(kind, reply_id)
        self.deadline = time.monotonic() + VARIABLES_TIMEOUT
        self.replied = self.idle = False
        self.rows: list[dict] | None = None
        self.error: str | None = None

    def receive(self, shell: bool, msg_type: str, content: dict) -> bool:
        """Display probes need both the shell reply and IOPub idle, in either order."""
        try:
            if shell:
                self.replied = True
                if msg_type != "execute_reply" or content.get("status") != "ok":
                    raise ValueError("variable probe execution failed")
                if self.kind == "variables":
                    self.rows = _python_rows(content)
            elif self.kind == "variables_display":
                if msg_type == "status" and content.get("execution_state") == "idle":
                    self.idle = True
                elif msg_type == "error":
                    raise ValueError("variable probe execution failed")
                elif (
                    msg_type in ("display_data", "execute_result")
                    and self.error is None
                ):
                    data = content.get("data")
                    if isinstance(data, dict) and "application/json" in data:
                        if self.rows is not None:
                            raise ValueError("duplicate variable snapshot")
                        self.rows = _variable_rows(data["application/json"])
        except ValueError as exc:
            self.rows = None
            self.error = str(exc)
        return self.replied and (self.kind == "variables" or self.idle)

    def respond(self, conn: Any) -> None:
        if self.error is not None or self.rows is None:
            conn.send_error(
                self.reply_id,
                "variables_failed",
                self.error or "missing application/json variable snapshot",
            )
        else:
            conn.send_result(self.reply_id, {"variables": self.rows})


class BridgeSession:
    """Bridges protocol requests onto one Jupyter kernel."""

    def __init__(self, conn: Any) -> None:
        self.conn = conn
        self.kernel = KernelController()
        self.pending: dict = {}
        # msg_id -> (cell, expiry): routes iopub events that arrive after
        # their execute_reply (see LATE_IOPUB_GRACE).
        self._recent: dict = {}
        self._lock = threading.Lock()
        self._shell_lock = threading.Lock()
        self._stop = threading.Event()
        self._restarting = False
        self._shutting_down = False
        self._kernel_info: tuple[str | None, str | None] = (None, None)
        self._ready = threading.Event()
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
        self.kernel.require_kernelspec(kernelspec)
        self._fail_pending("kernel_not_running", "kernel was replaced")
        self.kernel.start(kernelspec)
        self.conn.send_event("kernel_status", {"status": "starting"})
        if not self._probe_ready():
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
        """Snapshot user-namespace variables."""
        self.kernel.require_client()
        language, implementation = self._kernel_info
        if not language:
            language = self._kernel_language()
            implementation = None
        probe = lookup(language, implementation)
        if probe is None:
            return {"variables": [], "unsupported": language or "unknown"}
        if isinstance(probe, DisplayProbe):
            return self._submit_shell(
                "variables_display",
                reply_id,
                lambda client: client.execute(
                    probe.code, silent=True, store_history=False, allow_stdin=False
                ),
            )
        return self._submit_shell(
            "variables",
            reply_id,
            lambda client: client.execute(
                probe.install,
                silent=True,
                store_history=False,
                user_expressions={"__jove__": probe.query},
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

    def _route_variables(
        self, parent: str, msg_type: str, content: dict, *, shell: bool
    ) -> bool:
        """Return True for probe messages so they aren't routed to notebook cells."""
        with self._lock:
            pending = self.pending.get(parent)
            if not isinstance(pending, _Variables):
                return False
            if not pending.receive(shell, msg_type, content):
                return True
            del self.pending[parent]
        pending.respond(self.conn)
        return True

    def _expire_variables(self) -> None:
        now = time.monotonic()
        with self._lock:
            expired = [
                key
                for key, p in self.pending.items()
                if isinstance(p, _Variables) and p.deadline <= now
            ]
            requests = [self.pending.pop(key) for key in expired]
        for pending in requests:
            self.conn.send_error(
                pending.reply_id, "variables_timeout", "variable probe timed out"
            )

    def _submit_shell(
        self,
        kind: str,
        reply_id: int,
        send: Callable[[Any], str],
        cell: Optional[str] = None,
    ) -> Any:
        """Send a shell-channel request and register it atomically."""
        with self._lock:
            client = self.kernel.require_client()
            if kind in ("variables", "variables_display"):
                if (
                    sum(isinstance(p, _Variables) for p in self.pending.values())
                    >= MAX_VARIABLE_REQUESTS
                ):
                    raise KernelError(
                        "variables_busy", "too many pending variable requests"
                    )
                pending = _Variables(kind, reply_id)
            else:
                pending = _Pending(kind, reply_id, cell)
            with self._shell_lock:
                msg_id = send(client)
            self.pending[msg_id] = pending
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
        self._fail_pending("kernel_not_running", "kernel is shutting down")
        self.kernel.shutdown()

    def poll_forever(self) -> None:
        """Worker loop: drain iopub + shell, watch for kernel death."""
        while not self._stop.is_set():
            self._expire_variables()
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
            self._iopub_live.set()
            return
        parent = (msg.get("parent_header") or {}).get("msg_id")
        if self._route_variables(parent, msg_type, content, shell=False):
            return
        if msg_type == "status":
            self._iopub_live.set()
            state = content.get("execution_state")
            if state in ("starting", "busy", "idle"):
                self.conn.send_event("kernel_status", {"status": state})
            return
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
        msg_type = msg.get("msg_type")
        content = msg.get("content") or {}
        if self._route_variables(parent, msg_type, content, shell=True):
            return
        with self._lock:
            pending = self.pending.pop(parent, None)
            if (
                pending is not None
                and pending.kind == "ready_probe"
                and msg_type == "kernel_info_reply"
            ):
                info = content.get("language_info")
                language = info.get("name") if isinstance(info, dict) else None
                impl = content.get("implementation")
                self._kernel_info = (
                    language.strip() if isinstance(language, str) else None,
                    impl.strip() if isinstance(impl, str) else None,
                )
        if pending is None:
            return
        if pending.kind == "execute" and pending.cell is not None:
            # The reply arrived; keep routing iopub events to this cell for the
            # grace window, since outputs can trail the reply.
            now = time.monotonic()
            with self._lock:
                self._recent[parent] = (pending.cell, now + LATE_IOPUB_GRACE)
                for msg_id in [
                    m for m, (_, expiry) in self._recent.items() if expiry < now
                ]:
                    del self._recent[msg_id]
        if pending.kind == "ready_probe":
            self.conn.send_event("kernel_status", {"status": "idle"})
            self._ready.set()
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
        """Wait until the kernel is reachable and iopub is dependable."""
        client = self.kernel.client
        if client is None:
            return False
        self._ready.clear()
        self._iopub_live.clear()
        try:
            with self._lock:
                with self._shell_lock:
                    msg_id = client.kernel_info()
                self.pending[msg_id] = _Pending("ready_probe", None)
        except Exception:
            self._ready.set()
            self._iopub_live.set()
            return True
        deadline = time.monotonic() + timeout
        if not self._iopub_live.wait(timeout):
            self._iopub_live.set()
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
            self._kernel_info = (None, None)
            self._recent.clear()
        for pending in items:
            if pending.reply_id is None:
                continue
            self.conn.send_error(pending.reply_id, code, message)
