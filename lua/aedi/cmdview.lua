-- `c` in the Run panel: what the current tab runs, in full, in a popup --
-- IntelliJ's command line at the top of a run, without it in the log.
--
--   JAVA        ~/.local/share/mise/installs/java/temurin-25.0.5+8.0.LTS/bin/java
--   VM          -Xmx256m
--               -Dwho=world
--   MAIN        x.Main
--   ARGS        a b
--   ENV         JAVA_HOME=...
--   CLASSPATH   42 entries
--               ~/proj/app/build/classes/java/main
--               ...
--
-- `y` copies the whole command line; `q` / Esc close.

local M = {}

local ns = vim.api.nvim_create_namespace("aedi_cmdview")
local LABEL = 12

local function short(p)
  return vim.fn.fnamemodify(p, ":~")
end

--- Lines and their label rows for `run`.
---@param run aedi.Run
---@return string[] lines, integer[] label_rows, string? full the copyable command line
local function content(run)
  local lines, labels = {}, {}
  local function field(label, values)
    if type(values) ~= "table" then
      values = { values }
    end
    if #values == 0 then
      return
    end
    for i, v in ipairs(values) do
      if i == 1 then
        labels[#labels + 1] = #lines
      end
      lines[#lines + 1] = ("%-" .. LABEL .. "s%s"):format(i == 1 and label or "", v)
    end
  end
  local function env_lines(env)
    local keys = vim.tbl_keys(env or {})
    table.sort(keys)
    return vim.tbl_map(function(k)
      return k .. "=" .. env[k]
    end, keys)
  end

  local c = run.command
  if run.external then
    if not c then
      return { "Nothing launched in this tab yet." }, {}, nil
    end
    if c.pending then
      return { "Waiting for the JVM to start (the build runs first)…" }, {}, nil
    end
    local jvm = require("aedi.jvmcmd").parse(c.cmd, c.main)
    field("JAVA", short(jvm.java))
    field("VM", jvm.vm)
    field("MAIN", jvm.main)
    field("ARGS", #jvm.args > 0 and table.concat(jvm.args, " ") or {})
    field("ENV", env_lines(c.env))
    -- last: it is the long one
    if #jvm.classpath > 0 then
      field("CLASSPATH", ("%d entr%s"):format(#jvm.classpath, #jvm.classpath == 1 and "y" or "ies"))
      for _, e in ipairs(jvm.classpath) do
        lines[#lines + 1] = (" "):rep(LABEL) .. short(e)
      end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = c.by_mark and ("%s, the process this launch started."):format(c.debug and "Debug" or "Run")
      or "Matched by main class: a Run lens launch carries no mark of aedi's."
    return lines, labels, c.cmd
  end

  -- a terminal tab
  c = c or {}
  field("COMMAND", c.cmd or "?")
  field("DIRECTORY", c.cwd and short(c.cwd) or "?")
  field("ENV", env_lines(c.env))
  if c.mise then
    field("MISE", c.mise)
  end
  return lines, labels, c.cmd
end

---@param run? aedi.Run
function M.open(run)
  if not run then
    return
  end
  local lines, labels, full = content(run)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, row in ipairs(labels) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = LABEL, hl_group = "AediFormLabel" })
  end
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 8)
  local hints = { { "y", "copy the command line" }, { "q", "close" } }
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = { { " " .. run.config.name .. " · command line ", "FloatTitle" } },
    title_pos = "left",
    footer = require("aedi.hints").chunks(full and hints or { hints[2] }),
    footer_pos = "left",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].list = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function k(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  k("q", close)
  k("<Esc>", close)
  k("y", function()
    if full then
      vim.fn.setreg("+", full)
      vim.fn.setreg('"', full)
      vim.notify("Copied the command line", vim.log.levels.INFO)
    end
  end)
end

return M
