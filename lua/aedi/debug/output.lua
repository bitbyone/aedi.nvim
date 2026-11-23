-- A debug adapter that runs the program itself (no terminal of aedi's) and
-- sends what it prints as DAP `output` events: that output as a tab of the
-- Run panel, and as the Debug panel's Console while its session runs.
--
--   require("aedi.debug").output_tab({
--     name = "Game",   -- the tab's name until a session names it
--     match = function(session) return session.config.type == "my_engine" end,
--   })
--
-- One buffer per tab, started afresh by every session. The tab is ● while
-- the session runs; `r` runs the last session again (nvim-dap's run_last),
-- Ctrl-C ends it. Call it after nvim-dap-ui is configured (it wraps dap-ui's
-- listeners, as `listen` does).

---@class aedi.OutputTabSpec
---@field name string
---@field match fun(session: dap.Session): boolean
---@field key? string the tab's identity (default: the name)
---@field cwd? fun(): string where relative paths in the output are looked up

---@param spec aedi.OutputTabSpec
---@return { buf: fun(): integer } the tab's output buffer
return function(spec)
  local dap = require("dap")
  local console = require("aedi.console")
  local view = require("aedi.debug.view")
  local key = spec.key or spec.name
  local id = "aedi.output." .. key

  local buf
  local function output_buf()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].filetype = "aedi-console"
      pcall(vim.api.nvim_buf_set_name, buf, "aedi://" .. key)
    end
    return buf
  end

  local tab
  local function ensure(name)
    tab = console.external({
      key = key,
      name = name or (tab and tab.config.name) or spec.name,
      buf = output_buf(),
      cwd = spec.cwd and spec.cwd() or nil,
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
    return session ~= nil and session.config ~= nil and spec.match(session)
  end

  dap.listeners.after.event_initialized[id] = function(session)
    if not ours(session) then
      return
    end
    vim.api.nvim_buf_set_lines(output_buf(), 0, -1, false, {})
    console.set_state(ensure(session.config.name), "running")
  end
  dap.listeners.after.event_output[id] = function(session, body)
    if not ours(session) or not (body and body.output) or body.category == "telemetry" then
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
  dap.listeners.after.event_terminated[id] = ended
  dap.listeners.after.disconnect[id] = ended

  require("aedi.debug").listen(ours, {
    buf = output_buf,
    is_open = showing,
    close = function()
      if showing() then
        console.hide()
      end
    end,
    open = function(o)
      if view.console_win() then
        return
      end
      console.show_run(ensure(), not (o and o.focus == false))
    end,
  })
  return { buf = output_buf }
end
