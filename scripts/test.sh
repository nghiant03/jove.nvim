#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d ".testdeps/mini.test" ]; then
  echo "error: .testdeps/mini.test missing; clone mini.test there first:" >&2
  echo "  git clone --depth 1 https://github.com/nvim-mini/mini.test .testdeps/mini.test" >&2
  exit 2
fi

command -v jupytext >/dev/null 2>&1 || {
  echo "error: jupytext not found on PATH (tests exercise the real binary)" >&2
  exit 2
}

if command -v timeout >/dev/null 2>&1; then
  timeout 600 nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run()'
else
  nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run()'
fi
