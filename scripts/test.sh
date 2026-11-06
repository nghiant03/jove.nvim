#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."

tier="${1:-${JOVE_TEST_TIER:-all}}"
case "$tier" in
  all|unit|component|adapter|e2e) ;;
  *) echo "usage: scripts/test.sh [all|unit|component|adapter|e2e]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: scripts/test.sh [all|unit|component|adapter|e2e]" >&2
  exit 2
fi
export JOVE_TEST_TIER="$tier"

if [ ! -d ".testdeps/mini.test" ]; then
  echo "error: .testdeps/mini.test missing; clone mini.test there first:" >&2
  echo "  git clone --depth 1 https://github.com/nvim-mini/mini.test .testdeps/mini.test" >&2
  exit 2
fi

if [[ "$tier" == all || "$tier" == adapter || "$tier" == e2e ]]; then
  command -v jupytext >/dev/null 2>&1 || {
    echo "error: jupytext not found on PATH (selected tests exercise the real binary)" >&2
    exit 2
  }
fi

if command -v timeout >/dev/null 2>&1; then
  timeout 600 nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run()'
else
  nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run()'
fi
