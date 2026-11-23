-- Godot 4 projects: the game run in the Run panel, debugged through the
-- Godot editor's debug adapter into the Debug panel.
--
--   Run     `godot --path <project> [scene]` in a Run panel tab, as any
--           command: print(), push_error() and the engine's own log in it
--   Debug   a launch through the editor's debug adapter (port 6006): the
--           editor plays the scene and the game stops at nvim's breakpoints.
--           Its output is a tab of the Run panel ("Godot"), and the Console
--           tab of the Debug panel while the session runs.
--
-- The scene a configuration runs: none (the project's main scene), "current"
-- (the scene of the file you are in -- a .tscn, or a script attached to one)
-- or a `res://` path.
--
-- The editor has to be open on the same project for Debug: the debug adapter
-- is part of it (Editor Settings > Network > Debug Adapter).

local M = {}

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function opts()
  return require("aedi.config").options.godot
end

--- The Godot project in `root`: `root` itself, or a directory right under it
--- (a repository that keeps the game in `game/` or `src/`).
---@param root string
---@return string?
function M.project(root)
  if vim.uv.fs_stat(root .. "/project.godot") then
    return root
  end
  for name, type in vim.fs.dir(root) do
    if type == "directory" and not name:match("^%.") and vim.uv.fs_stat(root .. "/" .. name .. "/project.godot") then
      return root .. "/" .. name
    end
  end
end

--- The Godot executable: the option, `godot` on PATH, else the macOS app.
---@return string?
function M.bin()
  local bin = opts().bin
  if bin and bin ~= "" then
    return vim.fn.expand(bin)
  end
  for _, name in ipairs({ "godot", "godot4" }) do
    if vim.fn.executable(name) == 1 then
      return vim.fn.exepath(name)
    end
  end
  for _, app in ipairs({ "/Applications/Godot.app", vim.fn.expand("~/Applications/Godot.app") }) do
    local exe = app .. "/Contents/MacOS/Godot"
    if vim.uv.fs_stat(exe) then
      return exe
    end
  end
end

---@param project string
---@param path string absolute
---@return string res://...
function M.res(project, path)
  return "res://" .. path:sub(#project + 2)
end

--- The project's main scene (`run/main_scene`), if it has one.
---@param project string
---@return string?
function M.main_scene(project)
  local text = read(project .. "/project.godot") or ""
  return text:match('\nrun/main_scene%s*=%s*"([^"]+)"')
end

--- The project's scenes, as `res://` paths (`.godot/` and `addons/` left out).
---@param project string
---@return string[]
function M.scenes(project)
  local out = {}
  for rel, type in vim.fs.dir(project, {
    depth = 32,
    -- false: not into it (`dir` is relative to `project`)
    skip = function(dir)
      local name = vim.fs.basename(dir)
      return name ~= "addons" and not name:match("^%.")
    end,
  }) do
    if type == "file" and rel:match("%.tscn$") then
      out[#out + 1] = "res://" .. rel
    end
  end
  table.sort(out)
  return out
end

--- The scenes `file` stands for: itself when it is one, the ones it is
--- attached to when it is a script.
---@param project string
---@param file string absolute
---@return string[]
function M.scenes_of(project, file)
  if file:sub(1, #project + 1) ~= project .. "/" then
    return {}
  end
  local res = M.res(project, file)
  if file:match("%.tscn$") then
    return { res }
  end
  local out = {}
  for _, scene in ipairs(M.scenes(project)) do
    local text = read(project .. "/" .. scene:sub(7)) or ""
    if text:find('path="' .. res .. '"', 1, true) then
      out[#out + 1] = scene
    end
  end
  return out
end

--- The scene of the file in the code window you were in last.
---@param project string
---@return string?, string? error
function M.current_scene(project)
  local win = require("aedi.console").last_code
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = require("aedi.util").code_win()
  end
  local file = win and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) or ""
  if file == "" then
    return nil, "no file open"
  end
  local scenes = M.scenes_of(project, vim.fs.normalize(file))
  if #scenes == 0 then
    return nil, vim.fs.basename(file) .. " is not a scene, nor a script in one"
  end
  -- A script in several scenes: the one named after it, else the first.
  local base = vim.fn.fnamemodify(file, ":t:r")
  for _, s in ipairs(scenes) do
    if vim.fn.fnamemodify(s, ":t:r") == base then
      return s
    end
  end
  return scenes[1]
end

---@class aedi.GodotLaunch
---@field name string
---@field project string
---@field scene string "main" or a res:// path
---@field args string[]

--- What running `c` (a `godot` configuration) runs.
---@param c aedi.Configuration
---@param root string
---@return aedi.Launch?, string? error
function M.build(c, root)
  local project = M.project(root)
  if not project then
    return nil, "no project.godot in " .. vim.fn.fnamemodify(root, ":~")
  end
  local bin = M.bin()
  if not bin then
    return nil, "no Godot: set godot.bin, or put godot on PATH"
  end
  local scene = c.scene
  if scene == "current" then
    local err
    scene, err = M.current_scene(project)
    if not scene then
      return nil, err
    end
  elseif scene and scene ~= "" and not scene:match("^res://") then
    scene = "res://" .. scene:gsub("^%./", "")
  elseif not scene or scene == "" then
    if not M.main_scene(project) then
      return nil, "the project has no main scene (Project Settings > Application > Run)"
    end
    scene = nil
  end
  local types = require("aedi.types")
  local args = types.split_args(c.args)
  local shown = { bin, "--path", project }
  if scene then
    shown[#shown + 1] = scene
  end
  vim.list_extend(shown, args)
  return {
    cmd = table.concat(vim.tbl_map(function(a)
      return a:find("[%s'\"]") and vim.fn.shellescape(a) or a
    end, shown), " "),
    cwd = project,
    env = c.env,
    godot = { name = c.name, project = project, scene = scene or "main", args = args },
  }
end

-- ---------------------------------------------------------------------------
-- Debug: through the editor's debug adapter
-- ---------------------------------------------------------------------------

--- Is anything listening on the debug adapter's port? (nvim-dap's own
--- failure to connect is a bare ECONNREFUSED.)
local function reachable(cb)
  local o = opts()
  local tcp = vim.uv.new_tcp()
  tcp:connect(o.host, o.port, function(err)
    tcp:close()
    vim.schedule(function()
      cb(err == nil)
    end)
  end)
end

--- Debug `spec` (from `build`) in the Godot editor.
---@param spec aedi.GodotLaunch
function M.debug(spec)
  reachable(function(up)
    if not up then
      local o = opts()
      vim.notify(
        ("No Godot editor at %s:%d -- open the project in Godot to debug it (Editor Settings > Network > Debug Adapter)"):format(o.host, o.port),
        vim.log.levels.WARN
      )
      return
    end
    require("dap").run({
      type = "godot",
      request = "launch",
      name = spec.name,
      project = spec.project,
      scene = spec.scene,
      playArgs = #spec.args > 0 and spec.args or nil,
      aedi = true,
    })
  end)
end

local done = false

--- The `godot` debug adapter, launch configurations for `:DapContinue` in a
--- .gd file, and the session's output in the Run panel and the Debug panel.
function M.setup()
  if done then
    return
  end
  local ok, dap = pcall(require, "dap")
  if not ok then
    return
  end
  done = true
  local o = opts()
  dap.adapters.godot = { type = "server", host = o.host, port = o.port }
  local function project()
    return M.project(require("aedi.util").root()) or require("aedi.util").root()
  end
  dap.configurations.gdscript = dap.configurations.gdscript or {}
  vim.list_extend(dap.configurations.gdscript, {
    { type = "godot", request = "launch", name = "Godot: main scene", project = project, scene = "main" },
    {
      type = "godot",
      request = "launch",
      name = "Godot: current scene",
      project = project,
      scene = function()
        return M.current_scene(project()) or "main"
      end,
    },
  })

  local console = require("aedi.console")
  local view = require("aedi.debug.view")

  -- The output of every debug session, one buffer kept across them as the
  -- IntelliJ tab keeps its own: each launch starts it afresh.
  local buf
  local function output_buf()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].filetype = "aedi-console"
      vim.api.nvim_buf_set_name(buf, "aedi://godot")
    end
    return buf
  end
  local tab
  local function ensure(name)
    tab = console.external({
      key = "godot",
      name = name or (tab and tab.config.name) or "Godot",
      buf = output_buf(),
      cwd = project(),
      stop = function()
        dap.terminate()
      end,
      rerun = function()
        dap.run_last()
      end,
    })
    return tab
  end
  local function showing()
    return tab ~= nil and console.visible() and console.current_run() == tab
  end

  local function ours(session)
    return session and session.config and session.config.type == "godot"
  end
  dap.listeners.after.event_initialized["aedi.godot"] = function(session)
    if not ours(session) then
      return
    end
    vim.api.nvim_buf_set_lines(output_buf(), 0, -1, false, {})
    console.set_state(ensure(session.config.name), "running")
  end
  dap.listeners.after.event_output["aedi.godot"] = function(session, body)
    if not ours(session) or not body or not body.output or body.category == "telemetry" then
      return
    end
    local b = output_buf()
    local lines = vim.split((body.output:gsub("\r", "")), "\n", { plain = true })
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    local last = vim.api.nvim_buf_line_count(b)
    local empty = last == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == ""
    vim.api.nvim_buf_set_lines(b, empty and 0 or last, -1, false, lines)
  end
  local function ended(session)
    if ours(session) and tab then
      console.set_state(tab, "exited", 0)
    end
  end
  dap.listeners.after.event_terminated["aedi.godot"] = ended
  dap.listeners.after.disconnect["aedi.godot"] = ended

  -- The Debug panel's Console tab is this output; outside a session, it is
  -- the Run panel's tab.
  require("aedi.debug").listen(ours, {
    buf = output_buf,
    is_open = showing,
    close = function()
      if showing() then
        console.hide()
      end
    end,
    open = function(o2)
      if view.console_win() then
        return
      end
      console.show_run(ensure(), not (o2 and o2.focus == false))
    end,
  })
end

return M
