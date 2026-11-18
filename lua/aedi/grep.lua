-- Log lines coloured by what they say, as IntelliJ's Grep Console does: a
-- line with ERROR on a dark red ground, WARN on a dark orange one, DEBUG
-- dimmed, INFO left alone. In every output the Run panel shows (its terminals,
-- IntelliJ's output) and so in the Debug panel's Console.
--
-- Set with `setup({ grep = { ... } })`: each entry is a vim regex and a
-- highlight -- a group name, or attributes for `nvim_set_hl`. The first
-- entry (by `order`, then by name) that matches a line colours it.
--
--   grep = {
--     warn = false,                                        -- off
--     error = { hl = { bg = "#4a1010" } },                 -- another colour
--     debug = { pattern = [[\v<(DEBUG|TRACE|FINE)>]] },     -- more words
--     sql = { pattern = [[\v<(select|insert|update)>]], hl = "Special", order = 5 },
--   }
--
-- Only the lines on screen are looked at (a decoration provider), so a long
-- log costs nothing.

local M = {}

local ns = vim.api.nvim_create_namespace("aedi_grep")

---@class aedi.GrepRule
---@field pattern string a vim regex
---@field hl string|vim.api.keyset.highlight
---@field order? integer lower first (defaults: error 10, warn 20, debug 30)

---@type table<string, aedi.GrepRule|false>
M.defaults = {
  error = { pattern = [[\v<(ERROR|FATAL|SEVERE)>]], hl = "AediLogError", order = 10 },
  warn = { pattern = [[\v<(WARN|WARNING)>]], hl = "AediLogWarn", order = 20 },
  debug = { pattern = [[\v<(DEBUG|TRACE)>]], hl = "AediLogDebug", order = 30 },
  -- INFO: nothing
}

---@type { name: string, regex: vim.regex, group: string }[]
local rules = {}

--- Buffers whose lines are coloured.
---@type table<integer, boolean>
M.buffers = {}

local function get(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

--- `a` mixed into `b`: `t` of `a`.
local function mix(a, b, t)
  if not a or not b then
    return a or b
  end
  local function ch(c, s)
    return math.floor(c / s) % 256
  end
  local out = 0
  for _, s in ipairs({ 65536, 256, 1 }) do
    out = out + math.floor(ch(a, s) * t + ch(b, s) * (1 - t) + 0.5) * s
  end
  return out
end

local function define_defaults()
  local bg = get("Normal").bg or 0x1e1e1e
  local set = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set("AediLogError", { bg = mix(get("DiagnosticError").fg or 0xd04040, bg, 0.22) })
  set("AediLogWarn", { bg = mix(0xd0782a, bg, 0.22) })
  set("AediLogDebug", { fg = get("Comment").fg or get("NonText").fg })
end

--- Build the rules from the options.
function M.configure()
  define_defaults()
  local spec = vim.deepcopy(M.defaults)
  for name, rule in pairs(require("aedi.config").options.grep or {}) do
    if rule == false then
      spec[name] = false
    elseif type(rule) == "table" then
      spec[name] = vim.tbl_extend("force", spec[name] or {}, rule)
    end
  end
  rules = {}
  local names = vim.tbl_keys(spec)
  table.sort(names, function(a, b)
    local oa = spec[a] and spec[a].order or 100
    local ob = spec[b] and spec[b].order or 100
    if oa ~= ob then
      return oa < ob
    end
    return a < b
  end)
  for _, name in ipairs(names) do
    local rule = spec[name]
    if rule and rule.pattern and rule.hl then
      local ok, regex = pcall(vim.regex, rule.pattern)
      if not ok then
        vim.notify(("aedi grep %s: bad pattern %s"):format(name, rule.pattern), vim.log.levels.WARN)
      else
        local group = rule.hl
        if type(group) == "table" then
          group = "AediGrep_" .. name:gsub("[^%w]", "_")
          vim.api.nvim_set_hl(0, group, rule.hl)
        end
        rules[#rules + 1] = { name = name, regex = regex, group = group }
      end
    end
  end
end

--- The group `line` is coloured with, if any.
---@param line string
---@return string?
function M.match(line)
  for _, r in ipairs(rules) do
    if r.regex:match_str(line) then
      return r.group
    end
  end
end

--- Colour `buf`'s lines (`false`: stop).
---@param buf integer
---@param on? boolean
function M.attach(buf, on)
  M.buffers[buf] = on ~= false or nil
end

function M.setup()
  M.configure()
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf)
      return M.buffers[buf] == true and #rules > 0
    end,
    on_line = function(_, _, buf, row)
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      if not line or line == "" then
        return
      end
      local group = M.match(line)
      if group then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          end_row = row + 1,
          end_col = 0,
          hl_group = group,
          hl_eol = true,
          ephemeral = true,
          priority = 200,
        })
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("aedi_grep", { clear = true }),
    callback = function()
      vim.schedule(M.configure)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = "aedi_grep",
    callback = function(args)
      M.buffers[args.buf] = nil
    end,
  })
end

return M
