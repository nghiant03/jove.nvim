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
uv run --project python --locked --extra dev bash scripts/test.sh
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
- `.testdeps/mini.test` must exist at the repo root or `test.sh` exits 2.
- Lua tests must run with the project's Python env active (that's why CI wraps
  them in `uv run --project python`): the specs exercise the real `jupytext`
  binary, and `bridge_e2e_spec.lua` launches the real sidecar (it self-skips
  without `jupyter_client`/`ipykernel`).
- Bridge pytest needs a registered `python3` kernelspec
  (`python -m ipykernel install --user --name python3`); CI does this
  explicitly. Kernel startup is slow; the tests use 60-120s timeouts.

## Layout and architecture

- Lowest supported targets: Neovim 0.11, Python 3.10. CI (`.github/workflows/ci.yml`)
  runs lint plus both test suites; LSP warnings fail the build.
- Releases are cut by `.github/workflows/release.yml` (Actions > Release >
  Run workflow), which computes the next `v*` tag. Never tag by hand.
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
  flows); specs that need a real job inject fakes at `bridge_mod._impl`.
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
  Same idea for keymaps (`KNOWN_KEYMAP_KEYS`).
- jove conflicts with `jupytext.nvim` by design (both register
  `BufReadCmd *.ipynb`); the conflict check lives in `plugin/jove.lua` and
  `health.lua`.
- `doc/jove.txt` is generated from README.md by panvimdoc (on README changes
  to `main` and after each release); do not hand-edit it.

<!-- gitnexus:start -->
<!-- gitnexus:keep -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **jove.nvim** (291 symbols, 501 relationships, 19 execution flows).

> Index stale? Run `node .gitnexus/run.cjs analyze --index-only` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? Bootstrap with `npx`, `bunx`, or `pnpm dlx` — e.g. `bunx gitnexus@latest analyze` (npm 11 npx crash; #1939).

## Always Do

- **MUST run impact before editing.** Use `impact({target: "symbolName", direction: "upstream"})` or `node .gitnexus/run.cjs impact "symbolName" --direction upstream --repo .`; report callers, processes, and risk. Never substitute grep for graph analysis.
- **MUST analyze graph changes before committing.** Use `detect_changes({scope: "all"})` (MCP) or `node .gitnexus/run.cjs detect-changes --scope all --repo .` (CLI fallback). `partial: true` or `truncated: true` is not a clean check — a zero means unseen, not unaffected; re-run it. For regression review: `detect_changes({scope: "compare", base_ref: "main"})` or `node .gitnexus/run.cjs detect-changes --scope compare --base-ref "main" --repo .`.
- MUST warn on HIGH/CRITICAL `risk` pre-edit; never use `riskSharedAxes` to waive a HIGH/CRITICAL `risk` warning. Compare File/symbol: MCP File omits axes; Graph-RAG expands File.
- **MUST treat `risk: UNKNOWN` as unresolved, not as low.** An empty caller set is not evidence the symbol is unused — it can also mean the callers are not resolvable by the index (plain-object property access, dynamic dispatch, cross-language calls). `impact` pairs `UNKNOWN` with a `riskNote` saying so. Confirm with a text search before treating the symbol as safe to change or delete; do not proceed on the strength of a zero.
- **MUST use `query({search_query: "concept"})` for concepts/flows, `context({name: "symbolName"})` for a named symbol, or `impact` for blast radius, on read-only callers, dependencies, imports, or execution flow.** Graph first; text search only for empty/`UNKNOWN`/literals.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method before MCP/CLI impact analysis.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis, and never read `UNKNOWN` as an all-clear — it means the walk could not answer, which is the one verdict that requires confirming by other means.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit before MCP/CLI graph change analysis.

## Resources

| Resource | Use for |
| --- | --- |
| `gitnexus://repo/jove.nvim/context` | Codebase overview, check index freshness |
| `gitnexus://repo/jove.nvim/clusters` | All functional areas |
| `gitnexus://repo/jove.nvim/processes` | All execution flows |
| `gitnexus://repo/jove.nvim/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
| --- | --- |
| Understand architecture / "How does X work?" | `.agents/skills/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.agents/skills/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.agents/skills/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.agents/skills/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.agents/skills/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.agents/skills/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
