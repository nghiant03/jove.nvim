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

- **Native buffers** — notebooks open as ordinary buffers in the kernel's
  language; pyright, ruff, copilot, treesitter and git tooling attach like
  any other file (see [Languages and LSP](#languages-and-lsp)).
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
- **Tooling** — a tabbed sidebar combining the variable inspector, notebook
  table of contents, and kernel info (sessions and installed kernelspecs),
  with number keys to switch tabs.

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
  version = "v*", -- pin to the latest release tag; drop to track main
  lazy = false,
  opts = {
    auto_kernel = true,
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
3. `g:python3_host_prog` (Neovim's configured Python host)
4. your configured `bridge_python` value (default `"python3"`)

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
                                -- conda/venv/host-prog precedence)
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
    size = 0.25,                -- sidebar size as a fraction of the screen (columns, or lines in hsplit mode)
  },
  ui = {
    conceal_headers = true,     -- conceal # %% cell headers (front matter is hidden by stripping it on read)
    active_cell = true,         -- highlight the active cell
    exec_counts = true,         -- show per-cell execution counts
    elapsed = true,             -- show per-cell elapsed time
    borders = true,             -- draw a closing line below each cell
    border_hl = nil,            -- cell border highlight: an hl group name (string, linked) or attrs table (e.g. { fg = "#ff9e64" }); nil keeps the default Comment link
    window_mode = "vsplit",     -- how to open the sidebar and output viewer: "float", "vsplit", or "hsplit"
  },
  lsp = {
    auto_attach = false,        -- start the servers in `servers` on notebook open
    servers = {},               -- language id -> vim.lsp.config server names,
                                -- e.g. { python = { "pyright" }, javascript = { "ts_ls" } }
  },
})
```

## Languages and LSP

Built-in languages:

| Language | Filetype | Cell marker | Known servers |
|---|---|---|---|
| Python | `python` | `# %%` | pyright, basedpyright, ruff |
| Julia | `julia` | `# %%` | julials |
| R | `r` | `# %%` | r_language_server |
| JavaScript | `javascript` | `// %%` | ts_ls |
| TypeScript | `typescript` | `// %%` | ts_ls |

Unknown languages fall back to Python conventions. Register
more yourself:

```lua
require("jove.lang").register("scala", { fmt = "scala", comment = "//", servers = { "metals" } })
```

Because the buffer carries the language's real filetype, any LSP server you
have configured  attaches to notebook buffers automatically. If you prefer 
jove to start the servers for you:

```lua
opts = {
  lsp = {
    auto_attach = true,
    servers = { python = { "pyright" }, javascript = { "ts_ls" } },
  },
}
```

## Usage

### Commands

Everything lives under a single `:Jove` command with tab-completed
subcommands (`:Jove <Tab>` lists them). The old flat `:JoveFoo` commands
still work as deprecated aliases and will be removed in 0.5.0.

| Command | Action |
|---|---|
| `:Jove run-cell` | Run current notebook cell |
| `:Jove run-above` | Run all notebook cells above the cursor |
| `:Jove run-all` | Run all notebook cells |
| `:Jove run-selection` | Run the visual selection as one unit |
| `:Jove run-cell-and-advance` | Run the current cell and jump to the next |
| `:Jove next-cell` | Jump to next notebook cell |
| `:Jove prev-cell` | Jump to previous notebook cell |
| `:Jove goto-running-cell` | Jump to the currently executing cell |
| `:Jove toggle-follow-running` | Toggle following the currently executing cell with the cursor |
| `:Jove init-kernel` | Start a kernel for the current notebook |
| `:Jove select-kernel` | Pick a kernelspec for the current notebook (replaces running kernel) |
| `:Jove interrupt` | Interrupt the running execution |
| `:Jove restart-kernel` | Restart the current notebook kernel |
| `:Jove shutdown-kernel` | Shut down the current notebook kernel and bridge |
| `:Jove toggle-output` | Show/hide rendered outputs of the current cell |
| `:Jove open-output` | Open the current cell's outputs in a float |
| `:Jove clear-output` | Clear outputs of the current cell |
| `:Jove clear-outputs` | Clear all rendered outputs in this buffer |
| `:Jove reload` | Reload the current notebook buffer from disk |
| `:Jove sidebar` | Toggle the sidebar (variables, kernel info, table of contents) |

### Keymaps and motions

On jove buffers (python, julia, r, javascript, typescript filetypes backed by
an `.ipynb`):

- `ic` / `ac` cell text-objects (operator-pending and visual modes) — always
  on, no extra plugin needed.
- `[c` / `]c` cell motions (normal mode) — on by default; disable with
  `cell_motions = false`. Jove never clobbers your own bindings: the defaults
  are skipped if you already mapped `[c`/`]c` or bound something to the
  corresponding `<Plug>` mapping.
- Jove defines no other keymaps by itself. Bind the buffer-local `<Plug>`
  mappings to your own keys instead:

```lua
vim.keymap.set("n", "<leader>x", "<Plug>(JoveRunCell)", { desc = "Run cell" })
vim.keymap.set("n", "<leader>X", "<Plug>(JoveRunCellAndAdvance)", { desc = "Run cell, advance" })
vim.keymap.set("x", "<leader>xx", "<Plug>(JoveRunSelection)", { desc = "Run selection" })
vim.keymap.set("n", "<leader>j", "<Plug>(JoveGotoRunningCell)", { desc = "Go to running cell" })
vim.keymap.set("n", "<leader>J", "<Plug>(JoveToggleFollowRunning)", { desc = "Follow running cell" })
```

Available `<Plug>` mappings (active on notebook buffers only):

| Mapping | Action |
|---|---|
| `<Plug>(JoveRunCell)` | Run current notebook cell |
| `<Plug>(JoveRunAbove)` | Run all notebook cells above the cursor |
| `<Plug>(JoveRunAll)` | Run all notebook cells |
| `<Plug>(JoveRunSelection)` | Run the visual selection as one unit (visual mode) |
| `<Plug>(JoveRunCellAndAdvance)` | Run the current cell and jump to the next |
| `<Plug>(JoveNextCell)` | Jump to next notebook cell |
| `<Plug>(JovePrevCell)` | Jump to previous notebook cell |
| `<Plug>(JoveGotoRunningCell)` | Jump to the currently executing cell |
| `<Plug>(JoveToggleFollowRunning)` | Toggle following the currently executing cell |
