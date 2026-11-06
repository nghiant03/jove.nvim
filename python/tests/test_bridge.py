"""Bridge protocol conformance tests."""

from __future__ import annotations

import pytest

from jove_bridge.kernel import KernelError
from jove_bridge.session import DEFERRED as DEFERRED_SENTINEL
from jove_bridge.session import BridgeSession


@pytest.mark.integration
def test_ready_and_list_kernelspecs(bridge):
    ready = bridge.messages[0]
    assert ready["event"] == "ready"
    assert ready["params"]["protocol"] == 1

    msg = bridge.request("list_kernelspecs")
    specs = msg["result"]["kernelspecs"]
    assert "python3" in specs
    assert specs["python3"]["display_name"]
    assert specs["python3"]["language"]


@pytest.mark.integration
def test_requests_before_kernel_start(bridge):
    for method, params in (
        ("execute", {"code": "1+1", "cell": "c"}),
        ("interrupt", {}),
        ("restart", {}),
    ):
        msg = bridge.request(method, params)
        assert msg["error"]["code"] == "kernel_not_running", msg


@pytest.mark.integration
def test_unknown_method(bridge):
    msg = bridge.request("definitely_not_a_method", {})
    assert msg["error"]["code"] == "unknown_method"


@pytest.mark.integration
def test_invalid_params(bridge):
    msg = bridge.request("start_kernel", {})
    assert msg["error"]["code"] == "invalid_params"
    msg = bridge.request("execute", {"code": "1"})
    assert msg["error"]["code"] == "invalid_params"


@pytest.mark.integration
def test_protocol_error_then_recover(bridge):
    bridge.send_line("this is not json {{{")
    ev = bridge.wait_event("protocol_error", since=0)
    assert isinstance(ev["params"], dict) and ev["params"]
    msg = bridge.request("list_kernelspecs")
    assert "python3" in msg["result"]["kernelspecs"]


@pytest.mark.integration
def test_start_kernel_status_sequence(bridge):
    since = bridge.cursor()
    bridge.start_kernel("python3")
    statuses = bridge.statuses_since(since)
    assert statuses[0] == "starting"
    assert "idle" in statuses


@pytest.mark.integration
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


@pytest.mark.integration
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


@pytest.mark.integration
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


@pytest.mark.integration
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


@pytest.mark.integration
def test_overlapping_executes(kernel):
    since = kernel.cursor()
    rid1 = kernel.send_request(
        "execute",
        {"code": "import time\ntime.sleep(0.7)\nprint('first-done')", "cell": "c1"},
    )
    rid2 = kernel.send_request(
        "execute", {"code": "print('second-done')", "cell": "c2"}
    )
    r1 = kernel.wait_response(rid1, since=since)
    r2 = kernel.wait_response(rid2, since=since)
    assert r1["result"].get("status") == "ok"
    assert r2["result"].get("status") == "ok"

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
    return "print('started'); import time; time.sleep(30)"


@pytest.mark.integration
def test_interrupt(kernel):
    since = kernel.cursor()
    rid = kernel.send_request(
        "execute", {"code": _interruptable_sleep(), "cell": "slow"}
    )
    kernel.wait_event("output", since=since, pred=lambda p: p.get("cell") == "slow")
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


@pytest.mark.integration
def test_interrupt_with_queued_execute_error_implies_output(kernel):
    since = kernel.cursor()
    rid_sleep = kernel.send_request(
        "execute", {"code": _interruptable_sleep(), "cell": "sleep"}
    )
    kernel.wait_event("output", since=since, pred=lambda p: p.get("cell") == "sleep")
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

    kernel.wait_status("idle", since=since)
    outputs = kernel.outputs_since(since)
    for cell in ("sleep", "quick"):
        errs = [
            o for o in outputs if o.get("cell") == cell and o.get("kind") == "error"
        ]
        assert len(errs) == 1, f"expected exactly one error output for {cell!r}"
        assert errs[0]["mime"]["text/plain"]

    msg = kernel.request("execute", {"code": "print('alive')", "cell": "after"})
    assert msg["result"].get("status") == "ok"


@pytest.mark.integration
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

    msg = bridge.request("execute", {"code": "print(jove_secret)", "cell": "s2"})
    result = msg["result"]
    assert result["status"] == "error"
    assert result["ename"] == "NameError"


@pytest.mark.integration
def test_shutdown_exits_zero(bridge):
    bridge.start_kernel("python3")
    msg = bridge.request("shutdown")
    assert msg["result"] == {}
    rc = bridge.proc.wait(timeout=10)
    assert rc == 0


@pytest.mark.integration
def test_stdin_eof_exits_zero(bridge):
    bridge.start_kernel("python3")
    bridge.proc.stdin.close()
    rc = bridge.proc.wait(timeout=20)
    assert rc == 0


class _FakeConn:
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
    def __init__(self):
        self.km = _FakeKM()
        self.client = _FakeClient(self)

    def require_client(self):
        if self.client is None:
            raise KernelError("kernel_not_running", "start a kernel first")
        return self.client

    def mark_dead(self):
        self.client = None


@pytest.mark.unit
def test_single_response_when_kernel_dies_during_execute():
    conn = _FakeConn()
    session = BridgeSession(conn)
    session.kernel = _FakeKernel()  # type: ignore[assignment]

    assert session.execute("1+1", "cell-a", 42) is DEFERRED_SENTINEL
    session._check_alive()

    responses = conn.responses(42)
    assert len(responses) == 1, conn.msgs
    assert responses[0]["error"]["code"] == "kernel_not_running"
    assert session.pending == {}


@pytest.mark.unit
def test_execute_on_dead_kernel_raises_without_double_response():
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


@pytest.mark.unit
def test_late_iopub_after_execute_reply_still_tagged():
    from jove_bridge.session import _Pending

    conn = _FakeConn()
    session = BridgeSession(conn)
    with session._lock:
        session.pending["m-late"] = _Pending("execute", 7, "c-late")

    session._handle_shell(
        {
            "parent_header": {"msg_id": "m-late"},
            "msg_type": "execute_reply",
            "content": {"status": "ok"},
        }
    )
    assert conn.responses(7) == [{"id": 7, "result": {"status": "ok"}}]

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

    session._handle_iopub(
        {
            "parent_header": {"msg_id": "m-late"},
            "msg_type": "error",
            "content": {"ename": "KeyboardInterrupt", "evalue": "", "traceback": []},
        }
    )
    outputs = [m["params"] for m in conn.msgs if m.get("event") == "output"]
    assert any(p["cell"] == "c-late" and p["kind"] == "error" for p in outputs), (
        conn.msgs
    )

    session._handle_iopub(
        {
            "parent_header": {"msg_id": "never-sent"},
            "msg_type": "stream",
            "content": {"name": "stdout", "text": "x"},
        }
    )
    outputs = [m["params"] for m in conn.msgs if m.get("event") == "output"]
    assert all(p["cell"] != "never-sent" for p in outputs)
