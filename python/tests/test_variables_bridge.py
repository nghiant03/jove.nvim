"""Variable-inspector bridge tests."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass

import pytest

from jove_bridge.kernel import KernelError
from jove_bridge.languages import (
    _PYTHON_REVISION,
    PYTHON,
    DisplayProbe,
    Probe,
    lookup,
    register,
)
from jove_bridge.session import DEFERRED, BridgeSession, _Pending

from .support import KERNEL_TIMEOUT

pytestmark = pytest.mark.usefixtures("isolated_inspector", "isolated_registry")


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


class _RecordingClient:
    def __init__(self, msg_id: str = "msg-v") -> None:
        self.msg_id = msg_id
        self.captured: dict = {}

    def execute(self, code, **kwargs):
        self.captured["code"] = code
        self.captured.update(kwargs)
        return self.msg_id


class _KernelWithClient:
    def __init__(self, client: _RecordingClient, language: str = "python") -> None:
        self.km = _FakeKM("python3")
        self.client = client
        self._language = language

    def list_kernelspecs(self):
        return {self.km.kernel_name: {"language": self._language}}

    def require_client(self):
        return self.client


def _reply(session, reply_id, content):
    client = _RecordingClient()
    session.kernel = _KernelWithClient(client)  # type: ignore[assignment]
    assert session.variables(reply_id) is DEFERRED
    session._handle_shell(
        {
            "msg_type": "execute_reply",
            "parent_header": {"msg_id": client.msg_id},
            "content": content,
        }
    )


@pytest.mark.unit
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
    _reply(session, 5, content)
    assert conn.msgs == [{"id": 5, "result": {"variables": payload}}]


@pytest.mark.unit
def test_finish_variables_unwraps_ipython_string_repr():
    conn = _FakeConn()
    session = BridgeSession(conn)
    payload = [{"name": "x", "type": "int", "value": "'hi'", "size": 2}]
    text = repr(json.dumps(payload))
    content = {
        "status": "ok",
        "user_expressions": {
            "__jove__": {"status": "ok", "data": {"text/plain": text}}
        },
    }
    _reply(session, 8, content)
    assert conn.msgs == [{"id": 8, "result": {"variables": payload}}]


@pytest.mark.unit
def test_finish_variables_reports_bad_json():
    conn = _FakeConn()
    session = BridgeSession(conn)
    content = {
        "status": "ok",
        "user_expressions": {
            "__jove__": {"status": "ok", "data": {"text/plain": "not json"}}
        },
    }
    _reply(session, 6, content)
    assert [(msg["id"], msg["error"]["code"]) for msg in conn.msgs] == [
        (6, "variables_failed")
    ]


@pytest.mark.unit
def test_finish_variables_reports_expression_failure():
    conn = _FakeConn()
    session = BridgeSession(conn)
    content = {
        "status": "ok",
        "user_expressions": {"__jove__": {"status": "error", "data": {}}},
    }
    _reply(session, 7, content)
    assert [(msg["id"], msg["error"]["code"]) for msg in conn.msgs] == [
        (7, "variables_failed")
    ]


@pytest.mark.unit
def test_variables_unsupported_for_non_python_kernel():
    conn = _FakeConn()
    session = BridgeSession(conn)
    session.kernel = _KernelWithClient(_RecordingClient(), "julia")  # type: ignore[assignment]

    result = session.variables(9)
    assert result == {"variables": [], "unsupported": "julia"}
    assert conn.msgs == []


@pytest.mark.unit
def test_variables_submits_silent_user_expression_and_replies_on_shell_reply():
    conn = _FakeConn()
    session = BridgeSession(conn)
    client = _RecordingClient()
    session.kernel = _KernelWithClient(client)  # type: ignore[assignment]

    assert session.variables(10) is DEFERRED
    assert client.captured["code"] == PYTHON.install
    assert client.captured["silent"] is True
    assert client.captured["store_history"] is False
    assert client.captured["user_expressions"]["__jove__"] == PYTHON.query
    assert "globals()" in PYTHON.query

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


@pytest.mark.unit
def test_variables_per_item_resilience():
    class BoomLen:
        def __len__(self):
            raise TypeError("len() of unsized object")

        def __repr__(self):
            return "BoomLen()"

    class BoomRepr:
        def __repr__(self):
            raise ValueError("broken repr")

    assert isinstance(PYTHON.install, str)
    assert isinstance(PYTHON.query, str)
    ns = {"regular": 41, "s": "hi", "boom_len": BoomLen(), "boom_repr": BoomRepr()}
    exec(PYTHON.install, ns)
    data = json.loads(eval(PYTHON.query, ns))

    by_name = {v["name"]: v for v in data}
    assert not any(n.startswith("_") for n in by_name), by_name
    assert by_name["regular"]["type"] == "int"
    assert by_name["regular"]["value"] == "41"
    assert by_name["regular"]["size"] is None
    assert by_name["s"]["size"] == 2
    assert by_name["boom_len"]["value"] == "BoomLen()"
    assert by_name["boom_len"]["size"] is None
    assert by_name["boom_repr"]["value"] == "<repr failed>"

    assert not any(k.startswith("_jv_") or k == "_jove_inspector" for k in ns), ns

    exec(PYTHON.install, ns)
    assert json.loads(eval(PYTHON.query, ns)) == data
    assert not any(k.startswith("_jv_") or k == "_jove_inspector" for k in ns), ns


@pytest.mark.unit
def test_variables_install_preserves_existing_names():
    namespace = {
        "_jv_sys": object(),
        "_jv_types": object(),
        "_jv_m": object(),
        "source": object(),
        "revision": object(),
        "module": object(),
        "x": 41,
    }
    original = namespace.copy()
    exec(PYTHON.install, namespace)
    assert namespace.keys() == original.keys() | {"__builtins__"}
    assert all(namespace[name] is value for name, value in original.items())


@pytest.mark.unit
def test_variables_install_reuses_current_module():
    import sys

    exec(PYTHON.install, {})
    installed = sys.modules["_jove_inspector"]
    exec(PYTHON.install, {})
    assert sys.modules["_jove_inspector"] is installed


@pytest.mark.unit
def test_variables_install_replaces_stale_module():
    import sys

    ns = {"x": 41}
    exec(PYTHON.install, ns)
    assert sys.modules["_jove_inspector"]._jove_rev == _PYTHON_REVISION

    sys.modules["_jove_inspector"]._jove_rev = "stale"
    exec(PYTHON.install, ns)
    assert sys.modules["_jove_inspector"]._jove_rev == _PYTHON_REVISION
    assert json.loads(eval(PYTHON.query, ns))[0]["name"] == "x"


@pytest.mark.unit
def test_variables_per_item_resilience_numpy_zero_dim():
    """Zero-dimensional NumPy arrays report size=None rather than erroring."""
    np = pytest.importorskip("numpy")
    ns = {"scalar": np.array(1), "regular": 41}
    exec(PYTHON.install, ns)
    data = json.loads(eval(PYTHON.query, ns))
    by_name = {v["name"]: v for v in data}
    assert by_name["scalar"]["type"] == "ndarray"
    assert by_name["scalar"]["size"] is None
    assert by_name["regular"]["size"] is None


@pytest.mark.unit
def test_lookup_normalizes_language_spellings():
    assert lookup("Python3") is PYTHON
    assert lookup(" python ") is PYTHON
    assert lookup(None) is None
    assert lookup("not-a-language") is None


@pytest.mark.unit
def test_variables_resolves_probe_from_kernel_language():
    conn = _FakeConn()
    session = BridgeSession(conn)
    client = _RecordingClient(msg_id="msg-lang")
    session.kernel = _KernelWithClient(client, language="Python3")  # type: ignore[assignment]

    assert session.variables(12) is DEFERRED
    assert client.captured["code"] == PYTHON.install


@pytest.mark.unit
def test_variables_uses_registered_probe_for_new_language():
    probe = Probe(" Dummy ", install="1 + 1", query="'[]'")
    register(probe)
    conn = _FakeConn()
    session = BridgeSession(conn)
    client = _RecordingClient(msg_id="msg-dummy")
    session.kernel = _KernelWithClient(client, language="Dummy")  # type: ignore[assignment]

    assert session.variables(13) is DEFERRED
    assert client.captured["code"] == "1 + 1"
    assert client.captured["user_expressions"]["__jove__"] == "'[]'"


@pytest.mark.unit
def test_variables_unsupported_for_unresolvable_language():
    assert lookup(None) is None

    conn = _FakeConn()
    session = BridgeSession(conn)
    session.kernel = _KernelWithClient(_RecordingClient(), "")  # type: ignore[assignment]

    assert session.variables(14) == {"variables": [], "unsupported": "unknown"}


@pytest.mark.unit
def test_variables_without_running_kernel_is_an_error():
    with pytest.raises(KernelError) as exc:
        BridgeSession(_FakeConn()).variables(22)
    assert exc.value.code == "kernel_not_running"


@pytest.mark.unit
@pytest.mark.parametrize(
    "language,implementation",
    [("R", "IRkernel"), ("Julia", "ijulia")],
)
def test_native_probe_requires_a_recognized_implementation(language, implementation):
    assert isinstance(lookup(language, implementation), DisplayProbe)
    assert lookup(language) is None
    assert lookup(language, implementation + "-other") is None
    assert lookup("unrelated", implementation) is None


@pytest.mark.unit
@pytest.mark.parametrize(
    "language,implementation", [("javascript", "jslab"), ("typescript", "tslab")]
)
def test_unsupported_kernels_do_not_execute_a_probe(language, implementation):
    client = _RecordingClient()
    session = BridgeSession(_FakeConn())
    session.kernel = _KernelWithClient(client)  # type: ignore[assignment]
    session._kernel_info = (language, implementation)
    assert session.variables(9) == {"variables": [], "unsupported": language}
    assert client.captured == {}


@pytest.mark.unit
def test_variables_prefer_kernel_info_over_kernelspec():
    session = BridgeSession(_FakeConn())
    session.kernel = _KernelWithClient(_RecordingClient(), "python")  # type: ignore[assignment]
    session.pending["probe"] = _Pending("ready_probe", None)
    session._handle_shell(
        {
            "parent_header": {"msg_id": "probe"},
            "msg_type": "kernel_info_reply",
            "content": {
                "implementation": "unverified",
                "language_info": {"name": "julia"},
            },
        }
    )
    assert session.variables(9) == {"variables": [], "unsupported": "julia"}


def _msg(kind, content, parent="msg-v"):
    return {"msg_type": kind, "content": content, "parent_header": {"msg_id": parent}}


@pytest.fixture
def display_session():
    session = BridgeSession(_FakeConn())
    client = _RecordingClient()
    session.kernel = _KernelWithClient(client)  # type: ignore[assignment]
    session._kernel_info = ("R", "IRkernel")
    assert session.variables(27) is DEFERRED
    probe = lookup("R", "IRkernel")
    assert isinstance(probe, DisplayProbe)
    assert client.captured == {
        "code": probe.code,
        "silent": True,
        "store_history": False,
        "allow_stdin": False,
    }
    return session


@pytest.mark.unit
@pytest.mark.parametrize("shell_first", [True, False])
@pytest.mark.parametrize("kind", ["display_data", "execute_result"])
@pytest.mark.parametrize("serialize", [True, False])
def test_private_snapshot_waits_for_reply_and_matching_idle(
    display_session, shell_first, kind, serialize
):
    session = display_session
    rows = [{"name": "café", "type": "integer", "value": "1", "size": 1}]
    show = _msg(
        kind, {"data": {"application/json": json.dumps(rows) if serialize else rows}}
    )
    reply = _msg("execute_reply", {"status": "ok"})
    idle = _msg("status", {"execution_state": "idle"})
    if shell_first:
        session._handle_shell(reply)
    session._handle_iopub(_msg("stream", {"name": "stdout", "text": "not a snapshot"}))
    session._handle_iopub(
        _msg(kind, {"data": {"application/json": []}}, parent="other")
    )
    session._handle_iopub(show)
    assert session.conn.msgs == []
    session._handle_iopub(idle)
    if not shell_first:
        assert session.conn.msgs == []
        session._handle_shell(reply)
    session._handle_shell(reply)
    session._handle_iopub(show)
    assert session.conn.msgs == [{"id": 27, "result": {"variables": rows}}]
    assert session.pending == {}


@pytest.mark.unit
@pytest.mark.parametrize(
    "payload,reason",
    [
        ({}, "array"),
        ("not json", "JSON"),
        ([{}], "invalid variable row"),
        (None, "missing"),
        ([{"name": "x", "type": "number", "value": "0", "size": True}], "size"),
    ],
)
def test_display_errors_are_not_empty_snapshots(display_session, payload, reason):
    session = display_session
    if payload is not None:
        session._handle_iopub(
            _msg("display_data", {"data": {"application/json": payload}})
        )
    session._handle_iopub(_msg("status", {"execution_state": "idle"}))
    session._handle_shell(_msg("execute_reply", {"status": "ok"}))
    assert len(session.conn.msgs) == 1
    error = session.conn.msgs[0]["error"]
    assert error["code"] == "variables_failed" and reason in error["message"]


@pytest.mark.unit
@pytest.mark.parametrize(
    "source", ["iopub", "shell", "duplicate", "oversize", "too_many_rows"]
)
def test_display_errors_override_captured_rows(display_session, monkeypatch, source):
    session = display_session
    monkeypatch.setattr("jove_bridge.session.MAX_VARIABLE_BYTES", 250)
    monkeypatch.setattr("jove_bridge.session.MAX_VARIABLE_ROWS", 2)
    row = {"name": "x", "type": "str", "value": "s" * 160}
    rows = [row] * {"oversize": 2, "too_many_rows": 3}.get(source, 0)
    show = _msg("display_data", {"data": {"application/json": rows}})
    session._handle_iopub(show)
    if source == "duplicate":
        session._handle_iopub(show)
    if source == "iopub":
        session._handle_iopub(_msg("error", {"evalue": "boom"}))
    session._handle_shell(
        _msg("execute_reply", {"status": "error" if source == "shell" else "ok"})
    )
    session._handle_iopub(_msg("status", {"execution_state": "idle"}))
    assert [msg["error"]["code"] for msg in session.conn.msgs] == ["variables_failed"]


@pytest.mark.unit
def test_display_timeout_drops_late_messages_without_consuming_cell_output(
    display_session,
):
    session = display_session
    session.pending["cell-id"] = _Pending("execute", 20, "other-cell")
    stream = {"name": "stdout", "text": "user output"}
    session._handle_iopub(_msg("stream", stream, parent="cell-id"))
    session._handle_shell(_msg("execute_reply", {"status": "ok"}))
    session.pending["msg-v"].deadline = 0
    session._expire_variables()
    session._handle_iopub(_msg("display_data", {"data": {"application/json": []}}))
    session._expire_variables()
    first, second = session.conn.msgs
    assert first["event"] == "output" and first["params"]["cell"] == "other-cell"
    assert second["id"] == 27 and second["error"]["code"] == "variables_timeout"
    assert set(session.pending) == {"cell-id"}


@pytest.mark.unit
def test_limits_concurrent_snapshots_without_submitting_another(
    display_session, monkeypatch
):
    session = display_session
    monkeypatch.setattr("jove_bridge.session.MAX_VARIABLE_REQUESTS", 1)
    session.kernel.client.captured.clear()
    with pytest.raises(KernelError) as exc:
        session.variables(28)
    assert exc.value.code == "variables_busy"
    assert session.kernel.client.captured == {}
    assert set(session.pending) == {"msg-v"}


@pytest.mark.unit
def test_restart_clears_probe_identity_and_pending_snapshots(
    display_session, monkeypatch
):
    session = display_session
    monkeypatch.setattr(
        session.kernel, "require_km", lambda: session.kernel.km, raising=False
    )
    monkeypatch.setattr(
        session.kernel.km, "restart_kernel", lambda: None, raising=False
    )
    monkeypatch.setattr(session, "_probe_ready", lambda: True)
    assert session.restart() == {}
    session._handle_shell(_msg("execute_reply", {"status": "ok"}))
    assert session.pending == {} and session._kernel_info == (None, None)
    assert [m["error"]["code"] for m in session.conn.msgs if "error" in m] == [
        "kernel_not_running"
    ]


@pytest.mark.integration
def test_variables_e2e_real_kernel(kernel):
    proc = kernel
    msg = proc.request(
        "execute",
        {
            "code": (
                "jv_x = 41\njv_s = 'hi'\nimport os\n"
                "class jv_Boom:\n"
                "    def __len__(self):\n"
                "        raise TypeError('len() of unsized object')\n"
                "    def __repr__(self):\n"
                "        return 'jv_Boom()'\n"
                "jv_boom = jv_Boom()"
            ),
            "cell": "v0",
        },
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
    assert by_name["jv_boom"]["value"] == "jv_Boom()"
    assert by_name["jv_boom"]["size"] is None
    assert "os" not in by_name
    assert not any(n.startswith("_") for n in by_name)


@dataclass(frozen=True)
class Case:
    language: str
    setup: str
    update: str
    marker: str
    type_fragment: str


CASES = [
    Case(
        "python",
        "jove_items = [11, 22, 33]\njove_label = 'café'\n_jove_hidden = True",
        "jove_items = [81, 92]",
        "print('inspection finished')",
        "list",
    ),
    Case(
        "r",
        'jove_items <- c(11L, 22L, 33L); jove_label <- "café"; .jove_hidden <- TRUE; '
        'makeActiveBinding("jove_active", function() stop("do not force"), .GlobalEnv)',
        "jove_items <- c(81L, 92L)",
        'cat("inspection finished\\n")',
        "integer",
    ),
    Case(
        "julia",
        'jove_label = "café"; _jove_hidden = true; jove_items = [11, 22, 33];',
        "@assert ans === jove_items; @assert length(In) == 2; jove_items = [81, 92];",
        'println("inspection finished")',
        "Vector",
    ),
]


def _snapshot(proc):
    msg = proc.request("variables", timeout=KERNEL_TIMEOUT)
    assert "result" in msg and "unsupported" not in msg["result"], msg
    rows = msg["result"]["variables"]
    assert all(set(row) == {"name", "type", "value", "size"} for row in rows)
    by_name = {row["name"]: row for row in rows}
    assert len(by_name) == len(rows)
    return by_name


def _execute(proc, cell, code):
    msg = proc.request("execute", {"code": code, "cell": cell}, timeout=KERNEL_TIMEOUT)
    assert msg.get("result", {}).get("status") == "ok", msg
    return msg["result"]["execution_count"]


@pytest.mark.integration
@pytest.mark.parametrize("case", CASES, ids=lambda case: case.language)
def test_variables_live_session(bridge, case):
    if case.language == "python":
        kernelspec = "python3"
    else:
        key = f"JOVE_TEST_{case.language.upper()}_KERNEL"
        kernelspec = os.environ.get(key)
        if not kernelspec:
            specs = bridge.request("list_kernelspecs")["result"]["kernelspecs"]
            pattern = "ir" if case.language == "r" else r"julia-\d+\.\d+"
            kernelspec = next(
                (
                    name
                    for name in sorted(specs)
                    if specs[name]["language"].lower() == case.language
                    and re.fullmatch(pattern, name)
                ),
                None,
            )
            if not kernelspec:
                pytest.skip(
                    f"No default {case.language} kernel; set {key} to select one"
                )

    bridge.start_kernel(kernelspec)
    before = bridge.cursor()
    baseline = _snapshot(bridge)
    first_count = _execute(bridge, "setup", case.setup)
    created = _snapshot(bridge)
    assert created.keys() == baseline.keys() | {"jove_items", "jove_label"}
    items = created["jove_items"]
    assert case.type_fragment in items["type"]
    assert items["size"] == 3 and "11" in items["value"] and "33" in items["value"]
    assert "café" in created["jove_label"]["value"]
    assert _snapshot(bridge)["jove_items"] == items

    assert _execute(bridge, "update", case.update) == first_count + 1
    updated = _snapshot(bridge)
    assert updated.keys() == created.keys()
    assert updated["jove_items"]["size"] == 2 and "92" in updated["jove_items"]["value"]

    assert _execute(bridge, "marker", case.marker) == first_count + 2
    bridge.wait_event("output", since=before, pred=lambda p: p["cell"] == "marker")
    outputs = bridge.outputs_since(before)
    assert len(outputs) == 1 and outputs[0]["kind"] == "stream", outputs
    assert "inspection finished" in outputs[0]["mime"]["text/plain"]

    assert bridge.request("restart", timeout=KERNEL_TIMEOUT).get("result") == {}
    assert _snapshot(bridge).keys() == baseline.keys()
    assert _execute(bridge, "fresh", case.setup) == first_count
    assert _snapshot(bridge)["jove_items"] == items
