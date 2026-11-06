import io
import subprocess
import sys
from unittest.mock import Mock

import pytest

from . import conftest
from .support import BridgeProcess


@pytest.mark.integration
@pytest.mark.parametrize("line", ["not json", "[]", "null", '"text"'])
def test_malformed_stdout_fails_wait_and_health_check(line):
    proc = BridgeProcess([sys.executable, "-c", f"print({line!r})"])
    try:
        with pytest.raises(AssertionError, match="malformed bridge stdout"):
            proc.wait_ready(timeout=5)
    finally:
        proc.close()
    with pytest.raises(AssertionError, match="malformed bridge stdout"):
        proc.assert_healthy()
    assert proc.proc.returncode is not None
    assert all(not reader.is_alive() for reader in proc._readers)
    assert all(
        stream.closed
        for stream in (proc.proc.stdin, proc.proc.stdout, proc.proc.stderr)
    )
    proc.close()


@pytest.mark.unit
@pytest.mark.parametrize(
    "failure", [AssertionError("not ready"), RuntimeError("setup")]
)
def test_bridge_fixture_cleans_up_failed_setup(monkeypatch, failure):
    proc = Mock(spec=BridgeProcess)
    proc.wait_ready.side_effect = failure
    monkeypatch.setattr(conftest, "BridgeProcess", lambda **kwargs: proc)
    fixture = conftest.bridge.__wrapped__({})
    with pytest.raises(type(failure), match=str(failure)):
        next(fixture)
    proc.close.assert_called_once_with()


@pytest.mark.unit
@pytest.mark.parametrize("timeouts", [0, 1, 2])
def test_close_escalates_and_reaps_process(timeouts):
    bridge = BridgeProcess.__new__(BridgeProcess)
    bridge._closed = False
    bridge._readers = [Mock()]
    bridge._readers[0].is_alive.return_value = False
    bridge.proc = Mock()
    bridge.proc.stdin = io.StringIO()
    bridge.proc.stdout = io.StringIO()
    bridge.proc.stderr = io.StringIO()
    bridge.proc.wait.side_effect = [
        subprocess.TimeoutExpired("bridge", 1) for _ in range(timeouts)
    ] + [0]
    bridge.proc.poll.return_value = 0
    bridge.close(grace_timeout=1, terminate_timeout=1)
    assert bridge.proc.wait.call_count == timeouts + 1
    assert bridge.proc.terminate.call_count == (timeouts >= 1)
    assert bridge.proc.kill.call_count == (timeouts == 2)
    bridge._readers[0].join.assert_called_once_with(timeout=5)
    assert bridge.proc.stdin.closed
    assert bridge.proc.stdout.closed
    assert bridge.proc.stderr.closed
    bridge.close()
    assert bridge.proc.wait.call_count == timeouts + 1


@pytest.mark.unit
def test_inspector_fixture_restores_existing_module(monkeypatch):
    original = object()
    monkeypatch.setitem(sys.modules, "_jove_inspector", original)
    with pytest.MonkeyPatch.context() as patch:
        fixture = conftest.isolated_inspector.__wrapped__(patch)
        next(fixture)
        assert "_jove_inspector" not in sys.modules
        sys.modules["_jove_inspector"] = object()
        with pytest.raises(StopIteration):
            next(fixture)
    assert sys.modules["_jove_inspector"] is original


@pytest.mark.unit
def test_registry_fixture_restores_overwritten_entries():
    registry = conftest.REGISTRY
    original = registry.copy()
    fixture = conftest.isolated_registry.__wrapped__()
    next(fixture)
    registry.clear()
    registry["dummy"] = object()
    with pytest.raises(StopIteration):
        next(fixture)
    assert registry == original


@pytest.mark.integration
def test_kernel_uses_temporary_spec_and_current_interpreter(kernel):
    msg = kernel.request("list_kernelspecs")
    assert msg["result"]["kernelspecs"]["python3"]["display_name"] == "Jove test Python"
    msg = kernel.request(
        "execute",
        {
            "code": f"import sys; assert sys.executable == {sys.executable!r}",
            "cell": "env",
        },
    )
    assert msg["result"]["status"] == "ok"
