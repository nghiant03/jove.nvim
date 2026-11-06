import io
import json
from pathlib import Path
from unittest.mock import Mock

import pytest

from jove_bridge.__main__ import Connection
from jove_bridge.session import DEFERRED, BridgeSession


@pytest.mark.unit
def test_session_produces_shared_protocol_contract(monkeypatch):
    fixture = Path(__file__).resolve().parents[2] / "tests/fixtures/protocol.json"
    contract = json.loads(fixture.read_text(encoding="utf-8"))
    output = io.StringIO()
    conn = Connection(output)
    session = BridgeSession(conn)
    client = Mock()
    client.execute.side_effect = [
        f"kernel-{request['id']}" for request in contract["requests"]
    ]
    monkeypatch.setattr(session.kernel, "require_client", lambda: client)
    try:
        for request in contract["requests"]:
            assert (
                session.dispatch(request["method"], request["params"], request["id"])
                is DEFERRED
            )
        assert [call.args for call in client.execute.call_args_list] == [
            (request["params"]["code"],) for request in contract["requests"]
        ]
        for step in contract["steps"]:
            message = {
                "msg_type": step["msg_type"],
                "parent_header": {"msg_id": f"kernel-{step['request_id']}"},
                "content": step["content"],
            }
            if step["channel"] == "iopub":
                session._handle_iopub(message)
            else:
                session._handle_shell(message)
        assert not session.pending
    finally:
        session.stop()
        session.shutdown_kernel()
        conn.close()
    assert not conn._thread.is_alive()
    assert [json.loads(line) for line in output.getvalue().splitlines()] == [
        step["wire"] for step in contract["steps"]
    ]
