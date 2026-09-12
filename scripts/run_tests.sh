#!/usr/bin/env bash
# run_tests.sh: run the mini.test suite headless.
# Exits non-zero if any test case fails (mini.test's stdout reporter uses
# `:cquit 1` on failure, `:cquit 0` on success).
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

timeout 600 nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run()'
