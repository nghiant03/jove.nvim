# Contributing to jove.nvim

Bug reports, fixes, tests, and documentation improvements are welcome. For a
large feature or a change to existing behavior, open an issue first to discuss
the use case and scope.

## Reporting issues

Search existing issues before opening a new one, then use the bug report or
feature request template. For bugs, include a minimal reproduction, the plugin
revision, and the output of `:checkhealth jove`.

## Development setup

Run the commands below from the repository root.

```sh
uv sync --project python --locked --extra dev --python 3.12
git clone --depth 1 https://github.com/nvim-mini/mini.test .testdeps/mini.test
uv run --project python --locked --extra dev python -m ipykernel install --user --name python3 --display-name "Python 3 (ipykernel)"
```

For manual testing, point your plugin manager at this checkout rather than an
installed release. Launch Neovim through the project environment so that
`jupytext` and the bridge dependencies are available:

```sh
uv run --project python --locked --extra dev nvim
```

## Tests and checks

Run the Lua plugin and Python bridge suites:

```sh
uv run --project python --locked --extra dev bash scripts/test.sh
uv run --project python --locked --extra dev python -m pytest -q
```

The Lua suite requires `.testdeps/mini.test` and a `jupytext` executable.
Keep the project environment active even when running a single spec:

```sh
uv run --project python --locked --extra dev nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run({ file = "tests/spec/cell_spec.lua" })'
```

Integration tests start real kernels and can take several minutes.

Install StyLua and Selene separately, then run formatting and lint checks:

```sh
stylua --check .
selene .
uv run --project python --locked --extra dev ruff check python
uv run --project python --locked --extra dev ruff format --check python
```

## Making changes

- Keep pull requests focused and add regression tests for bug fixes.
- Use the existing mini.test patterns in `tests/spec/` and pytest tests under
  `python/`.
- When adding configuration, update the defaults, `KNOWN_KEYS`, and
  `jove.Config` annotations in `lua/jove/init.lua`, plus the README table.
- Add actions through `<Plug>(Jove...)` mappings with descriptions, update the
  README mapping table, and add a `:Jove` subcommand where appropriate.

## Pull requests

Describe the problem, the intended behavior, and how you tested the change.
Link any related issue. For rendering or interaction changes, include a small
reproduction and screenshots or a recording when useful. Call out changes to
configuration, compatibility, or existing behavior.

Run the relevant tests and checks before submitting, and note anything you
could not run. Do not include local environments, downloaded test dependencies,
or generated notebook outputs unrelated to the change.

Releases are managed through the GitHub Release workflow. Contributors do not
need to update a package version or create tags.
