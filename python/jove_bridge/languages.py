"""Language-specific variable probes."""

from __future__ import annotations

import ast
import hashlib
from dataclasses import dataclass
from importlib.resources import files


@dataclass(frozen=True)
class Probe:
    language: str
    install: str
    query: str


ALIASES = {
    "python": "python",
    "python2": "python",
    "python3": "python",
}

REGISTRY: dict[str, Probe] = {}


def register(probe: Probe) -> None:
    REGISTRY[probe.language.strip().lower()] = probe


def lookup(language: str | None) -> Probe | None:
    key = (language or "").strip().lower()
    key = ALIASES.get(key, key)
    return REGISTRY.get(key)


def _source(filename: str) -> str:
    return files("jove_bridge").joinpath(filename).read_text(encoding="utf-8")


def _python_install(source: str) -> str:
    return ast.unparse(
        ast.Call(
            func=ast.Name(id="exec", ctx=ast.Load()),
            args=[
                ast.Constant(value=_source("python_install.py")),
                ast.Dict(
                    keys=[ast.Constant(value="source")],
                    values=[ast.Constant(value=source)],
                ),
            ],
            keywords=[],
        )
    )


_PYTHON_SOURCE = _source("python_inspector.py")
_PYTHON_REVISION = hashlib.sha256(_PYTHON_SOURCE.encode()).hexdigest()[:16]
PYTHON = Probe(
    "python", _python_install(_PYTHON_SOURCE), _source("python_query.py").strip()
)

register(PYTHON)
