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


@dataclass(frozen=True)
class DisplayProbe:
    """Kernel-specific code that publishes one application/json MIME result."""

    language: str
    implementation: str
    resource: str

    @property
    def code(self) -> str:
        return _source(self.resource)


ALIASES = {
    "python": "python",
    "python2": "python",
    "python3": "python",
}

REGISTRY: dict[tuple[str, str], Probe | DisplayProbe] = {}


def _language_key(language: str | None) -> str:
    key = (language or "").strip().lower()
    return ALIASES.get(key, key)


def register(probe: Probe | DisplayProbe) -> None:
    implementation = probe.implementation if isinstance(probe, DisplayProbe) else ""
    REGISTRY[_language_key(probe.language), implementation.strip().lower()] = probe


def lookup(
    language: str | None, implementation: str | None = None
) -> Probe | DisplayProbe | None:
    key = _language_key(language)
    impl = (implementation or "").strip().lower()
    return REGISTRY.get((key, impl)) or REGISTRY.get((key, ""))


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
register(DisplayProbe("r", "IRkernel", "r_inspector.R"))
register(DisplayProbe("julia", "ijulia", "julia_inspector.jl"))
