# aedi.nvim

Run configurations, a Run panel and a Debug panel for Neovim, the way IntelliJ
IDEA has them. ("aedi" is "idea" backwards.)

- **Run configurations**: any shell command with its arguments, working
  directory and environment. They work for any language and build tool. The
  ones the project already has are offered too: `gradlew run/test/bootRun`,
  `go run ./cmd/...`, `cargo run`, npm scripts and make targets.
- **Run panel**: a split across the bottom with one tab per configuration.
  Each tab is a terminal, so colours and stdin work. Its winbar shows status
  and exit code. `<CR>` on a stack frame or `file:line` opens it.
- **Debug panel** (nvim-dap-ui): frames, variables and watches across the
  bottom, with a Console tab beside Variables. Long values open in a framed,
  wrapped popup.

## Install

lazy.nvim:

```lua
{
  "bitbyone/aedi.nvim",
  opts = {},
  keys = {
    { "<leader>Rr", function() require("aedi").pick() end, desc = "Run configuration…" },
    { "<leader>RR", function() require("aedi").rerun() end, desc = "Rerun last" },
    { "<leader>Rl", function() require("aedi").toggle() end, desc = "Run panel" },
    { "<leader>Rs", function() require("aedi").stop() end, desc = "Stop" },
  },
}
```

Requires Neovim 0.11+. [snacks.nvim](https://github.com/folke/snacks.nvim)
gives the picker its actions; without it, `vim.ui.select` is used.

## Run configurations

`:AediRun` (or `require("aedi").pick()`) lists the configurations. Saved ones
come first, starting with the one you ran last, then the ones found in the
project:

| key | |
| --- | --- |
| `<CR>` | run |
| `<C-e>` | edit; a found configuration is saved as a copy of your own |
| `<C-n>` | new |
| `<C-y>` | duplicate |
| `<C-x>` | delete |

Editing opens a form, which is a plain buffer edited like any text:

```
name:    API server
command: go run ./cmd/server
args:    --port 8080
cwd:     services/api
env:     LOG_LEVEL=debug
env:     PORT=8080
```

- `command` runs through `'shell'`, so pipes, `&&` and `$VARS` work.
- `args` is appended to `command`.
- `cwd` is relative to the project root.
- Each `env:` line sets one variable.

`:w` saves, `<C-CR>` saves and runs, and `q` closes.

Configurations are stored per project in
`stdpath("data")/aedi/configurations.json`, keyed by the project root (the
working directory by default). Nothing is written into the project.

## Run panel

| key (normal mode) | |
| --- | --- |
| `r` | rerun |
| `<C-c>` | stop (sends Ctrl-C; press again to kill) |
| `x` | close the tab |
| `e` | edit the configuration, or save an ad-hoc command as one |
| `<CR>` | open the file or stack frame under the cursor |
| `<Tab>` / `<S-Tab>` | next / previous tab |
| `q` | hide the panel |
| `<Esc>` | go back to the editor |
| `i` | type into the program |

`<CR>` understands these:

- JVM stack frames (`at com.x.Foo.bar(Foo.kt:42)`). A frame is found in the
  project, otherwise through the language server, so library frames open in
  their sources.
- `path:line[:col]` from any tool.
- Python tracebacks.

## Commands and API

| command | Lua | |
| --- | --- | --- |
| `:AediRun [name]` | `pick()`, `run(name_or_config)` | pick and run |
| `:AediRerun` | `rerun()` | run the last configuration again |
| `:AediEdit [name]`, `:AediNew` | `edit(name)`, `new()` | edit or create a configuration |
| `:AediStop` | `stop()` | stop the current tab |
| `:AediConsole` | `toggle()` | open, focus or hide the panel |
| `:AediExec {cmd}` | `exec(cmd, opts)` | run a command once, without saving it |
| | `run_kind("test")` | run the project's detected test, build or run |

## Options

```lua
require("aedi").setup({
  store = vim.fn.stdpath("data") .. "/aedi/configurations.json",
  root = function() return vim.uv.cwd() end,   -- the project of a configuration
  detect = true,                               -- offer the project's own configurations
  detectors = {},                              -- extra: function(root) -> configurations
  console = { height = 15 },
  debug = { enabled = true },
  on_panel = nil,   -- function(win): a window aedi draws its own winbar in
  ignore_buf = nil, -- function(buf): a split buffer that is not code (focus skips it)
})
```

## Debugging

These hooks go into the nvim-dap-ui spec:

```lua
{
  "rcarriga/nvim-dap-ui",
  opts = function(_, opts)
    require("aedi.debug").patch_dapui()
    return vim.tbl_deep_extend("force", opts, { layouts = require("aedi.debug").layouts })
  end,
}
```

Then choose which sessions get the Debug panel instead of dap-ui's own layout:

```lua
require("aedi.debug").listen(function(session) return session.config.type == "delve" end)
```

The Console tab of such a session is the current tab of the Run panel. For
[intellij-lsp.nvim](https://github.com/JetBrains/intellij-lsp.nvim), call
`require("aedi.integrations.intellij_lsp").setup()` after its setup. Its
sessions then get the Debug panel, with the plugin's run output as the Console tab.

`require("aedi.debug").toggle()` hides the Debug panel, or brings it back, while a
session is running.

## Tests

```sh
nvim -l tests/run.lua
```
