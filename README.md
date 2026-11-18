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

`:AediRun` (or `require("aedi").pick()`) lists the saved configurations
together with the ones found in the project. The ones you run most, and
most recently, come first (frecency).

| key | |
| --- | --- |
| `Enter` | run |
| `Ctrl-E` | edit; a found configuration is saved as a copy of your own |
| `Ctrl-N` | new |
| `Ctrl-Y` | duplicate |
| `Ctrl-X` | delete |

There are three types:

| type | fields | runs |
| --- | --- | --- |
| **Spring Boot** | module, profiles, arguments, environment | `./gradlew [:module:]bootRun --args='--spring.profiles.active=local …'` or `./mvnw spring-boot:run -Dspring-boot.run.profiles=local` |
| **Gradle** | tasks, arguments, environment | `./gradlew <tasks> <arguments>` |
| **Shell command** | command, arguments, directory, environment | the command, through `'shell'` |

Spring Boot applications are found by their `@SpringBootApplication` under
`src/main`, one configuration each. Their profiles come from
`application-<profile>.yml|yaml|properties` and from `on-profile:` documents.

The form is a float, laid out like this:

```
╭ Run configuration · access-control ─────────────────────────────────╮
│  TYPE          Spring Boot                             Enter change │
│  NAME          access-control                                       │
│  PROFILES      local                    local · openapi  Enter pick │
│  ARGUMENTS     none (program arguments, e.g. --server.port=8081)    │
│  ENVIRONMENT   KEY=value KEY2='with space'                          │
│                                                                     │
│  RUNS          ./gradlew bootRun --args='--spring.profiles.active=local'
│                in ~/workspace/my2n/access-control                   │
╰ Tab next · Enter pick · :w save · Ctrl-Enter save and run · q close ╯
```

- Each value is one line of text, edited like any text.
- `Enter` on Type, Profiles or Module offers their choices; profiles are
  ticked in a list.
- `RUNS` follows as you type, so it always shows how the profile gets
  activated.

Configurations are stored per project in
`stdpath("data")/aedi/configurations.json`, keyed by the project root (the
working directory by default). Nothing is written into the project.

## Run panel

| key (normal mode) | |
| --- | --- |
| `r` | rerun |
| `Ctrl-C` | stop (sends Ctrl-C; press again to kill) |
| `x` | close the tab; it stops the process if it is still running |
| `e` | edit the configuration, or save an ad-hoc command as one |
| `Enter` | go to the file or stack frame under the cursor |
| `Tab` / `Shift-Tab` | next / previous tab |
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
