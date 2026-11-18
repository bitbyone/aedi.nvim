-- IntelliJ's Edit Configuration dialog, as a buffer: one field per line,
-- edited like any text. `:w` saves, `q` closes, <C-CR> saves and runs.
--
--   name:    App
--   command: go run ./cmd/server
--   args:    --port 8080
--   cwd:     services/api
--   env:     PORT=8080
--   env:     LOG_LEVEL=debug
--
-- `command` runs through 'shell' (pipes, `&&` and variables work); `args` is
-- appended to it; `cwd` is relative to the project root; one `env:` line per
-- variable. Lines starting with `#` are ignored.

local M = {}

local FIELDS = { "name", "command", "args", "cwd", "env" }

local HELP = {
  "# Run configuration. :w saves, <C-CR> saves and runs, q closes.",
  "# command runs through your shell in cwd (relative to the project root);",
  "# args are appended to it; one env: line per variable (KEY=value).",
  "",
}

--- The form's lines for `c`.
---@param c aedi.Configuration
---@return string[]
function M.render(c)
  local lines = vim.list_extend({}, HELP)
  local function field(k, v)
    lines[#lines + 1] = ("%-8s %s"):format(k .. ":", v or "")
  end
  field("name", c.name)
  field("command", c.command)
  field("args", c.args)
  field("cwd", c.cwd or ".")
  local keys = vim.tbl_keys(c.env or {})
  table.sort(keys)
  if #keys == 0 then
    field("env", "")
  end
  for _, k in ipairs(keys) do
    field("env", k .. "=" .. c.env[k])
  end
  return lines
end

--- A configuration from the form's lines, or an error.
---@param lines string[]
---@return aedi.Configuration?, string?
function M.parse(lines)
  local c = { env = {} }
  for i, line in ipairs(lines) do
    if not (line:match("^%s*#") or line:match("^%s*$")) then
      local key, value = line:match("^%s*(%w+)%s*:%s?(.*)$")
      if not key then
        return nil, ("line %d: expected `field: value`"):format(i)
      end
      value = vim.trim(value)
      if not vim.tbl_contains(FIELDS, key) then
        return nil, ("line %d: unknown field %q (fields: %s)"):format(i, key, table.concat(FIELDS, ", "))
      end
      if key == "env" then
        if value ~= "" then
          local k, v = value:match("^([%w_]+)=(.*)$")
          if not k then
            return nil, ("line %d: env needs KEY=value"):format(i)
          end
          c.env[k] = v
        end
      else
        c[key] = value
      end
    end
  end
  if not c.name or c.name == "" then
    return nil, "name is empty"
  end
  if not c.command or c.command == "" then
    return nil, "command is empty"
  end
  if c.args == "" then
    c.args = nil
  end
  if c.cwd == "" or c.cwd == "." then
    c.cwd = nil
  end
  if not next(c.env) then
    c.env = nil
  end
  return c
end

local function highlight(buf)
  local ns = vim.api.nvim_create_namespace("aedi_editor")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^%s*#") then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #line, hl_group = "Comment" })
    else
      local s, e = line:find("^%s*%w+:")
      if s then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, s - 1, { end_col = e, hl_group = "Identifier" })
      end
    end
  end
end

--- Open the form for `c` (a new configuration when nil). `on_save` gets the
--- saved configuration.
---@param c? aedi.Configuration
---@param on_save? fun(c: aedi.Configuration)
function M.open(c, on_save)
  local store = require("aedi.store")
  local original = c and not c.detected and store.get(c.name) and c.name or nil
  c = c and vim.deepcopy(c) or { name = "", command = "" }
  if c.detected and not original then
    -- a detected one is saved as a configuration of its own
    c.detected = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, ("aedi://configuration/%d"):format(buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.render(c))
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "aedi-configuration"
  highlight(buf)

  local width = math.min(90, vim.o.columns - 4)
  local height = math.min(#HELP + 10, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = original and (" Edit configuration: " .. original .. " ") or " New run configuration ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  -- cursor on the first empty value, else on the command
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^name:%s*$") or line:match("^command:%s*$") then
      vim.api.nvim_win_set_cursor(win, { i, #line })
      break
    elseif line:match("^command:") then
      vim.api.nvim_win_set_cursor(win, { i, 9 })
    end
  end

  local function save()
    local parsed, err = M.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if not parsed then
      vim.notify("Not saved: " .. err, vim.log.levels.ERROR)
      return nil
    end
    local ok, perr = pcall(store.put, parsed, original)
    if not ok then
      vim.notify("Not saved: " .. tostring(perr), vim.log.levels.ERROR)
      return nil
    end
    original = parsed.name
    vim.bo[buf].modified = false
    vim.api.nvim_win_set_config(win, { title = " Edit configuration: " .. parsed.name .. " ", title_pos = "center" })
    vim.notify("Saved run configuration " .. parsed.name, vim.log.levels.INFO)
    if on_save then
      on_save(parsed)
    end
    return parsed
  end

  local function close()
    if vim.bo[buf].modified then
      local choice = vim.fn.confirm("Save the run configuration?", "&Save\n&Discard\n&Cancel", 1)
      if choice == 1 then
        if not save() then
          return
        end
      elseif choice ~= 2 then
        return
      end
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      save()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      highlight(buf)
    end,
  })
  local function k(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  k("n", "q", close, "Close")
  k("n", "<Esc>", close, "Close")
  k({ "n", "i" }, "<C-CR>", function()
    vim.cmd("stopinsert")
    local saved = save()
    if saved then
      vim.api.nvim_win_close(win, true)
      require("aedi.console").start(saved)
    end
  end, "Save and run")
end

return M
