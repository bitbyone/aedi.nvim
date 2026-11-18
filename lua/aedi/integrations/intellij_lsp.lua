-- intellij-lsp.nvim (JetBrains' IntelliJ language server) and the debug
-- strip.
--
--   require("aedi.integrations.intellij_lsp").setup()
--
-- after `require("intellij-lsp").setup()`. Its sessions (`intellij_jvm`) get
-- the strip, with the plugin's run output as the Console tab -- and while
-- the strip is up, the plugin opening its own output panel lands in that tab
-- instead of a second log across the bottom. Plain runs and test runs
-- (`noDebug`) keep the output panel as their whole UI.

local M = {}

local done = false

function M.setup()
  if done then
    return
  end
  done = true
  local output = require("intellij-lsp.output")
  local view = require("aedi.debug.view")
  local open = output.open
  output.open = function(opts)
    local win = view.console_win()
    if win then
      return win
    end
    return open(opts)
  end
  require("aedi.debug").listen(function(session)
    return session.config.type == "intellij_jvm"
  end, output)
end

return M
