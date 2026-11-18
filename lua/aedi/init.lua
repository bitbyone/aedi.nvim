-- aedi.nvim: run configurations, a Run panel and a Debug panel, the way
-- IntelliJ IDEA has them.
--
--   require("aedi").setup(opts)      see lua/aedi/config.lua for opts
--
--   :AediRun [name]    pick a configuration and run it (or run `name`)
--   :AediRerun         run the last one again
--   :AediEdit [name]   edit a configuration; :AediNew a new one
--   :AediStop          stop the run in the current tab of the panel
--   :AediConsole       show / focus / hide the Run panel
--   :AediExec {cmd}    run a shell command in the panel, once

local M = {}

local function console()
  return require("aedi.console")
end

--- Pick a configuration and run it.
function M.pick()
  require("aedi.picker").pick()
end

--- Pick a configuration and debug it (Application, Spring Boot: through the
--- IntelliJ server).
function M.pick_debug()
  require("aedi.picker").pick({ debug = true })
end

--- Debug a configuration: a table, or the name of a saved or found one.
---@param c aedi.Configuration|string
function M.debug(c)
  return M.run(c, { debug = true })
end

--- Run a configuration: a table, or the name of a saved or detected one.
---@param c aedi.Configuration|string
---@param opts? { debug?: boolean }
function M.run(c, opts)
  if type(c) == "string" then
    local name = c
    c = require("aedi.store").get(name)
    if not c then
      for _, d in ipairs(require("aedi.detect").all(require("aedi.util").root())) do
        if d.name == name then
          c = d
          break
        end
      end
    end
    if not c then
      vim.notify("No run configuration " .. name, vim.log.levels.WARN)
      return
    end
  end
  return console().start(c, opts)
end

--- Run a shell command in the panel without saving it (`e` in the panel
--- saves it as a configuration).
---@param cmd string
---@param opts? { name?: string, cwd?: string, env?: table<string, string> }
function M.exec(cmd, opts)
  opts = opts or {}
  return console().start({ name = opts.name or cmd, command = cmd, cwd = opts.cwd, env = opts.env })
end

--- Run the detected configuration of a kind ("run", "test", "build"): the
--- project's own `gradlew test`, `go test ./...`, `cargo test`, ...
---@param kind "run"|"test"|"build"
function M.run_kind(kind)
  for _, c in ipairs(require("aedi.detect").all(require("aedi.util").root())) do
    if c.kind == kind then
      return console().start(c)
    end
  end
  vim.notify(("Nothing to %s found in %s"):format(kind, require("aedi.util").root()), vim.log.levels.WARN)
end

--- Run the last configuration again: the saved one as it is now, if it was
--- saved.
function M.rerun()
  local store = require("aedi.store")
  local last = store.last()
  if not last then
    return M.pick()
  end
  return console().start(store.get(last.name) or last)
end

--- Stop the current run of the panel. false when nothing was running.
---@return boolean
function M.stop()
  return console().stop()
end

--- Is anything running in the panel?
function M.is_running()
  for _, r in ipairs(console().runs) do
    if console().running(r) then
      return true
    end
  end
  return false
end

function M.toggle()
  console().toggle()
end

---@param name? string
function M.edit(name)
  if name and name ~= "" then
    local c = require("aedi.store").get(name)
    if not c then
      vim.notify("No saved run configuration " .. name, vim.log.levels.WARN)
      return
    end
    return require("aedi.editor").open(c)
  end
  require("aedi.picker").pick_edit()
end

function M.new()
  require("aedi.editor").open(nil)
end

local function complete_names()
  local names = {}
  for _, c in ipairs(require("aedi.picker").items()) do
    names[#names + 1] = c.name
  end
  return names
end

---@param opts? aedi.Options
function M.setup(opts)
  require("aedi.config").set(opts)
  require("aedi.hints").setup()
  require("aedi.editor").setup()
  require("aedi.grep").setup()
  console().setup()
  local cmd = vim.api.nvim_create_user_command
  cmd("AediRun", function(a)
    if a.args ~= "" then
      M.run(a.args)
    else
      M.pick()
    end
  end, { nargs = "?", complete = complete_names, desc = "Run a configuration" })
  cmd("AediDebug", function(a)
    if a.args ~= "" then
      M.debug(a.args)
    else
      M.pick_debug()
    end
  end, { nargs = "?", complete = complete_names, desc = "Debug a configuration" })
  cmd("AediRerun", M.rerun, { desc = "Run the last configuration again" })
  cmd("AediEdit", function(a)
    M.edit(a.args)
  end, { nargs = "?", complete = complete_names, desc = "Edit a run configuration" })
  cmd("AediNew", M.new, { desc = "New run configuration" })
  cmd("AediStop", function()
    M.stop()
  end, { desc = "Stop the current run" })
  cmd("AediConsole", M.toggle, { desc = "Run panel" })
  cmd("AediExec", function(a)
    M.exec(a.args)
  end, { nargs = "+", complete = "shellcmd", desc = "Run a shell command in the Run panel" })
  if require("aedi.config").options.debug.enabled then
    require("aedi.debug").setup()
  end
end

return M
