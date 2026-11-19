-- intellij-lsp.nvim (JetBrains' IntelliJ language server) and aedi's panels.
--
--   require("aedi.integrations.intellij_lsp").setup()
--
-- after `require("intellij-lsp").setup()`.
--
--   * Its output panel (a launched main class, a test run, the build's import
--     log) is a tab of the Run panel, "IntelliJ" until a program runs, then
--     named after it (or after the aedi configuration that launched it). ●
--     while it runs, then its exit code; `r` runs it again, `d` in the
--     debugger, Ctrl-C stops it.
--   * Its debug sessions (`intellij_jvm`) get the Debug panel, with that same
--     output as the Console tab. Plain runs and test runs (`noDebug`) stay in
--     the Run panel.

local M = {}

local done = false

function M.setup()
  if done then
    return
  end
  done = true
  local output = require("intellij-lsp.output")
  local console = require("aedi.console")
  local view = require("aedi.debug.view")

  local tab
  local function ensure(name)
    tab = console.external({
      key = "intellij-lsp",
      name = name or (tab and tab.config.name) or "IntelliJ",
      buf = output.buf(),
      stop = function()
        require("intellij-lsp.run").stop()
      end,
      rerun = function()
        require("dap").run_last()
      end,
    })
    return tab
  end
  local function showing()
    return tab ~= nil and console.visible() and console.current_run() == tab
  end

  -- The plugin's own panel window is never opened: what it shows is the
  -- Run panel's tab (or, while the Debug panel is up, its Console tab).
  output.open = function(opts)
    local win = view.console_win()
    if win then
      return win
    end
    console.show_run(ensure(), not (opts and opts.focus == false))
    return console.win
  end
  output.is_open = showing
  output.close = function()
    if showing() then
      console.hide()
    end
  end

  local dap = require("dap")
  ---@type table<integer, fun()> the JVM watch of each session
  local watching = {}
  local function ours(session)
    return session and session.config and session.config.type == "intellij_jvm"
  end
  dap.listeners.after.event_initialized["aedi.intellij_lsp"] = function(session)
    if not ours(session) then
      return
    end
    local name
    if session.config.aedi then
      -- one of aedi's run configurations: its own name
      name = session.config.name
    else
      -- the Run lens: the class; `r` then reruns it, not an older aedi launch
      console.last_launch = nil
      name = session.config.mainClass and session.config.mainClass:match("[^.]+$") or session.config.name
    end
    console.set_state(ensure(name), "running")
    -- The JVM's actual command line, kept on the tab for `c` in the Run
    -- panel (nothing is written into the output): found once the build is
    -- through and the JVM is up.
    local main = session.config.mainClass
    tab.command = nil
    if main then
      local jvmcmd = require("aedi.jvmcmd")
      local mark = jvmcmd.mark_of(session.config.vmArgs)
      local this = tab
      this.command = { pending = true, main = main, env = session.config.env, debug = not session.config.noDebug }
      watching[session.id] = jvmcmd.watch({ mark = mark, main = main, before = not mark and jvmcmd.processes() or nil }, function(cmd, by_mark)
        this.command = { cmd = cmd, main = main, env = session.config.env, by_mark = by_mark, debug = not session.config.noDebug }
      end)
    end
  end
  local exit_codes = {}
  dap.listeners.after.event_exited["aedi.intellij_lsp"] = function(session, body)
    if ours(session) then
      exit_codes[session.id] = body and body.exitCode
    end
  end
  dap.listeners.after.event_terminated["aedi.intellij_lsp"] = function(session)
    if ours(session) and watching[session.id] then
      watching[session.id]()
      watching[session.id] = nil
    end
    if ours(session) and tab then
      console.set_state(tab, "exited", exit_codes[session.id])
      exit_codes[session.id] = nil
    end
  end

  require("aedi.debug").listen(function(session)
    return ours(session)
  end, output)
end

return M
