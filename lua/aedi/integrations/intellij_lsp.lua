-- intellij-lsp.nvim (JetBrains' IntelliJ language server) and aedi's panels.
--
--   require("aedi.integrations.intellij_lsp").setup()
--
-- after `require("intellij-lsp").setup()`.
--
--   * Its output panel (a launched main class, a test run, the build's import
--     log) is a tab of the Run panel, "IntelliJ" until a program runs, then
--     named after it. ● while it runs, then its exit code; `r` runs it again
--     (nvim-dap's run_last), Ctrl-C stops it.
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
  local function ours(session)
    return session and session.config and session.config.type == "intellij_jvm"
  end
  dap.listeners.after.event_initialized["aedi.intellij_lsp"] = function(session)
    if not ours(session) then
      return
    end
    local name = session.config.mainClass and session.config.mainClass:match("[^.]+$") or session.config.name
    console.set_state(ensure(name), "running")
  end
  local exit_codes = {}
  dap.listeners.after.event_exited["aedi.intellij_lsp"] = function(session, body)
    if ours(session) then
      exit_codes[session.id] = body and body.exitCode
    end
  end
  dap.listeners.after.event_terminated["aedi.intellij_lsp"] = function(session)
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
