# AGENTS.md

Guidance for agents working in this repository.

## What this is

`jove.nvim` is a Neovim plugin (Lua) that edits Jupyter `.ipynb` notebooks as
native buffers, plus a Python sidecar (`python/jove_bridge`) that owns one
Jupyter kernel per notebook and speaks a JSON-lines protocol over stdio with
the Lua client.

## Commands

Lua plugin tests (mini.test, headless Neovim, requires real `jupytext` on PATH):

```sh
git clone --depth 1 https://github.com/nvim-mini/mini.test .testdeps/mini.test  # one-time
uv run --project python --locked --extra dev bash scripts/run_tests.sh
```

Run a single spec:

```sh
nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run({ file = "tests/spec/cell_spec.lua" })'
```

Bridge tests / lint / format:

```sh
uv run --project python --locked --extra dev python -m pytest -q
uv run --project python --locked --extra dev ruff check python
uv run --project python --locked --extra dev ruff format --check python
stylua .        # check with: stylua --check .
selene .        # std = neovim (see neovim.yml / selene.toml)
```

Notes:
- `.testdeps/mini.test` must exist at the repo root or `run_tests.sh` exits 2.
- Lua tests must run with the project's Python env active (that's why CI wraps
  them in `uv run --project python`): the specs exercise the real `jupytext`
  binary, and `bridge_e2e_spec.lua` launches the real sidecar (it self-skips
  without `jupyter_client`/`ipykernel`).
- Bridge pytest needs a registered `python3` kernelspec
  (`python -m ipykernel install --user --name python3`); CI does this
  explicitly. Kernel startup is slow; the tests use 60-120s timeouts.

## Layout and architecture

- `plugin/jove.lua` - startup entry: registers `BufReadCmd`/`BufWriteCmd`/
  `FileChangedShell` on `*.ipynb` and all `:Jove*` commands. Config lives in
  `lua/jove/init.lua` (`require("jove").setup`), NOT here.
- `lua/jove/buffer.lua` - read/write/reload handlers. Conversion to/from
  `.ipynb` is async via `convert.lua` (jupytext CLI); completion state
  bookkeeping is scheduled onto the main loop.
- `lua/jove/state.lua` - per-buffer state registry (`state.get(buf)`), cleaned
  up on BufWipeout. Other modules attach their slots (`cells`, `kernel`,
  `exec`, `outputs`, `front_matter`) to this table.
- `lua/jove/bridge.lua` - JSON-lines client to `python -m jove_bridge`;
  `kernel.lua` creates one bridge handle (one process, one kernel) per buffer.
- `lua/jove/persist.lua` - merges session outputs into the `.ipynb` JSON on
  write and replays them on read. Outputs are matched to cells by **content
  hash** because jupytext py:percent round-trips drop cell ids.
- `lua/jove/output.lua`, `lua/jove/mime.lua`, `lua/jove/ui/` - rendering
  (inline extmark blocks, optional images via `snacks.image`), variables
  inspector, kernel info panel, TOC.
- `python/jove_bridge/` - stdio sidecar: `__main__.py` (envelope loop, bounded
  writer queue), `session.py` (method dispatch + iopub/shell routing),
  `kernel.py` (thin jupyter_client wrapper raising `KernelError(code, msg)`).

## Conventions and gotchas

- Lua: stylua with 100-col width, 2-space indent, double quotes. EmmyLua
  annotations (`---@class jove.*`, `---@param`, `---@return`) on all public
  functions; modules follow the `local M = {} ... return M` pattern.
- Modules expose `_`-prefixed fields/functions as test seams (e.g.
  `bridge._impl` lets specs inject fake `jobstart`/`jobsend`/`jobstop`;
  `init._reset_shim_state`). Timing knobs like `M.respawn_backoff_ms` and
  `M.ready_timeout_ms` are module-level so tests can shorten them. Do not use
  these outside tests.
- Test specs use mini.test: `MiniTest.new_set` with hooks, nested sets by
  topic; specs that need a real job inject fakes at `bridge_mod._impl`.
- Front matter (`# ---` fenced jupytext header) is stripped from the buffer on
  read and restored on write (`buffer.lua` `split_front`); cell markers are
  `# %%` (concealed when `ui.conceal_headers` is on).
- Wire protocol details that matter: output events can arrive after the
  execute reply (10s late-iopub grace in the sidecar); each execution gets a
  unique wire key so reruns invalidate the previous run's output routing;
  binary MIME payloads are base64; error tracebacks carry ANSI codes which the
  Lua renderer strips but persistence keeps.
- The Python bridge deliberately uses threads only (main + one poll worker +
  writer), no asyncio.
- Adding a config option? Update `M.config`, `KNOWN_KEYS` (and the
  `---@class jove.Config` docs) in `lua/jove/init.lua`, plus the README table.
  Same idea for keymaps (`KNOWN_KEYMAP_KEYS`).
- jove conflicts with `jupytext.nvim` by design (both register
  `BufReadCmd *.ipynb`); the conflict check lives in `plugin/jove.lua` and
  `health.lua`.
- `doc/jove.txt` is generated from README.md by panvimdoc on version tags; do
  not hand-edit it.
