import json
import os
import sys

import pytest

from jove_bridge.languages import REGISTRY

from .support import BridgeProcess


@pytest.fixture(scope="session")
def kernel_environment(tmp_path_factory):
    root = tmp_path_factory.mktemp("jupyter")
    spec_dir = root / "kernels" / "python3"
    spec_dir.mkdir(parents=True)
    spec = {
        "argv": [sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"],
        "display_name": "Jove test Python",
        "language": "python",
    }
    (spec_dir / "kernel.json").write_text(json.dumps(spec), encoding="utf-8")
    return {**os.environ, "JUPYTER_PATH": str(root)}


@pytest.fixture
def bridge(kernel_environment):
    proc = BridgeProcess(env=kernel_environment)
    try:
        proc.wait_ready()
        yield proc
    finally:
        proc.close()
        proc.assert_healthy()


@pytest.fixture
def kernel(bridge):
    bridge.start_kernel("python3")
    return bridge


@pytest.fixture
def isolated_inspector(monkeypatch):
    monkeypatch.delitem(sys.modules, "_jove_inspector", raising=False)
    yield
    sys.modules.pop("_jove_inspector", None)


@pytest.fixture
def isolated_registry():
    original = REGISTRY.copy()
    try:
        yield
    finally:
        REGISTRY.clear()
        REGISTRY.update(original)
