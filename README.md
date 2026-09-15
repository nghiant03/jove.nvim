# jove.nvim

> **Jupyter notebooks, edited natively in Neovim.**
> *Jove — /dʒoʊv/, as in Jupiter.*

Edit Jupyter `.ipynb` notebooks in Neovim as if they were native Python
buffers — real LSP/copilot/treesitter, a first-party kernel client, inline
cell outputs, and proper round-tripping to disk. No otter, no quarto, no
molten, no temp files, no lost outputs.

<!-- panvimdoc-ignore-start -->

[![CI](https://github.com/nghiant03/jove.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/nghiant03/jove.nvim/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Jupyter](https://img.shields.io/badge/Jupyter-.ipynb-F37626?logo=jupyter&logoColor=white)](https://jupyter.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

<!-- panvimdoc-ignore-end -->

## Features

- **Native buffers** — notebooks open as ordinary Python buffers; pyright,
  ruff, copilot, treesitter and git tooling attach like any other file.
- **Built-in kernel client** — a first-party Python bridge starts and
  supervises one kernel per notebook; if it dies, it restarts automatically.
  No molten, no browser.
- **Inline outputs** — text, tables, tracebacks and images (PNG/JPEG via
  `snacks.image`) render in bordered blocks below each cell, with signs and a
  spinner for queued/running/done state.
- **True round-tripping** — session outputs and execution counts merge back
  into the `.ipynb` on save; cleared outputs stay cleared; reload treats disk
  as truth.
- **Cell ergonomics** — `ic`/`ac` cell text-objects, `[c`/`]c` cell motions,
  cell borders, per-cell execution counts and elapsed time.
- **Tooling** — variable inspector sidebar, notebook table of contents, and a
  kernel info panel with sessions and installed kernelspecs.

## How it works

```
.ipynb on disk (JSON)
   │  open ── jupytext ─▶  normal buffer, filetype=python
   │                        pyright / ruff / copilot / treesitter attach natively
   │                        run cells via a background Jupyter kernel
   │                        cell status signs + inline cell outputs
   │  save ── jupytext ─▶  .ipynb on disk (outputs persisted in the JSON)
```

- Notebooks open as ordinary Python buffers — LSP, completion, formatting,
  and git tooling all work on them like any other file.
- On save, the outputs you produced this session are merged back into the
  `.ipynb`, so they survive to disk and reappear when you reopen the notebook.
- Kernel execution runs through a small Python helper that jove starts and
  supervises per notebook; if it dies, it is restarted automatically and the
  kernel comes back with it.
- The kernel is chosen from the notebook's own metadata, then the active
  Python environment, then an interactive picker of installed kernels.

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
`jupytext` binary, the Python interpreter and its dependencies, the optional
`snacks.image` integration, and a conflict check against `jupytext.nvim`
(it also warns if it detects molten, which jove no longer uses).

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)

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

With any other plugin manager, load jove at startup (not lazily) and call
`require("jove").setup({...})` in your config.

**Do not load `jupytext.nvim` alongside jove** — both register `BufReadCmd`
on `*.ipynb`. Jove detects it and refuses to register its handlers with a
warning; remove one of the two plugins.

### Python environment

The kernel needs a Python interpreter that can `import jupyter_client` and
`ipykernel`. Jove picks one automatically, in this order:

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

## Configuration

Full option list with defaults:

```lua
require("jove").setup({
  jupytext = "jupytext",        -- path to the jupytext binary
  bridge_python = "python3",    -- fallback Python for the kernel helper
                                -- (see "Python environment" above for the
                                -- conda/venv precedence)
  auto_kernel = true,           -- start kernel automatically on open
  auto_import_outputs = true,   -- render persisted outputs on open/reload
  auto_export_outputs = true,   -- merge session outputs into the .ipynb on save
  persist_exec_counts = true,   -- persist kernel execution counts into the .ipynb
  elapsed = true,               -- show per-cell elapsed execution time
  auto_reload = false,          -- auto-reload when the .ipynb changes on disk
  cell_motions = true,          -- map [c / ]c cell motions
  signs = {
    queued = "…",               -- gutter sign: queued for execution
    running = "▶",              -- gutter sign: currently running
    ok = "✓",                   -- gutter sign: finished successfully
    error = "✗",                -- gutter sign: finished with an error
  },
  output = {
    max_lines = 50,             -- inline output truncation limit
    images = true,              -- render images via snacks.image when available
    header = true,              -- draw the Output block's `┌─ Out[n] ─┐` top frame; false renders content + guide rail only
    guide = "▎ ",               -- per-line inner output rail (between the left border and the text); false disables it
    inside_border = false,      -- render output inside the cell border instead of its own bordered block below it
    hl = nil,                   -- output background tint: hl group name (string, linked) or attrs table; nil disables
  },
  variables = {
    auto_refresh = true,        -- refresh the variables inspector on idle
    width = 32,                 -- inspector window width
  },
  ui = {
    conceal_headers = true,     -- conceal # %% cell headers (front matter is hidden by stripping it on read)
    active_cell = true,         -- highlight the active cell
    exec_counts = true,         -- show per-cell execution counts
    elapsed = true,             -- show per-cell elapsed time
    borders = true,             -- draw a closing line below each cell
    border_hl = nil,            -- cell border highlight: an hl group name (string, linked) or attrs table (e.g. { fg = "#ff9e64" }); nil keeps the default Comment link
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

## Usage

### Commands

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
| `:JoveVariables` | Toggle the variable inspector sidebar |
| `:JoveKernelInfo` | Show kernel panel (current session, running kernels, installed kernelspecs) |
| `:JoveToc` | Show a table of contents for the current notebook |

Use `:checkhealth jove` to verify dependencies, versions, and conflicts.

### Keymaps and motions

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

### Execution and status

Cells run one at a time per notebook: a queued cell gets the `queued` sign,
then `running` (with a spinner on the cell), then `ok` or `error`. Errors
keep the `✗` sign and render the traceback. `:JoveInterrupt` stops the
running execution.

When enabled (`ui.exec_counts` / `ui.elapsed`), each cell shows its kernel
execution count and how long its last run took; counts are also persisted
into the `.ipynb` on save (`persist_exec_counts`).

Add a kernel status component to your statusline:

```lua
require("jove.ui.panel").status()  -- e.g. "⚡ python3 · busy"
```

It shows the kernelspec name and busy/idle state, and returns an empty
string when no kernel is running.

`:JoveKernelInfo` opens a centered float with three sections: the current
session (kernel, status, and queue length), every running kernel across all
open notebooks, and the installed kernelspecs (fetched asynchronously through
the bridge, reusing a live kernel when one is available).

## Output rendering

Outputs render as a dedicated bordered `Out` block below each cell, attached
to the cell border so the two stay visually separated:

```
╭─ ○ Cell 5 ────────────────╮       <- JoveCellBorder
[code lines]
╰────────────────────────────╯       <- JoveCellBorder
┌─ Out[3] ─────────────────────┐     <- JoveOutputBorder (distinct group)
│ ▎ accuracy             │
│ ▎ 0.74      0.74  …     │
└────────────────────────────────┘     <- JoveOutputBorder
```

- The Code cell border (`JoveCellBorder`) wraps the **code only**; the Output
  block is its own bordered region with the **distinct** `JoveOutputBorder`
  group so cell vs output can be themed independently and never visually merge.
- Effect: the output sits directly below the code border without being
  contained inside it (set `output.inside_border = true` for the older
  in-box behaviour).
- The Output top frame carries the `Out[n]` label and is the same role the
  `└─ Out[n]` rule used to play; `output.header = false` skips the entire
  Output frame and renders just content with the guide rail.
- Every content row carries a `▎ ` guide rail between its left and right
  border rails (`JoveOutputGuide` → `Comment`, or `JoveOutputGuideError` →
  `DiagnosticError` for error blocks). Customize with `output.guide = "│ "`,
  or disable with `output.guide = false`.
- `output.inside_border = true` restores the original layout (output rendered
  between the cell body and its closing border — no Output frame).
- `output.hl` optionally tints the block's full window-width background: an hl
  group name (`string`, linked to `JoveOutput`) or attrs table (e.g.
  `{ bg = "#2a2a3a" }`). nil disables the tint.
- `:JoveToggleOutput` folds/unfolds the current cell's output.
- `:JoveOpenOutput` opens the current cell's output in a scrollable float
  (close with `q` or `<Esc>`); the float shows the raw, undecorated lines.
- Output longer than `output.max_lines` is truncated inline, with a trailer
  pointing at `:JoveOpenOutput` for the full view.
- Error tracebacks are shown as plain text.
- Image outputs (PNG/JPEG) render inline via `snacks.image` when available;
  otherwise a text placeholder is shown.

Highlight groups: `JoveCellBorder` (cell frame), `JoveOutputBorder` (Output
frame, distinct from the cell frame), `JoveOutputHeader`,
`JoveOutputGuide`, `JoveOutputGuideError` and `JoveOutput` (all
user-overridable via `nvim_set_hl`).

## Output persistence

jove persists outputs natively in the `.ipynb` — no import/export step. On
save, session outputs are merged into the notebook JSON, matched to cells by
their content.

The exact semantics:

- **Untouched cells** keep whatever jupytext preserved on disk, including
  their original execution counts.
- **Cells re-run this session** get their disk outputs replaced by the
  session outputs along with the kernel execution count; with
  `persist_exec_counts = false` (or when the kernel reports no count) the
  count is written as `null`.
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

## Migrating from 0.1 (molten-based)

jove 0.2 replaced molten with a first-party kernel bridge:

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

## Contributing

Bug reports, feature requests and pull requests are welcome on
[GitHub](https://github.com/nghiant03/jove.nvim/issues).

## License

MIT — see [LICENSE](LICENSE).
