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
  "your-user/jove.nvim",
  ft = "python",                       -- jove handles .ipynb via BufReadCmd
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

## Commands

| Command | Action |
|---|---|
| `:IpynbRunCell` | Run cell under cursor via molten |
| `:IpynbRunAbove` | Run all cells from top to cursor |
| `:IpynbRunAll` | Run every cell |
| `:IpynbNextCell` / `:IpynbPrevCell` | Jump between cells |
| `:IpynbInitKernel` | Start molten kernel for this notebook |
| `:IpynbImportOutputs` | Re-display outputs stored in the `.ipynb` JSON |
| `:IpynbExportOutputs` | Merge current molten outputs into `.ipynb` on disk |
| `:checkhealth ipynb` | Verify deps, versions, and conflicts |

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
