# AGENTS.md

Guidance for agents working in this repository.

## What this is

`jove.nvim` is a Neovim plugin that edits Jupyter `.ipynb` notebooks as
native buffers, plus a Python sidecar that owns one Jupyter kernel per notebook 
and speaks a JSON-lines protocol over stdio with the Lua client.

## Commands

Lua plugin tests:

```sh
git clone --depth 1 https://github.com/nvim-mini/mini.test .testdeps/mini.test
bash scripts/test.sh unit
bash scripts/test.sh component
uv sync --project python --locked --extra dev --python 3.12
uv run --project python --locked --extra dev python -m ipykernel install --user --name python3 --display-name "Python 3 (ipykernel)"
JOVE_TEST_STRICT=1 uv run --project python --locked --extra dev bash scripts/test.sh adapter
JOVE_TEST_STRICT=1 uv run --project python --locked --extra dev bash scripts/test.sh e2e
uv run --project python --locked --extra dev bash scripts/test.sh
```

Run a single spec:

```sh
nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run_file("tests/spec/cell_spec.lua")'
```

Bridge tests / lint / format:

```sh
uv run --project python --locked --extra dev python -m pytest -q -m unit
uv run --project python --locked --extra dev python -m pytest -q -m integration
uv run --project python --locked --extra dev python -m pytest -q
uv run --project python --locked --extra dev ruff check python
uv run --project python --locked --extra dev ruff format --check python
stylua .
selene .
```

Notes:
- `.testdeps/mini.test` must exist at the repo root or `test.sh` exits 2.
- `scripts/test.sh [all|unit|component|adapter|e2e]` defaults to `all`, or
  `JOVE_TEST_TIER` when set. The minimal init filters discovery, keeping 
  specs flat in `tests/spec/`.
- Unit files: `ansi`, `lang`, `mime`, `output_render`, `persist`,
  `webview_document`, `webview_transport`. Adapter files: `buffer`, `convert`,
  `persist_adapter`, `webview_terminal`. Files named `*_e2e_spec.lua` are e2e;
  remaining files are component.
- Only adapter/e2e/all need the project's Python environment and real `jupytext`.
  Lua real-kernel tests need a registered `python3` kernelspec. CI runs fast Lua tiers
  before Python setup, then adapter/e2e separately with `JOVE_TEST_STRICT=1` to
  fail on missing real-bridge prerequisites.
- Python pytest uses strict registered `unit` and `integration` markers. Keep
  in-process tests separate from subprocess/kernel coverage; the unfiltered
  command still runs both. Python integration fixtures supply a temporary
  `python3` kernelspec. Kernel startup can need 60-120s timeouts.
- Shared Lua fake ownership lives in `tests/helpers/bridge.lua`.
  Specs own cleanup of their buffers/windows/files and any additional patches.
- Python subprocess ownership lives in `python/tests/support.py`; reuse the
  `bridge`/`kernel` fixtures in `python/tests/conftest.py` for cleanup and reader
  health checks.

## Layout and architecture

- Lowest supported targets: Neovim 0.11, Python 3.10. CI (`.github/workflows/ci.yml`)
  runs lint plus both test suites; LSP warnings fail the build.
- `plugin/jove.lua` - startup entry: registers `BufReadCmd`/`BufWriteCmd`/
  `FileChangedShell` on `*.ipynb` and all `:Jove*` commands. Config lives in
  `lua/jove/init.lua` (`require("jove").setup`), NOT here.
- `lua/jove/buffer.lua` - read/write/reload handlers. Conversion to/from
  `.ipynb` is async via `convert.lua` (jupytext CLI); completion state
  bookkeeping is scheduled onto the main loop.
- `lua/jove/lang.lua` - language registry: kernelspec language -> filetype,
  jupytext percent-format stem (`py`/`jl`/`R`/`js`/`ts`), comment leader, and
  known LSP server names. Extend with `require("jove.lang").register(id, spec)`.
  The resolved id is cached per buffer as `state.lang`.
- `lua/jove/lsp.lua` - opt-in LSP auto-attach (`lsp.auto_attach` +
  `lsp.servers[lang]`); starts only servers with an existing
  `vim.lsp.config` entry, never invents cmd/root_dir.
- `lua/jove/state.lua` - per-buffer state registry (`state.get(buf)`), cleaned
  up on BufWipeout. Other modules attach their slots (`cells`, `kernel`,
  `exec`, `outputs`, `front_matter`) to this table; the slot types
  (`jove.CellCache`, `jove.KernelEntry`, `jove.ExecState`, `jove.OutputEntry`)
  are declared as fields on `jove.BufferState` so LuaLS can follow them.
- `lua/jove/bridge.lua` - JSON-lines client to `python -m jove_bridge`;
  `kernel.lua` creates one bridge handle (one process, one kernel) per buffer.
- `lua/jove/persist.lua` - merges session outputs into the `.ipynb` JSON on
  write and replays them on read. Outputs are matched to cells by **content
  hash** because jupytext py:percent round-trips drop cell ids.
- `lua/jove/output/`, `lua/jove/mime.lua`, `lua/jove/ansi.lua`,
  `lua/jove/ui/` - rendering (inline extmark blocks, optional images via
  `snacks.image`). `output/init.lua` owns storage and extmark placement; the
  pure chunks-to-virt_lines pipeline is `output/render.lua` and the
  full-output float viewer is `output/float.lua`. The terminal-browser webview
  entry point `lua/jove/webview/init.lua` delegates to `lua/jove/webview/`
  (MIME-to-HTML rendering, `_impl` test seam, Kitty graphics relay,
  terminal-buffer lifecycle). `ui/sidebar.lua` is the single tabbed pane hosting
  the variables, kernel info, and TOC views; number keys switch tabs.
  `ansi.lua` owns all terminal escape handling: `strip` (drop sequences),
  `cr_concat` (carriage-return folding), and `parse` (map SGR styling to
  highlight spans, stateful across stream events).
- `python/jove_bridge/` - stdio sidecar: `__main__.py` (envelope loop, bounded
  writer queue), `session.py` (method dispatch + iopub/shell routing),
  `kernel.py` (thin jupyter_client wrapper raising `KernelError(code, msg)`).
  The package is intentionally unversioned; the plugin versions via git tags.

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
  topic, named `<module>_spec.lua` (`<module>_e2e_spec.lua` for cross-process
  flows); component specs inject fake jobs at `bridge_mod._impl`.
- Front matter (`# ---` fenced jupytext header, comment leader per language)
  is stripped from the buffer on read and restored on write (`buffer.lua`
  `split_front`); cell markers are `<comment> %%` (e.g. `# %%` for
  python/julia/r, `// %%` for javascript/typescript) and concealed when
  `ui.conceal_headers` is on.
- Wire protocol details that matter: output events can arrive after the
  execute reply (10s late-iopub grace in the sidecar); each execution gets a
  unique wire key so reruns invalidate the previous run's output routing;
  binary MIME payloads are base64; stream text may carry ANSI SGR codes
  (e.g. Keras 3 `model.summary()`) which `ansi.parse` renders as highlight
  groups, while error tracebacks are stripped; persistence keeps the raw
  bytes either way.
- The Python bridge deliberately uses threads only (main + one poll worker +
  writer), no asyncio.
- Adding a config option? Update `M.config`, `KNOWN_KEYS` (and the
  `---@class jove.Config` docs) in `lua/jove/init.lua`, plus the README table.
- Keymaps are `<Plug>`-only: there is no setup-time keymap config (the old
  `keymap` option is deprecated). New actions go into `lua/jove/keymaps.lua`
  as a `<Plug>(Jove...)` mapping with a which-key `desc`, plus the README
  `<Plug>` table and a `:Jove` subcommand in `commands.lua` if applicable.
- jove conflicts with `jupytext.nvim` by design (both register
  `BufReadCmd *.ipynb`); the conflict check lives in `plugin/jove.lua` and
  `health.lua`.
- `doc/jove.txt` is generated from README.md by panvimdoc (on README changes
  to `main` and after each release); do not hand-edit it.
