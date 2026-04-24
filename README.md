# jove.nvim

Edit Jupyter `.ipynb` notebooks in Neovim as if they were native Python
buffers — with rendered cell outputs, real LSP/copilot/treesitter, and proper
round-tripping to disk. No otter, no quarto, no temp files, no lost outputs.

## How it works

```
.ipynb on disk (JSON)
    │  BufReadCmd  ── jupytext CLI via stdio (no temp file) ──▶
buffer  buftype=acwrite, filetype=python
    │  pyright/ruff/copilot/treesitter attach natively
    │  molten attaches → kernel + inline outputs
    │  BufWriteCmd ── jupytext --update via stdio ──▶
.ipynb on disk (JSON, outputs preserved)
```

## Requirements

- Neovim ≥ 0.10
- [`jupytext`](https://github.com/mwouts/jupytext) on `$PATH`
- [`molten-nvim`](https://github.com/benlubas/molten-nvim) — optional but
  required for kernel execution and rich outputs
- [`nvim-various-textobjs`](https://github.com/chrisgrieser/nvim-various-textobjs)
  — optional, for `ic`/`ac` cell text-objects

## Install (lazy.nvim)

```lua
{
  "nghiant03/jove.nvim",
  lazy = false,                        -- BufReadCmd must be registered before .ipynb is opened
  dependencies = { "benlubas/molten-nvim" },
  opts = {
    auto_kernel = true,                -- MoltenInit from kernelspec on open
    auto_import_outputs = true,        -- restore outputs from .ipynb JSON
    auto_export_outputs = true,        -- merge molten outputs back on :w
    keymap = {
      run_cell  = "<leader>x",
      next_cell = "]h",
      prev_cell = "[h",
    },
  },
}
```

> `opts = {}` (or `config = true`) is **required** — without it lazy.nvim
> never calls `require("jove").setup(...)`, and the keymaps under `keymap = {}`
> are not registered. The `BufReadCmd`/`BufWriteCmd` handlers are installed
> from `plugin/jove.lua` at startup either way, but you'll lose the cell
> motions and `run_cell` binding.

## Setup

### 1. Install `jupytext`

```sh
pip install jupytext      # or: pipx install jupytext / conda install jupytext
jupytext --version        # must be on $PATH for the nvim process
```

If you launch Neovim from a conda env that doesn't have `jupytext`, prepend
the env's `bin/` to `vim.env.PATH` early in your `init.lua`, or set
`opts.jupytext = "/abs/path/to/jupytext"`.

### 2. Install `molten-nvim` (recommended)

Molten provides the kernel and inline outputs. Without it jove still edits
notebooks, but `:JoveRunCell` and outputs do nothing. Minimal lazy spec:

```lua
{
  "benlubas/molten-nvim",
  build = ":UpdateRemotePlugins",
  init = function()
    vim.g.molten_image_provider       = "image.nvim" -- or "snacks.nvim"
    vim.g.molten_auto_open_output     = false
    vim.g.molten_virt_text_output     = true
    vim.g.molten_virt_lines_off_by_1  = true         -- correct for `# %%` cells
    vim.g.molten_wrap_output          = true
  end,
}
```

You also need a Jupyter kernel that matches your notebook's
`metadata.kernelspec.name` — typically `python3` from `ipykernel`:

```sh
pip install ipykernel
python -m ipykernel install --user --name python3
```

Verify inside nvim with `:lua =vim.fn.MoltenAvailableKernels()`.

### 3. Avoid conflicts

- **Do not load `jupytext.nvim`** alongside jove — both register `BufReadCmd`
  on `*.ipynb`. Jove will hard-refuse and warn on startup; remove one.
- **Do not duplicate molten's auto-init autocmds.** If you copied the
  `BufAdd *.ipynb` → `MoltenInit` + `MoltenImportOutput` snippet from
  molten's README, delete it: jove already does this when
  `auto_kernel = true` and `auto_import_outputs = true`. Otherwise molten
  initializes twice and logs errors.

### 4. Verify

```vim
:checkhealth jove
```

Expect green checks for: Neovim ≥ 0.10, `jupytext` binary found, molten
detected, no `jupytext.nvim` conflict. Then open any `.ipynb`:

```sh
nvim notebook.ipynb
```

You should land in a Python buffer split into `# %%` cells, with kernel
status visible via molten and outputs rendered as virtual text.

## Commands

| Command | Action |
|---|---|
| `:JoveRunCell` | Run cell under cursor via molten |
| `:JoveRunAbove` | Run all cells from top to cursor |
| `:JoveRunAll` | Run every cell |
| `:JoveNextCell` / `:JovePrevCell` | Jump between cells |
| `:JoveInitKernel` | Start molten kernel for this notebook |
| `:JoveImportOutputs` | Re-display outputs stored in the `.ipynb` JSON |
| `:JoveExportOutputs` | Merge current molten outputs into `.ipynb` on disk |
| `:checkhealth jove` | Verify deps, versions, and conflicts |

## Comparison

| | jove.nvim | jupytext.nvim | quarto-nvim + otter | jupynium.nvim |
|---|---|---|---|---|
| Native python LSP | yes | yes | proxy/chunked | yes |
| Inline outputs | via molten | no | via molten | via browser |
| No temp files | yes | no (writes sidecar) | yes | yes |
| Output persistence | yes (JSON merge) | no | manual | yes |
| Browser required | no | no | no | yes |
| Scope | small | small | wide (`.qmd`) | wide |

## Non-goals

- Markdown prose rendering between cells (markdown cells stay as
  `# %% [markdown]` comment blocks).
- Browser sync à la jupynium.
- A custom Jupyter kernel client (delegated to molten).
- Reimplementing `jupytext` format conversions in Lua.

## License

MIT
