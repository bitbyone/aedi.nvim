-- Debugging: nvim-dap-ui laid out like IntelliJ's Debug tool window.
--
--   * the Debug panel (lua/aedi/debug/view.lua): frames, variables and
--     watches across the bottom, a Console tab beside Variables
--   * long values (a record's toString) in a framed, wrapped popup instead
--     of dap-ui's borderless strip across the next panels
--     (lua/aedi/debug/hover.lua)
--   * no editor gutter in dap-ui's panels, and no empty line after every
--     thread in the frames list
--
-- In your dap-ui spec:
--
--   opts = function(_, opts)
--     require("aedi.debug").patch_dapui()
--     return vim.tbl_deep_extend("force", opts, { layouts = require("aedi.debug").layouts })
--   end
--
-- and say which sessions get the Debug panel:
--
--   require("aedi.debug").listen(function(session) return session.config.type == "go" end)

local M = {}

--- dap-ui's layouts: 1 is the Debug panel (lua/aedi/debug/view.lua needs scopes in it),
--- 2 the REPL and console on the right, which the Debug panel does not open.
M.layouts = {
  {
    position = "bottom",
    size = 15,
    elements = {
      { id = "stacks", size = 0.2 },
      { id = "scopes", size = 0.65 },
      { id = "watches", size = 0.15 },
    },
  },
  {
    position = "right",
    size = 70,
    elements = {
      { id = "console", size = 0.6 },
      { id = "repl", size = 0.4 },
    },
  },
}

--- Patch dap-ui as it loads, before its setup: the framed value popup and
--- the compact frames list.
function M.patch_dapui()
  require("aedi.debug.hover").install()
  -- The frames list puts an empty line after every thread, which with the
  -- JVM's eight or so threads is half the panel spent on nothing. The threads
  -- component is the only place in dap-ui that writes a literal "\n\n", so
  -- shortening exactly that write compacts the list and touches nothing else.
  -- The module exports only `new`; every canvas has the method table as its
  -- metatable, which is where `write` is patched.
  local ok, canvas = pcall(require, "dapui.render.canvas")
  local Canvas = ok and getmetatable(canvas.new()) or nil
  if Canvas and not Canvas._aedi_compact then
    Canvas._aedi_compact = true
    local write = Canvas.write
    Canvas.write = function(self, text, ...)
      if text == "\n\n" then
        text = "\n"
      end
      return write(self, text, ...)
    end
  end
end

--- Sessions `match` accepts get the Debug panel instead of dap-ui's own
--- listeners (every other adapter keeps those). A session with `noDebug`
--- (a plain run) gets no UI at all. `console` is where its Console comes
--- from (default: aedi's Run panel).
---
--- LazyVim's dap-ui listeners (`dapui_config`) are wrapped, not replaced, so
--- call this after nvim-dap-ui is configured.
---@param match fun(session: dap.Session): boolean
---@param console? aedi.ConsoleProvider
function M.listen(match, console)
  local view = require("aedi.debug.view")
  local listeners = require("dap").listeners
  local function ours(session)
    return session and session.config and match(session)
  end
  local init = listeners.after.event_initialized["dapui_config"]
  listeners.after.event_initialized["dapui_config"] = function(session, ...)
    if not ours(session) then
      return init and init(session, ...)
    end
    if session.config.noDebug then
      return
    end
    view.start(console)
  end
  for _, event in ipairs({ "event_terminated", "event_exited" }) do
    local close = listeners.before[event]["dapui_config"]
    listeners.before[event]["dapui_config"] = function(session, ...)
      if not ours(session) then
        return close and close(session, ...)
      end
      if session.config.noDebug or not view.active() then
        return
      end
      vim.schedule(view.stop)
    end
  end
end

--- Show / hide the Debug panel while a session runs.
function M.toggle()
  require("aedi.debug.view").toggle()
end

function M.setup()
  require("aedi.debug.view").setup()
  -- dap-ui's windows inherit the editor's gutter -- a statuscolumn, the sign
  -- and fold columns -- which in a panel is a strip of empty margin down the
  -- left of every element. Panels get none. BufWinEnter as well as FileType:
  -- dap-ui sets the filetype before the buffer has a window, and reuses
  -- buffers across opens.
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("aedi_dapui_gutter", { clear = true }),
    callback = function(args)
      local ft = vim.bo[args.buf].filetype
      if not (ft:find("^dapui_") or ft == "dap-repl") then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then
          return
        end
        for _, win in ipairs(vim.fn.win_findbuf(args.buf)) do
          require("aedi.util").bare(win)
        end
      end)
    end,
  })
end

return M
