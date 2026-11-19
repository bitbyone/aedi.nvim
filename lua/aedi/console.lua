-- The Run panel: IntelliJ's Run tool window, a split across the bottom with a
-- tab per configuration that ran.
--
--   ● App   ✓ go test ./... 3.1s   ✗ gradle build 1         r rerun  ^C stop ...
--
-- Each tab is a terminal running the configuration's command, so colours,
-- progress bars and stdin work (`i` types into the program). Running a
-- configuration again reuses its tab. Output stays after the process exits;
-- `x` closes the tab.
--
-- In the panel (normal mode):
--   r        rerun          <C-c>   stop (Ctrl-C; again: kill)
--   x        close the tab  e       edit the configuration
--   <CR>     open the file / stack frame under the cursor
--   <Tab> <S-Tab>, <C-S-l> <C-S-h>   next / previous tab
--   q        hide           <Esc>   back to the editor

local util = require("aedi.util")

local M = {}

---@class aedi.Run
---@field id integer
---@field config aedi.Configuration
---@field buf integer
---@field job integer?
---@field cwd string
---@field code integer? exit code; nil while running
---@field started integer
---@field ended integer?
---@field stopping boolean?

---@type aedi.Run[]
M.runs = {}
---@type integer? index into M.runs
M.current = nil
---@type integer?
M.win = nil

local next_id = 0

local function valid_win()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

---@return aedi.Run?
function M.current_run()
  return M.current and M.runs[M.current] or nil
end

--- Is the panel on screen in this tab?
function M.visible()
  return valid_win() and vim.api.nvim_win_get_tabpage(M.win) == vim.api.nvim_get_current_tabpage()
end

local function running(run)
  return run.code == nil and not run.idle
end
M.running = running

local function duration(run)
  local ms = ((run.ended or vim.uv.now()) - run.started)
  if ms < 1000 then
    return ("%dms"):format(ms)
  elseif ms < 60000 then
    return ("%.1fs"):format(ms / 1000)
  end
  return ("%dm%02ds"):format(ms / 60000, (ms / 1000) % 60)
end

local function status(run)
  if run.idle then
    return "○"
  elseif running(run) then
    return "●"
  elseif run.stopping then
    return "■"
  elseif run.code == 0 then
    return "✓"
  end
  return "✗"
end

-- ---------------------------------------------------------------------------
-- Winbar
-- ---------------------------------------------------------------------------

---@param i integer
function _G.AediConsoleTab(i, _, button)
  if button == "l" then
    M.select(i)
  elseif button == "m" then
    M.close(i)
  end
end

local HINT = {
  { "r", "rerun" },
  { "Ctrl-C", "stop" },
  { "x", "close tab" },
  { "e", "edit" },
  { "Enter", "go to source" },
  { "q", "hide" },
}

--- What the panel shows with no tab: how to get one.
local empty_buf

local EMPTY_HINT = { { "q", "hide" }, { "Esc", "editor" } }

local function empty()
  if empty_buf and vim.api.nvim_buf_is_valid(empty_buf) then
    return empty_buf
  end
  empty_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[empty_buf].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(empty_buf, 0, -1, false, {
    "",
    "  Nothing is running.",
    "",
    "  :AediRun picks a configuration and runs it here; :AediExec runs a command.",
  })
  vim.bo[empty_buf].modifiable = false
  vim.bo[empty_buf].filetype = "aedi-console"
  local ns = vim.api.nvim_create_namespace("aedi_empty")
  vim.api.nvim_buf_set_extmark(empty_buf, ns, 1, 0, { end_row = 4, hl_group = "AediHint", hl_eol = false })
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = empty_buf, nowait = true, desc = "Hide the Run panel" })
  vim.keymap.set("n", "<Esc>", function()
    M.to_editor()
  end, { buffer = empty_buf, nowait = true, desc = "Back to the editor" })
  return empty_buf
end

--- An external tab (IntelliJ's output) has no configuration to edit.
local function hint_for(run)
  if run and run.external then
    local out = { { "r", "rerun" }, { "d", "debug" } }
    vim.list_extend(out, vim.tbl_filter(function(h)
      return h[1] ~= "e" and h[1] ~= "r"
    end, HINT))
    return out
  end
  return HINT
end

function M.render()
  if not valid_win() then
    return
  end
  if #M.runs == 0 then
    vim.wo[M.win].winbar = "%#AediTabFill#%=" .. require("aedi.hints").statusline(EMPTY_HINT)
    return
  end
  local tabs = {}
  for i, run in ipairs(M.runs) do
    local icon_group = (run.idle and nil)
      or (running(run) and "AediRunning")
      or (run.stopping and nil)
      or (run.code == 0 and "AediPassed" or "AediFailed")
    local tail = ""
    if not running(run) and not run.idle then
      tail = (run.code ~= 0 and not run.stopping) and tostring(run.code) or duration(run)
    end
    tabs[#tabs + 1] = {
      text = run.config.name,
      icon = status(run),
      icon_group = icon_group,
      tail = tail,
      selected = i == M.current,
      click = "AediConsoleTab",
      id = i,
    }
  end
  local focused = vim.api.nvim_get_current_win() == M.win
  vim.wo[M.win].winbar = require("aedi.tabs").render(tabs, focused)
    .. "%="
    .. require("aedi.hints").statusline(hint_for(M.current_run()))
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function open_win()
  local prev = vim.api.nvim_get_current_win()
  vim.cmd(("botright %dsplit"):format(require("aedi.config").options.console.height))
  M.win = vim.api.nvim_get_current_win()
  vim.wo[M.win].winfixheight = true
  util.bare(M.win)
  util.panel(M.win)
  if vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
end

--- Show the panel (on the current run), keeping focus where it is.
---@param focus? boolean
function M.show(focus)
  local run = M.current_run()
  if valid_win() and not M.visible() then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  if not valid_win() then
    open_win()
  end
  local buf = run and run.buf or empty()
  if vim.api.nvim_win_get_buf(M.win) ~= buf then
    vim.api.nvim_win_set_buf(M.win, buf)
    util.bare(M.win)
  end
  if run and run.to_end then
    run.to_end = nil
    pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
  M.render()
  if focus then
    vim.api.nvim_set_current_win(M.win)
  end
end

function M.hide()
  if valid_win() then
    -- the last window of a tab cannot be closed; leave it be
    pcall(vim.api.nvim_win_close, M.win, false)
  end
  M.win = nil
end

--- The code window you were in last (this tab).
---@type integer?
M.last_code = nil

--- Back to the code: the window you were in last, else any in this tab.
function M.to_editor()
  local win = M.last_code
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()) then
    win = util.code_win()
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("wincmd p")
  end
end

--- IntelliJ's cmd+4: open and focus; focused already, hide.
function M.toggle()
  if M.visible() and vim.api.nvim_get_current_win() == M.win then
    M.hide()
    M.to_editor()
  elseif M.visible() then
    vim.api.nvim_set_current_win(M.win)
  else
    M.show(true)
  end
end

---@param i integer
function M.select(i)
  if not M.runs[i] then
    return
  end
  M.current = i
  M.show()
end

---@param delta integer
function M.cycle(delta)
  if #M.runs == 0 then
    return
  end
  M.select(((M.current or 1) - 1 + delta) % #M.runs + 1)
end

-- ---------------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------------

---@param run aedi.Run
local function index_of(run)
  for i, r in ipairs(M.runs) do
    if r == run then
      return i
    end
  end
end

--- Ctrl-C into the terminal -- the program sees what a terminal gives it --
--- and, when it is already stopping, kill.
---@param run? aedi.Run
function M.stop(run)
  run = run or M.current_run()
  if not (run and running(run)) then
    return false
  end
  if run.external then
    run.stopping = true
    if run.stop then
      run.stop()
    end
    M.render()
    return true
  end
  if run.stopping then
    vim.fn.jobstop(run.job)
  else
    run.stopping = true
    pcall(vim.api.nvim_chan_send, run.job, "\3")
  end
  M.render()
  return true
end

---@param i? integer
function M.close(i)
  i = i or M.current
  local run = i and M.runs[i]
  if not run then
    return
  end
  if run.external then
    -- the buffer is its owner's; a running program stops with its tab
    if running(run) and run.stop then
      run.stop()
    end
    M.forget(run)
    return
  end
  if running(run) then
    vim.fn.jobstop(run.job)
  end
  M.forget(run)
  if vim.api.nvim_buf_is_valid(run.buf) then
    pcall(vim.api.nvim_buf_delete, run.buf, { force = true })
  end
end

--- Take `run` off the panel (its buffer is gone or going).
---@param run aedi.Run
function M.forget(run)
  local i = index_of(run)
  if not i then
    return
  end
  table.remove(M.runs, i)
  if #M.runs == 0 then
    -- the panel stays, empty: closing the last tab is not closing the panel
    M.current = nil
    if valid_win() then
      M.show()
    end
    return
  end
  if M.current > i then
    M.current = M.current - 1
  end
  M.current = math.max(1, math.min(M.current, #M.runs))
  if valid_win() then
    M.show()
  end
end

local function map(buf, run)
  -- No smooth scrolling (snacks.scroll) in output: following the end moves
  -- the cursor there at once, and an animation still on its way down looked
  -- like you had scrolled up, so the tab stopped following.
  vim.b[buf].snacks_scroll = false
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  k("q", M.hide, "Hide the Run panel")
  k("<Esc>", M.to_editor, "Back to the editor")
  k("r", function()
    if run.external then
      if M.last_launch then
        M.start(M.last_launch.config, { debug = M.last_launch.debug })
      elseif run.rerun then
        run.rerun()
      end
    else
      M.start(run.config)
    end
  end, "Rerun")
  k("<C-c>", function()
    M.stop(run)
  end, "Stop (again: kill)")
  k("d", function()
    local c = run.external and M.last_launch and M.last_launch.config or run.config
    M.start(c, { debug = true })
  end, "Debug it")
  k("x", function()
    M.close(index_of(run))
  end, "Close the tab")
  k("e", function()
    if run.external then
      vim.notify(run.config.name .. " is not a run configuration of aedi's", vim.log.levels.INFO)
      return
    end
    require("aedi.editor").open(run.config)
  end, "Edit the configuration")
  k("<CR>", function()
    M.follow_link(run)
  end, "Open the location under the cursor")
  for _, lhs in ipairs({ "<Tab>", "<C-S-l>", "<C-S-j>" }) do
    k(lhs, function()
      M.cycle(1)
    end, "Next run")
  end
  for _, lhs in ipairs({ "<S-Tab>", "<C-S-h>", "<C-S-k>" }) do
    k(lhs, function()
      M.cycle(-1)
    end, "Previous run")
  end
end

--- `<CR>`: the file or stack frame under the cursor. A terminal breaks a
--- long line at the window's width, so the line is also tried joined to the
--- ones around it.
---@param run aedi.Run
function M.follow_link(run)
  local links = require("aedi.links")
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(run.buf, math.max(row - 2, 0), row + 1, false)
  local first = math.max(row - 2, 0) + 1
  local cur = lines[row - first + 1] or ""
  local prev = row > 1 and lines[1] or ""
  local nxt = lines[row - first + 2] or ""
  local tries = {
    { cur, col + 1 },
    { prev .. cur, #prev + col + 1 },
    { cur .. nxt, col + 1 },
    { prev .. cur .. nxt, #prev + col + 1 },
  }
  local candidates = {}
  for _, t in ipairs(tries) do
    vim.list_extend(candidates, links.candidates(t[1], t[2]))
  end
  if #candidates == 0 then
    return
  end
  local from = vim.api.nvim_get_current_win()
  M.to_editor()
  local win = vim.api.nvim_get_current_win()
  if win == M.win then
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
  end
  for _, loc in ipairs(candidates) do
    if links.open(loc, { run.cwd, util.root() }, win) then
      return
    end
  end
  if vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
  local loc = candidates[1]
  vim.notify("Not found: " .. (loc.file or (loc.frame and loc.frame.file) or "?"), vim.log.levels.WARN)
end

--- Run `c` in its tab (a new one, or the one it ran in before).
---@param c aedi.Configuration
---@return aedi.Run?
---@param opts? { debug?: boolean }
function M.start(c, opts)
  local debug = opts and opts.debug
  local types = require("aedi.types")
  local launch, err = types.build(c, util.root())
  if not launch then
    vim.notify(("Cannot run %s: %s"):format(c.name, err), vim.log.levels.ERROR)
    return
  end
  -- Through the IntelliJ server: its output is the IntelliJ tab of this
  -- panel (lua/aedi/integrations/intellij_lsp.lua), a debug session the
  -- Debug panel.
  if launch.intellij then
    -- the program's environment: the project's mise, then the configuration's
    launch.intellij.env = require("aedi.env").merge(util.root(), launch.intellij.env)
    if require("aedi.jvm").launch(launch.intellij, debug) then
      require("aedi.store").set_last(c)
      M.last_launch = { config = vim.deepcopy(c), debug = debug }
    end
    return
  end
  if debug then
    vim.notify(("%s cannot be debugged: a %s runs in a terminal, not under the debugger"):format(c.name, types.label(c)), vim.log.levels.WARN)
    return
  end
  local cwd = launch.cwd
  if not vim.uv.fs_stat(cwd) then
    vim.notify(("Working directory does not exist: %s"):format(cwd), vim.log.levels.ERROR)
    return
  end
  local slot
  for i, r in ipairs(M.runs) do
    if r.config.name == c.name and not r.external then
      slot = i
      break
    end
  end
  local old = slot and M.runs[slot]
  if old and running(old) then
    vim.fn.jobstop(old.job)
  end

  next_id = next_id + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  ---@type aedi.Run
  local run = { id = next_id, config = vim.deepcopy(c), buf = buf, cwd = cwd, started = vim.uv.now() }
  if slot then
    M.runs[slot] = run
  else
    M.runs[#M.runs + 1] = run
    slot = #M.runs
  end
  M.current = slot
  M.show()

  local line = launch.cmd
  -- The command first, dimmed, as IntelliJ prints the command line it ran.
  local header = ("printf '\\033[2m%%s\\033[0m\\n' %s; "):format(vim.fn.shellescape("$ " .. line))
  vim.api.nvim_win_call(M.win, function()
    run.job = vim.fn.jobstart({ vim.o.shell, "-c", header .. line }, {
      term = true,
      cwd = cwd,
      -- the project's mise environment (JAVA_HOME, PATH, ...), then the
      -- configuration's own
      env = require("aedi.env").merge(util.root(), launch.env),
      on_exit = function(_, code)
        run.code = code
        run.ended = vim.uv.now()
        vim.schedule(function()
          M.render()
          if index_of(run) and not M.visible() then
            local ok = code == 0 or run.stopping
            vim.notify(
              ("%s %s"):format(c.name, run.stopping and "stopped" or (code == 0 and "finished" or ("failed (" .. code .. ")"))),
              ok and vim.log.levels.INFO or vim.log.levels.ERROR
            )
          end
        end)
      end,
    })
  end)
  if not run.job or run.job <= 0 then
    run.code, run.ended, run.job = -1, vim.uv.now(), nil
    vim.notify("Could not start: " .. line, vim.log.levels.ERROR)
  end
  vim.bo[buf].filetype = "aedi-console"
  map(buf, run)
  require("aedi.grep").attach(buf)
  -- A key pressed in terminal mode after the process ended wipes the buffer
  -- (Neovim's own behaviour); the tab goes with it.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        M.forget(run)
      end)
    end,
  })
  -- Terminal mode left with <C-\><C-n> lands on the last line, so the window
  -- keeps following the output.
  pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(buf), 0 })
  if old and vim.api.nvim_buf_is_valid(old.buf) then
    pcall(vim.api.nvim_buf_delete, old.buf, { force = true })
  end
  M.render()
  require("aedi.store").set_last(c)
  return run
end

--- A tab for output another plugin writes into a buffer of its own (an
--- IntelliJ launch): `key` names the tab, so the same producer keeps one.
--- Starts idle (○); `set_state` says when its program runs and ends.
---@param spec { key: string, name: string, buf: integer, stop?: fun(), rerun?: fun(), cwd?: string }
---@return aedi.Run
function M.external(spec)
  local run
  for _, r in ipairs(M.runs) do
    if r.external and r.key == spec.key then
      run = r
    end
  end
  if not run then
    next_id = next_id + 1
    run = {
      id = next_id,
      key = spec.key,
      external = true,
      idle = true,
      config = { name = spec.name },
      started = vim.uv.now(),
    }
    M.runs[#M.runs + 1] = run
  end
  run.config.name = spec.name or run.config.name
  run.stop, run.rerun = spec.stop, spec.rerun
  run.cwd = spec.cwd or util.root()
  if run.buf ~= spec.buf then
    run.buf = spec.buf
    map(spec.buf, run)
    require("aedi.grep").attach(spec.buf)
    -- Follow the end of the output while the cursor is on the last line, as
    -- a terminal tab does (its producer follows only its own window).
    vim.api.nvim_buf_attach(spec.buf, false, {
      on_lines = function(_, b, _, first)
        if run.buf ~= b then
          return true
        end
        vim.schedule(function()
          if valid_win() and vim.api.nvim_win_get_buf(M.win) == b and vim.api.nvim_buf_is_valid(b) then
            if vim.api.nvim_win_get_cursor(M.win)[1] >= first then
              pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(b), 0 })
            end
          end
        end)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = spec.buf,
      once = true,
      callback = function()
        vim.schedule(function()
          if run.buf == spec.buf then
            M.forget(run)
          end
        end)
      end,
    })
  end
  M.render()
  return run
end

--- An external tab's program started ("running") or ended ("exited").
---@param run aedi.Run
---@param state "running"|"exited"
---@param code? integer
function M.set_state(run, state, code)
  if state == "running" then
    run.idle, run.code, run.ended, run.stopping = false, nil, nil, nil
    run.started = vim.uv.now()
    -- A new run follows its output again, however far up the last one was
    -- left (its buffer is reused): now if it is on screen, else when shown.
    run.to_end = true
    if valid_win() and vim.api.nvim_win_get_buf(M.win) == run.buf then
      run.to_end = nil
      pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(run.buf), 0 })
    end
  else
    if run.idle or run.code ~= nil then
      return
    end
    run.code = code or 0
    run.ended = vim.uv.now()
    if not M.visible() then
      vim.notify(
        ("%s %s"):format(run.config.name, run.stopping and "stopped" or (run.code == 0 and "finished" or ("failed (" .. run.code .. ")"))),
        (run.code == 0 or run.stopping) and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end
  end
  M.render()
end

--- Show `run`'s tab.
---@param run aedi.Run
---@param focus? boolean
function M.show_run(run, focus)
  local i = index_of(run)
  if i then
    M.current = i
    M.show(focus)
  end
end

function M.setup()
  -- However the panel goes -- q, the toggle, a :close or a close-window key
  -- of your own -- focus lands back in the code you came from, not wherever
  -- Neovim's own rules put it (the explorer, as often as not).
  local group = vim.api.nvim_create_augroup("aedi_console_focus", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if util.is_code_win(win) then
        M.last_code = win
      end
      -- the current tab's edge is accented only while the panel has focus
      if valid_win() then
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed or closed ~= M.win then
        return
      end
      local was_current = vim.api.nvim_get_current_win() == closed
      M.win = nil
      if was_current then
        vim.schedule(function()
          if not util.is_code_win(vim.api.nvim_get_current_win()) then
            M.to_editor()
          end
        end)
      end
    end,
  })
  local function link(name, to)
    vim.api.nvim_set_hl(0, name, { link = to, default = true })
  end
  require("aedi.tabs").setup()
  link("AediRunning", "DiagnosticInfo")
  link("AediPassed", "DiagnosticOk")
  link("AediFailed", "DiagnosticError")
end

return M
