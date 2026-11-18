-- The Debug panel: IntelliJ's Debug tool window, in the view you are already
-- in. nvim-dap-ui's layout 1 -- frames, variables, watches -- as one strip
-- across the bottom of the tab, under the explorer, the editor and whatever
-- else is open. Nothing else about the layout changes. `toggle()` hides the
-- panel and brings it back while the session runs; it goes away by itself
-- when the session ends.
--
-- The variables window has two tabs, Variables and Console (the program's
-- output), as IntelliJ's Debugger / Console tabs; <C-S-h>/<C-S-l> (and
-- <C-S-j>/<C-S-k>) switch them while it has focus. dap-ui's layout 2 (REPL
-- and console) is not opened; its console would be a second copy of the
-- output.
--
-- Which sessions get the Debug panel, and where their Console comes from, is up to
-- `listen()` (lua/aedi/debug/init.lua); an integration such as
-- lua/aedi/integrations/intellij_lsp.lua registers its own. Without a
-- console of its own, a session's Console is the current tab of aedi's Run
-- panel.

local M = {}

--- A debug session is running (the Debug panel may be hidden).
M.on = false
---@type integer? the variables window
M.win = nil
M.console = false

local CHORDS = { "<C-S-h>", "<C-S-l>", "<C-S-j>", "<C-S-k>" }

local util = require("aedi.util")

---@class aedi.ConsoleProvider
---@field buf fun(): integer? the output buffer
---@field is_open fun(): boolean its own window is up
---@field close fun() close its own window
---@field open fun(opts: { focus: boolean }) reopen its own window

--- The console of the running session (set by `start`).
---@type aedi.ConsoleProvider?
M.provider = nil

--- aedi's Run panel as a console: its current tab.
---@type aedi.ConsoleProvider
M.panel_console = {
  buf = function()
    local run = require("aedi.console").current_run()
    return run and vim.api.nvim_buf_is_valid(run.buf) and run.buf or nil
  end,
  is_open = function()
    return require("aedi.console").visible()
  end,
  close = function()
    require("aedi.console").hide()
  end,
  open = function(opts)
    if require("aedi.console").current_run() then
      require("aedi.console").show(opts and opts.focus)
    end
  end,
}

local function output_mod()
  local p = M.provider
  if p and p.buf() then
    return p
  end
end

local function layout1()
  local ok, windows = pcall(require, "dapui.windows")
  return ok and windows.layouts[1] or nil
end

local function code_win()
  return util.code_win()
end

--- Is the debug session running?
function M.active()
  return M.on
end

--- Is the Debug panel on screen?
function M.visible()
  local layout = layout1()
  return M.on and layout ~= nil and layout:is_open()
end

-- ---------------------------------------------------------------------------
-- Variables | Console
-- ---------------------------------------------------------------------------

local function render_winbar()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  util.panel(M.win)
  local focused = vim.api.nvim_get_current_win() == M.win
  vim.wo[M.win].winbar = require("aedi.tabs").render({
    { text = "Variables", selected = not M.console },
    { text = "Console", selected = M.console },
  }, focused)
end

local function follow_tail()
  local output = output_mod()
  if M.console and output and M.win and vim.api.nvim_win_is_valid(M.win) then
    local buf = output.buf()
    if vim.api.nvim_win_get_buf(M.win) == buf then
      pcall(vim.api.nvim_win_set_cursor, M.win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

--- Flip the variables window between its two tabs.
function M.switch()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  M.console = not M.console
  -- dap-ui keeps its windows on their own buffers (`force_buffers`) through
  -- the getter `attach` wrapped, so the getter decides and this just asks.
  pcall(vim.api.nvim_win_set_buf, M.win, M.getter())
  render_winbar()
  follow_tail()
end

local function map_chords(buf)
  for _, lhs in ipairs(CHORDS) do
    vim.keymap.set("n", lhs, function()
      if vim.api.nvim_get_current_win() == M.win then
        M.switch()
      end
    end, { buffer = buf, desc = "Variables / Console" })
  end
end

--- Focus back to the code: the window the session started from, else the
--- first one holding a file.
function M.to_editor()
  local win = M.home_win
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()) then
    win = code_win()
  end
  if win then
    vim.api.nvim_set_current_win(win)
  end
end

--- The run output's own <Esc> closes its panel; in the Console tab that would
--- close the variables window, so it is swapped for the jump while attached
--- and put back after.
local saved_esc

local function map_output_esc(buf)
  local m = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("<Esc>", "n", false, true)
  end)
  saved_esc = (m and m.buffer == 1) and m or false
  vim.keymap.set("n", "<Esc>", M.to_editor, { buffer = buf, desc = "Back to the editor" })
end

local function unmap_output_esc(buf)
  if saved_esc == nil or not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
  if saved_esc then
    vim.api.nvim_buf_call(buf, function()
      vim.fn.mapset("n", false, saved_esc)
    end)
  end
  saved_esc = nil
end

local function unmap_chords(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in ipairs(CHORDS) do
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
end

--- After dap-ui has opened layout 1: give its variables window the Console
--- tab, and take the run output's own window away -- the output lives in the
--- Debug panel now.
local function attach()
  local output = output_mod()
  local layout = layout1()
  if not (output and layout) then
    return
  end
  M.win, M.console = nil, false
  for win, get in pairs(layout.win_bufs) do
    if vim.api.nvim_win_is_valid(win) and vim.bo[get()].filetype == "dapui_scopes" then
      M.win = win
      local scopes = get
      M.scopes_buf = scopes()
      M.getter = function()
        return M.console and output.buf() or scopes()
      end
      layout.win_bufs[win] = M.getter
      break
    end
  end
  if not M.win then
    return
  end
  if output.is_open() then
    output.close()
  end
  map_chords(M.scopes_buf)
  map_chords(output.buf())
  map_output_esc(output.buf())
  if not M.attached_buf then
    M.attached_buf = output.buf()
    vim.api.nvim_buf_attach(M.attached_buf, false, {
      on_lines = function()
        if not M.on then
          M.attached_buf = nil
          return true
        end
        vim.schedule(follow_tail)
      end,
    })
  end
  render_winbar()
end

--- Undo `attach` before the Debug panel closes: the variables window back on its
--- own buffer -- closing it while it shows the run output must not take the
--- output buffer with it -- and the chords off both buffers.
local function detach()
  if M.console and M.win and vim.api.nvim_win_is_valid(M.win) and M.scopes_buf and vim.api.nvim_buf_is_valid(M.scopes_buf) then
    M.console = false
    pcall(vim.api.nvim_win_set_buf, M.win, M.scopes_buf)
  end
  unmap_chords(M.scopes_buf)
  local output = output_mod()
  unmap_chords(output and output.buf())
  unmap_output_esc(output and output.buf())
  M.win, M.console, M.scopes_buf = nil, false, nil
end

--- The run output's window while the Debug panel is up: the Console tab, so the
--- plugin opening its panel on a session's first output does not put a second
--- window across the bottom.
---@return integer?
function M.console_win()
  if M.visible() and M.win and vim.api.nvim_win_is_valid(M.win) then
    return M.win
  end
end

--- The Debug panel back to its configured sizes (15 rows; 0.2 / 0.65 / 0.15
--- across). dap-ui remembers whatever sizes it had when it was last closed,
--- and a sidebar re-laid after it opened takes rows back.
local function fit()
  vim.schedule(function()
    local layout = layout1()
    if layout and M.visible() then
      pcall(layout.resize, layout, { reset = true })
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Sidebars
-- ---------------------------------------------------------------------------

--- Sidebar pickers (the explorer) in the current tab: their layout box is a
--- split carrying `w:snacks_layout`; float pickers have no split.
---@return table<integer, boolean>
local function sidebars()
  local set = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].snacks_layout and vim.api.nvim_win_get_config(win).relative == "" then
      set[win] = true
    end
  end
  return set
end

--- The sidebars the Debug panel was laid out under.
local known = {}

--- Open the Debug panel, keeping focus where it was.
function M.show()
  if not M.on or M.visible() then
    return
  end
  local ok, dapui = pcall(require, "dapui")
  if not ok then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  dapui.open({ layout = 1 })
  attach()
  fit()
  known = sidebars()
  if vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
end

--- Close the Debug panel; the session keeps running.
function M.hide()
  if not M.visible() then
    return
  end
  detach()
  local ok, dapui = pcall(require, "dapui")
  if ok then
    dapui.close({ layout = 1 })
  end
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

--- Autocommands: <Esc> out of dap-ui panes, and the Debug panel laid out again
--- under a sidebar opened while it is up.
function M.setup()
  -- the current tab's edge is accented only while the window has focus
  vim.api.nvim_create_autocmd("WinEnter", {
    group = vim.api.nvim_create_augroup("aedi_debug_tabs", { clear = true }),
    callback = function()
      if M.on and M.win and vim.api.nvim_win_is_valid(M.win) then
        render_winbar()
      end
    end,
  })
  -- <Esc> in any dap-ui pane goes back to the editor, the way it leaves a tool
  -- window in IntelliJ. Normal mode only: in the Watches prompt <Esc> still
  -- just leaves insert mode first.
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("DebugViewEsc", { clear = true }),
    pattern = { "dapui_scopes", "dapui_stacks", "dapui_watches", "dapui_breakpoints", "dapui_console", "dap-repl" },
    callback = function(ev)
      vim.keymap.set("n", "<Esc>", M.to_editor, { buffer = ev.buf, desc = "Back to the editor" })
    end,
  })

  -- A sidebar opened while the Debug panel is up is a `topleft` split -- the whole
  -- height, with the Debug panel squeezed in beside it. Reopening the Debug panel puts it
  -- back under everything. Only a sidebar the Debug panel has not seen counts: every
  -- picker (recent files, go to class) fires this FileType too, and rebuilding
  -- the Debug panel under one moved focus out of it, which closed it on the spot.
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("DebugViewSidebar", { clear = true }),
    pattern = "snacks_picker_list",
    callback = function()
      vim.schedule(function()
        if not M.visible() then
          return
        end
        local now = sidebars()
        local new = false
        for win in pairs(now) do
          if not known[win] then
            new = true
          end
        end
        known = now
        if new then
          local cur = vim.api.nvim_get_current_win()
          M.hide()
          M.show()
          if vim.api.nvim_win_is_valid(cur) then
            vim.api.nvim_set_current_win(cur)
          end
        end
      end)
    end,
  })
end

--- A debug session started: the Debug panel comes up, focus stays in the code.
---@param provider? aedi.ConsoleProvider where its Console comes from
function M.start(provider)
  M.provider = provider or M.panel_console
  M.home_win = code_win()
  M.on = true
  M.show()
  if M.home_win and vim.api.nvim_win_is_valid(M.home_win) then
    vim.api.nvim_set_current_win(M.home_win)
  end
end

--- The session ended: the Debug panel goes, the run output comes back as its own
--- panel, and focus goes to the code.
function M.stop()
  if not M.on then
    return
  end
  M.hide()
  M.on = false
  local output = output_mod()
  if output then
    pcall(output.open, { focus = false })
  end
  -- The run output was opened with focus when the build started; without
  -- this the view came back with the log as its current window.
  M.to_editor()
end

--- `<leader>dv`: hide or show the Debug panel.
function M.toggle()
  if not M.on then
    vim.notify("No debug session", vim.log.levels.INFO)
    return
  end
  if M.visible() then
    M.hide()
  else
    M.show()
  end
end

return M
