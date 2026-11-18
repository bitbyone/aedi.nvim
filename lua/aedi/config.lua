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
  debug = {
    -- The debug strip, dap-ui's gutter cleanup and its framed value popup.
    enabled = true,
  },
  --- A window aedi draws its own winbar in (the Run panel, the debug strip's
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
