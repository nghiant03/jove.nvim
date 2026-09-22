# jove.nvim

> **Jupyter notebooks, edited natively in Neovim.**
> *Jove — /dʒoʊv/, as in Jupiter.*

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

## Requirements

- Neovim ≥ 0.11
- [`jupytext`](https://github.com/mwouts/jupytext)
- A Python interpreter with `jupyter_client` and
  `ipykernel` installed:
- [`snacks.nvim`](https://github.com/folke/snacks.nvim) (optional): Image rendering 

Run `:checkhealth jove` to verify the requirements

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)

```lua
{
  "nghiant03/jove.nvim",
  lazy = false,
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
> [!important]
> **Do not** load `jupytext.nvim` with jove since both register `BufReadCmd`
> on `*.ipynb`. Jove detects it and refuses to register its handlers with a
> warning.

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
    image_max_width = 80,       -- cap rendered image width in terminal cells (nil disables)
    image_max_height = 40,      -- cap rendered image height in terminal cells (nil disables)
    header = true,              -- draw the Output block's `┌─ Out[n] ─┐` top frame; false renders content + guide rail only
    guide = "▎ ",               -- per-line inner output rail (before the text); false disables it
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
    window_mode = "vsplit",     -- how to open the variables inspector, kernel info panel, and output viewer: "float", "vsplit", or "hsplit"
  },
  keymap = {
    run_cell = false,
    run_and_advance = false,
    run_selection = false,
    next_cell = false,
    prev_cell = false,
    goto_running_cell = false,
    toggle_follow_running = false,
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
| `:JoveGotoRunningCell` | Jump to the currently executing cell |
| `:JoveToggleFollowRunning` | Toggle following the currently executing cell with the cursor |
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
    run_cell              = "<leader>x",  -- normal: run cell under cursor
    run_and_advance       = "<leader>X",  -- normal: run cell, jump to next
    run_selection         = "<leader>xx", -- visual: run selection as one unit
    next_cell             = "]h",
    prev_cell             = "[h",
    goto_running_cell     = "<leader>j",  -- normal: jump to the running cell
    toggle_follow_running = "<leader>J",  -- normal: cursor follows the running cell
  },
}
```
