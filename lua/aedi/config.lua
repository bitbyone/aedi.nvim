-- Options, set once by `require("aedi").setup(opts)`.

local M = {}

---@class aedi.Options
M.defaults = {
  -- Where run configurations are kept: one JSON file for every project,
  -- keyed by the project root, so nothing is written into the project.
  store = vim.fn.stdpath("data") .. "/aedi/configurations.json",
  -- The project a configuration belongs to. The working directory by
  -- default -- the folder nvim was opened in.
  root = function()
    return vim.fs.normalize(vim.uv.cwd() or ".")
  end,
  -- Offer configurations found in the project (gradlew run, go test ./...,
  -- cargo run, npm scripts, make targets) next to the saved ones.
  detect = true,
  ---@type (fun(root: string): aedi.Configuration[])[]
  detectors = {},
  console = {
    -- Rows of the Run panel across the bottom.
    height = 15,
  },
  -- Log lines coloured by level (lua/aedi/grep.lua): ERROR, WARN and DEBUG
  -- by default. `name = false` turns one off, a table overrides or adds one:
  -- { pattern = <vim regex>, hl = <group or nvim_set_hl attributes>, order = n }
  ---@type table<string, aedi.GrepRule|false>
  grep = {},
  -- Run in the project's mise environment (lua/aedi/env.lua) when it has a
  -- mise config and mise is installed.
  mise = true,
  gradle = {
    -- Index the project's Gradle tasks in the background (lua/aedi/gradle.lua).
    index = true,
  },
  debug = {
    -- The Debug panel, dap-ui's gutter cleanup and its framed value popup.
    enabled = true,
  },
  --- A window aedi draws its own winbar in (the Run panel, the Debug panel's
  --- variables window). For a tab line plugin that would otherwise repaint
  --- the winbar.
  ---@type fun(win: integer)?
  on_panel = nil,
  --- A buffer that is in a split but is not code (a centring margin, say):
  --- focus never goes back to it.
  ---@type fun(buf: integer): boolean
  ignore_buf = nil,
}

---@type aedi.Options
M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
