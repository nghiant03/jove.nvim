"""Variable-inspector bridge tests (Phase D).

Unit tests drive :meth:`BridgeSession._finish_variables` with a recording fake
connection, and the ``variables`` submit path with a fake client. The e2e test
reuses ``test_bridge.BridgeProcess`` to run the probe against a real python3
ipykernel.
"""

from __future__ import annotations

import json

import pytest

from jove_bridge.kernel import KernelError
from jove_bridge.session import DEFERRED, BridgeSession, _Pending

try:  # test module sibling; pytest prepends the test dir to sys.path
    from test_bridge import BridgeProcess
except Exception:  # pragma: no cover - only when run out of tree
    BridgeProcess = None  # type: ignore[assignment]


class _FakeConn:
    """Records everything the session would write to the wire."""

    def __init__(self) -> None:
        self.msgs: list = []

    def send_result(self, reply_id, result):
        self.msgs.append({"id": reply_id, "result": result})

    def send_error(self, reply_id, code, message):
        self.msgs.append({"id": reply_id, "error": {"code": code, "message": message}})

    def send_event(self, event, params):
        self.msgs.append({"event": event, "params": params})


class _FakeKM:
    def __init__(self, name: str) -> None:
        self.kernel_name = name


class _FakeKernel:
    """Duck-typed KernelController: only what the variables path touches."""

    def __init__(self, language: str = "python", name: str = "python3") -> None:
        self.km = _FakeKM(name)
        self._language = language

    def list_kernelspecs(self):
        return {self.km.kernel_name: {"language": self._language}}

    def require_client(self):
        raise KernelError("kernel_not_running", "start a kernel first")


class _RecordingClient:
    def __init__(self, msg_id: str = "msg-v") -> None:
        self.msg_id = msg_id
        self.captured: dict = {}

    def execute(self, code, **kwargs):
        self.captured["code"] = code
        self.captured.update(kwargs)
        return self.msg_id


class _KernelWithClient:
    def __init__(self, client: _RecordingClient) -> None:
        self.km = _FakeKM("python3")
        self.client = client

    def list_kernelspecs(self):
        return {"python3": {"language": "python"}}

    def require_client(self):
        return self.client


def test_finish_variables_parses_user_expression():
    conn = _FakeConn()
    session = BridgeSession(conn)
    payload = [
        {"name": "x", "type": "int", "value": "1", "size": None},
        {"name": "s", "type": "str", "value": "'hi'", "size": 2},
    ]
    content = {
        "status": "ok",
        "user_expressions": {
            "__jove__": {"status": "ok", "data": {"text/plain": json.dumps(payload)}}
        },
    }
    session._finish_variables(_Pending("variables", 5), "execute_reply", content)
    assert conn.msgs == [{"id": 5, "result": {"variables": payload}}]


def test_finish_variables_unwraps_ipython_string_repr():
    """ipykernel's text/plain for a str expression is its repr (quoted)."""
    conn = _FakeConn()
    session = BridgeSession(conn)
    payload = [{"name": "x", "type": "int", "value": "'hi'", "size": 2}]
    text = repr(json.dumps(payload))  # e.g. '\'[{"name": "x", ...}]\''
    content = {
        "status": "ok",
        "user_expressions": {"__jove__": {"status": "ok", "data": {"text/plain": text}}},
    }
    session._finish_variables(_Pending("variables", 8), "execute_reply", content)
    assert conn.msgs == [{"id": 8, "result": {"variables": payload}}]


def test_finish_variables_degrades_to_empty_on_bad_json():
    conn = _FakeConn()
    session = BridgeSession(conn)
    content = {
        "status": "ok",
        "user_expressions": {
            "__jove__": {"status": "ok", "data": {"text/plain": "not json"}}
        },
    }
    session._finish_variables(_Pending("variables", 6), "execute_reply", content)
    assert conn.msgs == [{"id": 6, "result": {"variables": []}}]


def test_finish_variables_empty_when_expression_errored():
    conn = _FakeConn()
    session = BridgeSession(conn)
    content = {
        "status": "ok",
        "user_expressions": {"__jove__": {"status": "error", "data": {}}},
    }
    session._finish_variables(_Pending("variables", 7), "execute_reply", content)
    assert conn.msgs == [{"id": 7, "result": {"variables": []}}]


def test_variables_unsupported_for_non_python_kernel():
    conn = _FakeConn()
    session = BridgeSession(conn)
    session.kernel = _FakeKernel(language="julia", name="julia-1.9")  # type: ignore[assignment]

    result = session.variables(9)
    assert result == {"variables": [], "unsupported": "julia"}
    assert conn.msgs == []


def test_variables_submits_silent_user_expression_and_replies_on_shell_reply():
    conn = _FakeConn()
    session = BridgeSession(conn)
    client = _RecordingClient()
    session.kernel = _KernelWithClient(client)  # type: ignore[assignment]

    assert session.variables(10) is DEFERRED
    assert client.captured["code"] == ""
    # ipykernel drops user_expressions when silent=True, so the probe is
    # non-silent but non-history.
    assert client.captured["silent"] is False
    assert client.captured["store_history"] is False
    expr = client.captured["user_expressions"]["__jove__"]
    assert "globals()" in expr and "json" in expr

    content = {
        "status": "ok",
        "user_expressions": {
            "__jove__": {"status": "ok", "data": {"text/plain": "[]"}}
        },
    }
    session._handle_shell(
        {
            "parent_header": {"msg_id": client.msg_id},
            "msg_type": "execute_reply",
            "content": content,
        }
    )
    assert conn.msgs == [{"id": 10, "result": {"variables": []}}]


@pytest.mark.skipif(BridgeProcess is None, reason="test_bridge helper unavailable")
def test_variables_e2e_real_kernel():
    """Round-trip against a real python3 ipykernel: types, repr, size, filter."""
    proc = BridgeProcess()  # type: ignore[misc]
    try:
        proc.wait_ready()
        proc.start_kernel("python3")
        msg = proc.request(
            "execute",
            {"code": "jv_x = 41\njv_s = 'hi'\nimport os", "cell": "v0"},
        )
        assert msg.get("result", {}).get("status") == "ok"

        msg = proc.request("variables")
        result = msg["result"]
        assert "variables" in result, msg
        by_name = {v["name"]: v for v in result["variables"]}
        assert by_name["jv_x"]["type"] == "int"
        assert by_name["jv_x"]["value"] == "41"
        assert by_name["jv_s"]["type"] == "str"
        assert by_name["jv_s"]["value"] == "'hi'"
        assert by_name["jv_s"]["size"] == 2
        assert "os" not in by_name  # imported modules are filtered out
        assert not any(n.startswith("_") for n in by_name)
    finally:
        proc.close()
