"""Bridge protocol conformance tests.

Launches ``python -m jove_bridge`` as a subprocess and speaks the JSON-lines
protocol directly — no Neovim involved. Kernel tests exercise a real
``python3`` ipykernel. Generous timeouts: kernel startup can take ~10s in CI.
"""

from __future__ import annotations

import json
import subprocess
import sys
import threading
import time

import pytest

from jove_bridge.kernel import KernelError
from jove_bridge.session import DEFERRED as DEFERRED_SENTINEL
from jove_bridge.session import BridgeSession

REQ_TIMEOUT = 60.0
KERNEL_TIMEOUT = 120.0


class BridgeProcess:
    """A sidecar subprocess plus helpers for speaking the protocol."""

    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "jove_bridge"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.messages: list = []
        self._cond = threading.Condition()
        self._eof = False
        self._stderr: list[str] = []
        self._next_id = 0
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            with self._cond:
                self.messages.append(msg)
                self._cond.notify_all()
        with self._cond:
            self._eof = True
            self._cond.notify_all()

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self._stderr.append(line)

    def cursor(self) -> int:
        """Snapshot of the message count; use as ``since`` in waiters."""
        return len(self.messages)

    def send(self, obj) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def send_line(self, text: str) -> None:
        """Send a raw (possibly malformed) line."""
        assert self.proc.stdin is not None
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def wait(self, predicate, timeout=REQ_TIMEOUT, since=0):
        """Return the first message matching ``predicate`` from ``since``."""
        deadline = time.monotonic() + timeout
        with self._cond:
            i = since
            while True:
                while i < len(self.messages):
                    msg = self.messages[i]
                    i += 1
                    if predicate(msg):
                        return msg
                if self._eof:
                    raise AssertionError(
                        "bridge exited before the expected message; "
                        "stderr tail:\n" + "".join(self._stderr[-30:])
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(
                        "timed out waiting for a message; messages since "
                        f"{since}:\n"
                        + json.dumps(self.messages[since:], indent=1)[:4000]
                    )
                self._cond.wait(remaining)

    def wait_ready(self, timeout=REQ_TIMEOUT) -> dict:
        msg = self.wait(lambda m: m.get("event") == "ready", timeout)
        assert self.messages[0] is msg, "ready must be the first message"
        return msg

    def send_request(self, method: str, params=None) -> int:
        self._next_id += 1
        self.send({"id": self._next_id, "method": method, "params": params or {}})
        return self._next_id

    def wait_response(self, reply_id, timeout=REQ_TIMEOUT, since=0) -> dict:
        return self.wait(
            lambda m: m.get("id") == reply_id and ("result" in m or "error" in m),
            timeout,
            since,
        )

    def request(self, method: str, params=None, timeout=REQ_TIMEOUT) -> dict:
        since = self.cursor()
        reply_id = self.send_request(method, params)
        return self.wait_response(reply_id, timeout, since)

    def wait_event(self, event, timeout=REQ_TIMEOUT, since=0, pred=None) -> dict:
        def check(msg):
            if msg.get("event") != event:
                return False
            return pred is None or pred(msg.get("params") or {})

        return self.wait(check, timeout, since)

    def wait_status(self, *states, timeout=KERNEL_TIMEOUT, since=0) -> dict:
        return self.wait_event(
            "kernel_status",
            timeout,
            since,
            pred=lambda p: p.get("status") in states,
        )

    def statuses_since(self, since: int) -> list:
        return [
            m["params"]["status"]
            for m in self.messages[since:]
            if m.get("event") == "kernel_status"
        ]

    def outputs_since(self, since: int) -> list:
        return [
            m["params"] for m in self.messages[since:] if m.get("event") == "output"
        ]

    def start_kernel(self, name="python3", timeout=KERNEL_TIMEOUT) -> dict:
        since = self.cursor()
        msg = self.request("start_kernel", {"kernelspec": name}, timeout)
        assert "result" in msg, f"start_kernel failed: {msg}"
        self.wait_status("idle", since=since, timeout=timeout)
        return msg

    def close(self) -> None:
        try:
            if self.proc.poll() is None and self.proc.stdin is not None:
                self.proc.stdin.close()
                self.proc.wait(timeout=15)
        except Exception:
            pass
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()


@pytest.fixture
def bridge():
    proc = BridgeProcess()
    proc.wait_ready()
    yield proc
    proc.close()


@pytest.fixture
def kernel(bridge):
    """A bridge with a running python3 kernel."""
    bridge.start_kernel("python3")
    return bridge




def test_ready_and_list_kernelspecs(bridge):
    ready = bridge.messages[0]
    assert ready["event"] == "ready"
    assert ready["params"]["protocol"] == 1
    assert isinstance(ready["params"]["version"], str)
    assert ready["params"]["version"]

    msg = bridge.request("list_kernelspecs")
    specs = msg["result"]["kernelspecs"]
    assert "python3" in specs
    assert specs["python3"]["display_name"]
    assert specs["python3"]["language"]


def test_requests_before_kernel_start(bridge):
    for method, params in (
        ("execute", {"code": "1+1", "cell": "c"}),
        ("interrupt", {}),
        ("restart", {}),
    ):
        msg = bridge.request(method, params)
        assert msg["error"]["code"] == "kernel_not_running", msg


def test_unknown_method(bridge):
    msg = bridge.request("definitely_not_a_method", {})
    assert msg["error"]["code"] == "unknown_method"


def test_invalid_params(bridge):
    msg = bridge.request("start_kernel", {})
    assert msg["error"]["code"] == "invalid_params"
    msg = bridge.request("execute", {"code": "1"})  # missing cell
    assert msg["error"]["code"] == "invalid_params"


def test_protocol_error_then_recover(bridge):
    bridge.send_line("this is not json {{{")
    ev = bridge.wait_event("protocol_error", since=0)
    assert isinstance(ev["params"], dict) and ev["params"]
    msg = bridge.request("list_kernelspecs")
    assert "python3" in msg["result"]["kernelspecs"]


def test_start_kernel_status_sequence(bridge):
    since = bridge.cursor()
    bridge.start_kernel("python3")
    statuses = bridge.statuses_since(since)
    assert statuses[0] == "starting"
    assert "idle" in statuses




def test_execute_stream(kernel):
    since = kernel.cursor()
    msg = kernel.request("execute", {"code": "print(1+1)", "cell": "cell-a1"})
    assert msg["result"].get("status") == "ok"
    ev = kernel.wait_event(
        "output", since=since, pred=lambda p: p.get("cell") == "cell-a1"
    )
    params = ev["params"]
    assert params["kind"] == "stream"
    assert params["name"] == "stdout"
    assert params["mime"]["text/plain"] == "2\n"


def test_execute_error(kernel):
    since = kernel.cursor()
    msg = kernel.request("execute", {"code": "raise ValueError('boom')", "cell": "e1"})
    result = msg["result"]
    assert result["status"] == "error"
    assert result["ename"] == "ValueError"
    assert "boom" in result["evalue"]

    ev = kernel.wait_event(
        "output",
        since=since,
        pred=lambda p: p.get("cell") == "e1" and p.get("kind") == "error",
    )
    params = ev["params"]
    assert params["ename"] == "ValueError"
    assert params["evalue"] == result["evalue"]
    assert params["traceback"], "raw ANSI traceback lines must be present"
    assert any("ValueError" in line for line in params["traceback"])
    assert params["mime"]["text/plain"]


def test_execute_result_mime_bundle(kernel):
    since = kernel.cursor()
    msg = kernel.request("execute", {"code": "'hello'", "cell": "r1"})
    assert msg["result"].get("status") == "ok"
    ev = kernel.wait_event(
        "output",
        since=since,
        pred=lambda p: p.get("cell") == "r1" and p.get("kind") == "execute_result",
    )
    params = ev["params"]
    assert params["mime"]["text/plain"] == "'hello'"


def test_execute_display_data(kernel):
    since = kernel.cursor()
    code = "from IPython.display import display, HTML\ndisplay(HTML('<b>jove</b>'))"
    msg = kernel.request("execute", {"code": code, "cell": "d1"})
    assert msg["result"].get("status") == "ok"
    ev = kernel.wait_event(
        "output",
        since=since,
        pred=lambda p: p.get("cell") == "d1" and p.get("kind") == "display_data",
    )
    params = ev["params"]
    assert params["mime"]["text/html"] == "<b>jove</b>"


def test_overlapping_executes(kernel):
    since = kernel.cursor()
    rid1 = kernel.send_request(
        "execute",
        {"code": "import time\ntime.sleep(0.7)\nprint('first-done')", "cell": "c1"},
    )
    rid2 = kernel.send_request("execute", {"code": "print('second-done')", "cell": "c2"})
    r1 = kernel.wait_response(rid1, since=since)
    r2 = kernel.wait_response(rid2, since=since)
    assert r1["result"].get("status") == "ok"
    assert r2["result"].get("status") == "ok"

    # A cell's final iopub output can be emitted after its execute_reply
    # (ZMQ gives no cross-socket ordering; the bridge re-tags late outputs to
    # the originating cell). Wait for the stream events instead of
    # snapshotting whatever has arrived right after the replies.
    ev1 = kernel.wait_event(
        "output",
        since=since,
        pred=lambda p: p.get("cell") == "c1" and p.get("kind") == "stream",
    )
    ev2 = kernel.wait_event(
        "output",
        since=since,
        pred=lambda p: p.get("cell") == "c2" and p.get("kind") == "stream",
    )
    assert "first-done" in ev1["params"]["mime"]["text/plain"]
    assert "second-done" in ev2["params"]["mime"]["text/plain"]


def _interruptable_sleep():
    """Sleep code that provably enters the cell before sleeping.

    ipykernel installs its SIGINT handler only around handler execution
    (SIG_IGN otherwise, set at startup). Interrupting right after seeing the
    "busy" status races the pre-handler window, and on loaded runners
    (macOS CI) the SIGINT can be swallowed, letting the sleep run to
    completion. The cell prints "started" from inside the handler, so waiting
    for that output proves the kernel is executing user code and the
    interrupt must land.
    """
    return "print('started'); import time; time.sleep(30)"


def test_interrupt(kernel):
    since = kernel.cursor()
    rid = kernel.send_request(
        "execute", {"code": _interruptable_sleep(), "cell": "slow"}
    )
    kernel.wait_event(
        "output", since=since, pred=lambda p: p.get("cell") == "slow"
    )
    msg = kernel.request("interrupt")
    assert msg["result"] == {}

    reply = kernel.wait_response(rid, since=since, timeout=60)
    result = reply["result"]
    assert result["status"] == "error"
    assert result["ename"] == "KeyboardInterrupt"

    kernel.wait_status("idle", since=since)
    msg = kernel.request("execute", {"code": "print('alive')", "cell": "after"})
    assert msg["result"].get("status") == "ok"
    ev = kernel.wait_event(
        "output", since=since, pred=lambda p: p.get("cell") == "after"
    )
    assert ev["params"]["mime"]["text/plain"] == "alive\n"


def test_interrupt_with_queued_execute_error_implies_output(kernel):
    """Interrupting with a queued execute: the queued request is aborted.

    ipykernel answers the queued request with ``execute_reply
    status="aborted"`` and publishes *no* iopub error for it. The contract
    (an error result implies an error-kind output event) must still hold,
    so the bridge synthesizes the missing output event.
    """
    since = kernel.cursor()
    rid_sleep = kernel.send_request(
        "execute", {"code": _interruptable_sleep(), "cell": "sleep"}
    )
    kernel.wait_event(
        "output", since=since, pred=lambda p: p.get("cell") == "sleep"
    )
    rid_quick = kernel.send_request(
        "execute", {"code": "print('quick-done')", "cell": "quick"}
    )
    msg = kernel.request("interrupt")
    assert msg["result"] == {}

    sleep_reply = kernel.wait_response(rid_sleep, since=since, timeout=60)
    assert sleep_reply["result"]["status"] == "error"
    assert sleep_reply["result"]["ename"] == "KeyboardInterrupt"
    quick_reply = kernel.wait_response(rid_quick, since=since, timeout=60)
    assert quick_reply["result"]["status"] == "error"

    # Exactly one error-kind output per error result: the sleeper's arrives
    # via iopub, the aborted request's is synthesized by the bridge. The
    # sleeper's iopub error can be emitted after its execute_reply (no
    # cross-socket ZMQ ordering), but it always precedes the idle status on
    # the wire, and the bridge emits iopub events in wire order — so wait
    # for idle before counting.
    kernel.wait_status("idle", since=since)
    outputs = kernel.outputs_since(since)
    for cell in ("sleep", "quick"):
        errs = [
            o
            for o in outputs
            if o.get("cell") == cell and o.get("kind") == "error"
        ]
        assert len(errs) == 1, f"expected exactly one error output for {cell!r}"
        assert errs[0]["mime"]["text/plain"]

    msg = kernel.request("execute", {"code": "print('alive')", "cell": "after"})
    assert msg["result"].get("status") == "ok"


def test_restart(bridge):
    bridge.start_kernel("python3")
    msg = bridge.request("execute", {"code": "jove_secret = 42", "cell": "s1"})
    assert msg["result"].get("status") == "ok"

    since = bridge.cursor()
    msg = bridge.request("restart")
    assert msg["result"] == {}
    statuses = bridge.statuses_since(since)
    assert "restarting" in statuses
    bridge.wait_status("idle", since=since)

    # Fresh execution context: the pre-restart variable is gone.
    msg = bridge.request("execute", {"code": "print(jove_secret)", "cell": "s2"})
    result = msg["result"]
    assert result["status"] == "error"
    assert result["ename"] == "NameError"




def test_shutdown_exits_zero(bridge):
    bridge.start_kernel("python3")
    msg = bridge.request("shutdown")
    assert msg["result"] == {}
    rc = bridge.proc.wait(timeout=10)
    assert rc == 0


def test_stdin_eof_exits_zero(bridge):
    bridge.start_kernel("python3")
    bridge.proc.stdin.close()
    rc = bridge.proc.wait(timeout=20)
    assert rc == 0


# Use in-process fakes to reproduce kernel death during request submission
# deterministically; subprocess timing cannot reliably hit that window.


class _FakeConn:
    """Records everything the session would write to the wire."""

    def __init__(self):
        self.msgs = []

    def send_result(self, reply_id, result):
        self.msgs.append({"id": reply_id, "result": result})

    def send_error(self, reply_id, code, message):
        self.msgs.append({"id": reply_id, "error": {"code": code, "message": message}})

    def send_event(self, event, params):
        self.msgs.append({"event": event, "params": params})

    def responses(self, reply_id):
        return [m for m in self.msgs if m.get("id") == reply_id]


class _FakeKM:
    def is_alive(self):
        return False


class _FakeClient:
    def __init__(self, kernel):
        self._kernel = kernel

    def execute(self, code):
        # Simulate the kernel dying mid-send: mark_dead nils the client.
        self._kernel.client = None
        return "msg-1"


class _FakeKernel:
    """Duck-typed KernelController (only what BridgeSession touches)."""

    def __init__(self):
        self.km = _FakeKM()
        self.client = _FakeClient(self)

    def require_client(self):
        if self.client is None:
            raise KernelError("kernel_not_running", "start a kernel first")
        return self.client

    def mark_dead(self):
        self.client = None


def test_single_response_when_kernel_dies_during_execute():
    """Death mid-send: the pending entry is registered, so the death path
    (_check_alive → mark_dead → _fail_pending) must be the ONLY responder."""
    conn = _FakeConn()
    session = BridgeSession(conn)
    session.kernel = _FakeKernel()  # type: ignore[assignment]

    assert session.execute("1+1", "cell-a", 42) is DEFERRED_SENTINEL
    session._check_alive()  # drive the poll-thread death path

    responses = conn.responses(42)
    assert len(responses) == 1, conn.msgs
    assert responses[0]["error"]["code"] == "kernel_not_running"
    assert session.pending == {}


def test_execute_on_dead_kernel_raises_without_double_response():
    """Death before submit: the KernelError raise is the single response and
    nothing is left registered for _fail_pending to answer again."""
    conn = _FakeConn()
    session = BridgeSession(conn)
    kernel = _FakeKernel()
    kernel.client = None
    session.kernel = kernel  # type: ignore[assignment]

    with pytest.raises(KernelError) as excinfo:
        session.execute("1+1", "cell-a", 42)
    assert excinfo.value.code == "kernel_not_running"
    assert session.pending == {}
    assert conn.responses(42) == []


def test_late_iopub_after_execute_reply_still_tagged():
    """Regression (macOS CI): ZMQ has no cross-socket ordering, so a cell's
    last iopub outputs can be delivered after the shell execute_reply was
    processed. The pending entry is already popped at that point; the late
    outputs must still be tagged to the originating cell, not dropped."""
    from jove_bridge.session import _Pending

    conn = _FakeConn()
    session = BridgeSession(conn)
    with session._lock:
        session.pending["m-late"] = _Pending("execute", 7, "c-late")

    # Shell reply first: pops the pending entry and answers ok.
    session._handle_shell(
        {
            "parent_header": {"msg_id": "m-late"},
            "msg_type": "execute_reply",
            "content": {"status": "ok"},
        }
    )
    assert conn.responses(7) == [{"id": 7, "result": {"status": "ok"}}]

    # Then the iopub stream arrives late — still tagged to "c-late".
    session._handle_iopub(
        {
            "parent_header": {"msg_id": "m-late"},
            "msg_type": "stream",
            "content": {"name": "stdout", "text": "second-done\n"},
        }
    )
    outputs = [m["params"] for m in conn.msgs if m.get("event") == "output"]
    assert any(
        p["cell"] == "c-late"
        and p["kind"] == "stream"
        and p["mime"]["text/plain"] == "second-done\n"
        for p in outputs
    ), conn.msgs

    # Late error outputs are tagged too (interrupt traceback race).
    session._handle_iopub(
        {
            "parent_header": {"msg_id": "m-late"},
            "msg_type": "error",
            "content": {"ename": "KeyboardInterrupt", "evalue": "", "traceback": []},
        }
    )
    outputs = [m["params"] for m in conn.msgs if m.get("event") == "output"]
    assert any(
        p["cell"] == "c-late" and p["kind"] == "error" for p in outputs
    ), conn.msgs

    # Unknown parents and expired grace entries are still dropped.
    session._handle_iopub(
        {
            "parent_header": {"msg_id": "never-sent"},
            "msg_type": "stream",
            "content": {"name": "stdout", "text": "x"},
        }
    )
    outputs = [m["params"] for m in conn.msgs if m.get("event") == "output"]
    assert all(p["cell"] != "never-sent" for p in outputs)


def test_version_matches_pyproject() -> None:
    """__version__ must track pyproject.toml so the `ready` event can't drift."""
    import re
    from pathlib import Path

    import jove_bridge

    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    match = re.search(r'^version\s*=\s*"([^"]+)"', pyproject.read_text(), re.MULTILINE)
    assert match, "pyproject.toml has no version field"
    assert jove_bridge.__version__ == match.group(1)
