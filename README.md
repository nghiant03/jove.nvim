# jove.nvim

Edit Jupyter `.ipynb` notebooks in Neovim as if they were native Python
buffers — real LSP/copilot/treesitter, a first-party kernel client, inline
cell outputs, and proper round-tripping to disk. No otter, no quarto, no
molten, no temp files, no lost outputs.

## How it works

```
.ipynb on disk (JSON)
   │  BufReadCmd ── jupytext CLI (async, via stdio, no temp files) ──▶
buffer  buftype=acwrite, filetype=python
   │  pyright / ruff / copilot / treesitter attach natively
   │  per-buffer bridge: python -m jove_bridge (JSON lines over stdio)
   │      └─ jupyter_client kernel: execute, streams outputs back as events
   │  cell status signs + inline virtual-line outputs
   │  BufWriteCmd ── jupytext --update, then session outputs merged ──▶
.ipynb on disk (JSON, outputs persisted)
```

The kernel client is first-party: jove spawns one Python sidecar process per
buffer that needs a kernel (`python -m jove_bridge`, newline-delimited JSON
over stdio — the wire contract is specified in
[PROTOCOL.md](PROTOCOL.md)). The sidecar wraps `jupyter_client` and manages
exactly one kernel: start, interrupt, restart, shutdown. If the bridge process
dies unexpectedly it is respawned automatically (up to 3 attempts with
increasing backoff) and restarts the last kernelspec.

The kernelspec is resolved from the notebook's `metadata.kernelspec.name`,
falling back to the active environment's name, and finally to a `vim.ui.select`
picker of installed kernelspecs.

## Requirements

- Neovim ≥ 0.11
- [`jupytext`](https://github.com/mwouts/jupytext) on `$PATH` (conversion-only
  usage — editing and saving notebooks without running cells — needs just this)
- For kernel execution: a Python interpreter with `jupyter_client` and
  `ipykernel` installed:

  ```sh
  pip install jupyter_client ipykernel
  ```

- [`snacks.nvim`](https://github.com/folke/snacks.nvim) (optional) — its
  `image` module renders inline PNG/JPEG outputs. Without it, image outputs
  render as text placeholders.

Run `:checkhealth jove` to verify all of the above: the Neovim version, the
`jupytext` binary, the Python interpreter and its dependencies, a bridge
sidecar import probe, the optional `snacks.image` integration, and a conflict
check against `jupytext.nvim` (it also warns if it detects molten, which jove
no longer uses).

## Install (lazy.nvim)

```lua
{
  "nghiant03/jove.nvim",
  lazy = false,   -- BufReadCmd must be registered before the .ipynb is opened
  opts = {
    auto_kernel = true,
    keymap = {
      run_cell  = "<leader>x",
      next_cell = "]h",
      prev_cell = "[h",
    },
  },
}
```

> `opts = {}` (or `config = true`) is **required** — without it lazy.nvim
> never calls `require("jove").setup(...)`. The `BufReadCmd`/`BufWriteCmd`
> handlers are installed from `plugin/jove.lua` at startup either way, but
> you'll lose the `ic`/`ac` cell text-objects, `[c`/`]c` cell motions, all
> `keymap = {}` bindings, and the cell status signs/spinner.

**Do not load `jupytext.nvim` alongside jove** — both register `BufReadCmd`
on `*.ipynb`. Jove detects it and refuses to register its handlers with a
warning; remove one of the two plugins.

### Python environment

The bridge needs a Python interpreter that can `import jupyter_client` and
`ipykernel`. Jove picks it per spawn, in this order:

1. `$CONDA_PREFIX/bin/python` (active conda env)
2. `$VIRTUAL_ENV/bin/python` (active virtualenv)
3. your configured `bridge_python` value (default `"python3"`)

If you launch Neovim from outside the environment that has the Jupyter
stack, set the fallback explicitly:

```lua
opts = {
  bridge_python = "/home/you/envs/jupyter/bin/python",
}
```

If `jupytext` lives in a conda env that isn't on `$PATH` for the nvim
process, either prepend that env's `bin/` to `vim.env.PATH` early in your
`init.lua` or point `opts.jupytext` at the absolute binary path.

## Commands

| Command | Action |
|---|---|
| `:JoveRunCell` | Run current notebook cell |
| `:JoveRunAbove` | Run all notebook cells above the cursor |
| `:JoveRunAll` | Run all notebook cells |
| `:JoveRunSelection` | Run the visual selection as one unit |
| `:JoveRunCellAndAdvance` | Run the current cell and jump to the next |
| `:JoveNextCell` | Jump to next notebook cell |
| `:JovePrevCell` | Jump to previous notebook cell |
| `:JoveInitKernel` | Start a kernel for the current notebook |
| `:JoveSelectKernel` | Pick a kernelspec for the current notebook (replaces running kernel) |
| `:JoveInterrupt` | Interrupt the running execution |
| `:JoveRestartKernel` | Restart the current notebook kernel |
| `:JoveShutdownKernel` | Shut down the current notebook kernel and bridge |
| `:JoveToggleOutput` | Show/hide rendered outputs of the current cell |
| `:JoveOpenOutput` | Open the current cell's outputs in a float |
| `:JoveClearOutput` | Clear outputs of the current cell |
| `:JoveClearOutputs` | Clear all rendered outputs in this buffer |
| `:JoveReload` | Reload the current notebook buffer from disk |

Use `:checkhealth jove` to verify dependencies, versions, and conflicts.

## Keymaps and motions

On jove buffers (python, julia, r, javascript filetypes backed by an
`.ipynb`):

- `ic` / `ac` cell text-objects (operator-pending and visual modes) — always
  on, no extra plugin needed.
- `[c` / `]c` cell motions (normal mode) — on by default; disable with
  `cell_motions = false`.
- Everything under `keymap = {}` is opt-in; all bindings default to disabled.

```lua
opts = {
  keymap = {
    run_cell        = "<leader>x",  -- normal: run cell under cursor
    run_and_advance = "<leader>X",  -- normal: run cell, jump to next
    run_selection   = "<leader>xx", -- visual: run selection as one unit
    next_cell       = "]h",
    prev_cell       = "[h",
  },
}
```

## Configuration

Full option list with defaults:

```lua
require("jove").setup({
  jupytext = "jupytext",           -- path to the jupytext binary
  bridge_python = "python3",       -- fallback interpreter for the bridge
                                   -- (see "Python environment" above for the
                                   -- conda/venv precedence)
  auto_kernel = true,              -- start bridge + kernel on open
  auto_import_outputs = true,      -- render persisted outputs on open/reload
  auto_export_outputs = true,      -- merge session outputs into the .ipynb on save
  auto_reload = false,             -- auto-reload when the .ipynb changes on disk
  cell_motions = true,             -- map [c / ]c cell motions
  signs = {
    queued = "…",                  -- gutter sign: queued for execution
    running = "▶",                 -- gutter sign: currently running
    ok = "✓",                      -- gutter sign: finished successfully
    error = "✗",                   -- gutter sign: finished with an error
  },
  output = {
    max_lines = 50,                -- inline output truncation limit
    images = true,                 -- render images via snacks.image when available
  },
  keymap = {
    run_cell = false,
    run_and_advance = false,
    run_selection = false,
    next_cell = false,
    prev_cell = false,
  },
})
```

## Execution and status

Cells run through a per-buffer serial queue over the buffer's kernel: a
queued cell gets the `queued` sign, then `running` (with a spinner on the
cell), then `ok` or `error`. Errors keep the `✗` sign and render the
traceback (ANSI-stripped). `:JoveInterrupt` stops the running execution.

Add a kernel status component to your statusline:

```lua
require("jove.ui.panel").status()  -- e.g. "⚡ python3 · busy"
```

It shows the kernelspec name and busy/idle state, and returns an empty
string when no kernel is running.

## Output rendering

Outputs render inline as virtual lines below each cell:

- `:JoveToggleOutput` folds/unfolds the current cell's output.
- `:JoveOpenOutput` opens the current cell's output in a scrollable float
  (close with `q` or `<Esc>`).
- Output longer than `output.max_lines` is truncated inline, with a trailer
  pointing at `:JoveOpenOutput` for the full view.
- Error tracebacks are shown with ANSI escapes stripped.
- Image outputs (PNG/JPEG) render inline via `snacks.image` when available;
  otherwise a text placeholder is shown.

## Output persistence

jove persists outputs natively in the `.ipynb` — no import/export step. On
save, session outputs are merged into the notebook JSON, matched to cells by
content hash (jupytext's `py:percent` round-trip drops cell ids, so a hash of
the normalized cell source is the stable identity).

The exact semantics:

- **Untouched cells** keep whatever jupytext preserved on disk, including
  their original execution counts.
- **Cells re-run this session** get their disk outputs replaced by the
  session outputs (execution counts are nulled — the session result carries
  no count).
- **Cleared outputs stay cleared**: deleting a cell's outputs and saving
  persists `outputs: []`, so they don't resurrect on reload.
- **Reload treats disk as truth**: `:JoveReload` (or an external change with
  `auto_reload = true`) re-imports outputs from the file; session-only
  outputs that were never saved are dropped.
- **One-time reformat**: the first save that merges session outputs
  re-encodes the whole notebook as compact JSON, so that diff can look large
  once. Subsequent saves only rewrite cells you actually ran or cleared.

Known limitation: two cells with identical content share a content hash, so
outputs and status signs attach to the first of them. Edit one of the cells
to differentiate them.

## Comparison

| | jove.nvim | jupytext.nvim | quarto-nvim + otter | jupynium.nvim |
|---|---|---|---|---|
| Native python LSP | yes | yes | proxy/chunked | yes |
| Kernel execution | built-in (Python bridge) | no | via molten | via browser |
| Inline outputs | built-in (virtual lines + floats) | no | via molten | via browser |
| No temp files | yes | no (writes sidecar) | yes | yes |
| Output persistence | yes (JSON merge) | no | manual | yes |
| Browser required | no | no | no | yes |
| Scope | small | small | wide (`.qmd`) | wide |

## Migrating from v1 (molten-based)

jove v2 replaced molten with a first-party kernel bridge:

- Remove `benlubas/molten-nvim` from your plugin dependencies and delete any
  `Molten*` autocmds or keymaps you copied from molten's README (e.g.
  `BufAdd *.ipynb` → `MoltenInit`). jove initializes its own kernel when
  `auto_kernel = true`.
- There is no `MoltenInit` equivalent to run — `:JoveInitKernel` (or just
  opening the notebook) is enough.
- `:JoveImportOutputs` / `:JoveExportOutputs` are gone. Outputs are read
  from and merged into the `.ipynb` automatically; see
  [Output persistence](#output-persistence).

## Non-goals

- Markdown prose rendering between cells (markdown cells stay as
  `# %% [markdown]` comment blocks).
- Browser sync à la jupynium.
- Quarto/`.qmd` support — jove is scoped to Jupyter notebooks.
- Reimplementing `jupytext` format conversions in Lua.

## License

MIT
