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

```sh
bash scripts/test.sh unit
bash scripts/test.sh component
```

The runner selects whole files using `JOVE_TEST_TIER` through `scripts/minimal_init.lua`:

| Tier | Scope |
| --- | --- |
| `unit` | Focused transformations and logic. |
| `component` | Neovim buffers, UI, state, and orchestration. |
| `adapter` | Real conversion, filesystem, or terminal-process boundaries. |
| `e2e` | Real kernel flows. |

Persistence specs are separated by dependency: in-memory transformations and
merging run as unit tests, buffer-only behavior runs as component tests, and
real file writes and notebook conversion run as adapter tests.

Run the external-boundary tiers and Python tiers:

```sh
JOVE_TEST_STRICT=1 uv run --project python --locked --extra dev bash scripts/test.sh adapter
JOVE_TEST_STRICT=1 uv run --project python --locked --extra dev bash scripts/test.sh e2e
uv run --project python --locked --extra dev python -m pytest -q -m unit
uv run --project python --locked --extra dev python -m pytest -q -m integration
```

Adapter and e2e runs require the Python environment and `jupytext`; Lua real-kernel
flows also need the registered `python3` kernelspec. `JOVE_TEST_STRICT=1` makes
missing real-bridge prerequisites fail instead of skipping. CI uses this mode.
Python uses strict registered `unit` and `integration` pytest markers; mark new
tests according to whether they stay in-process or exercise real external
boundaries. Integration tests can take several minutes.

The full-suite commands remain supported (`all` is the Lua default, unless
`JOVE_TEST_TIER` is set; an explicit argument overrides that environment variable):

```sh
uv run --project python --locked --extra dev bash scripts/test.sh
uv run --project python --locked --extra dev python -m pytest -q
```

Run a single component spec without the Python environment, or wrap Neovim in
`uv run --project python --locked --extra dev` for an adapter/e2e spec:

```sh
nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run_file("tests/spec/cell_spec.lua")'
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
