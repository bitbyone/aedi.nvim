-- The full text of a long dap-ui line, as a bordered popup.
--
-- dap-ui's own `expand_lines` lays an unbordered one-line float over the line
-- under the cursor, as wide as the text -- across the frames and watches
-- panels next to it, in the same colours, so a `toString()` of a record is a
-- 400-column strip that cannot be told from the panels it covers.
--
-- This replaces `require("dapui.render.line_hover").show`, which every dap-ui
-- buffer calls on CursorMoved, so it stays dap-ui's trigger with a different
-- picture: a framed float above the line, at most most of the screen wide,
-- the variable (`record ConsumerRecord@6429`) as its title and the value
-- below it, broken at its brackets and commas and indented by depth:
--
--   ConsumerRecord(
--     topic = structure.organization-events,
--     partition = 1,
--     headers = RecordHeaders(
--       headers = [],
--       isReadOnly = false
--     ),
--     ...
--   )
--
-- A value whose brackets do not balance (a truncated or free-form string) is
-- shown as it is, soft-wrapped. Lines without ` = ` -- a stack frame -- are
-- only wrapped.

local M = {}

local api = vim.api
local state = { win = nil, buf = nil, src = nil, line = nil }

local OPEN, CLOSE = { ["("] = ")", ["["] = "]", ["{"] = "}" }, { [")"] = true, ["]"] = true, ["}"] = true }

--- Break `s` at brackets and top-level commas. nil when the brackets do not
--- balance or there is nothing to break.
---@param s string
---@return string[]?
local function pretty(s)
  local out, cur, depth, quoted, broke = {}, "", 0, false, false
  local function push()
    if cur:match("%S") then
      table.insert(out, string.rep("  ", depth) .. vim.trim(cur))
    end
    cur = ""
  end
  local i, n = 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == '"' then
      quoted = not quoted
      cur = cur .. ch
    elseif quoted then
      cur = cur .. ch
    elseif ch == "[" and (s:match("^%[+[BCDFIJSZ]@", i) or s:match("^%[+L[^;%s]+;@", i)) then
      -- A JVM array's identity, `[B@4db0ba1c` / `[Ljava.lang.String;@1f2a`:
      -- not a bracket.
      local lit = s:match("^%[+[BCDFIJSZ]@", i) or s:match("^%[+L[^;%s]+;@", i)
      cur = cur .. lit
      i = i + #lit - 1
    elseif OPEN[ch] then
      -- An empty pair stays inline: `[]`, `()`.
      if s:sub(i + 1, i + 1) == OPEN[ch] then
        cur = cur .. ch .. OPEN[ch]
        i = i + 1
      else
        cur = cur .. ch
        push()
        depth = depth + 1
        broke = true
      end
    elseif CLOSE[ch] then
      push()
      depth = depth - 1
      if depth < 0 then
        return nil
      end
      cur = ch
    elseif ch == "," and depth > 0 then
      cur = cur .. ch
      push()
      -- Swallow the space after the comma; the next line is indented anyway.
      if s:sub(i + 1, i + 1) == " " then
        i = i + 1
      end
    else
      cur = cur .. ch
    end
    i = i + 1
  end
  if depth ~= 0 or quoted or not broke then
    return nil
  end
  push()
  return out
end

--- Title and body lines for one dap-ui line.
---@param text string
---@return string?, string[]
local function content(text)
  -- Drop the tree marker and indentation dap-ui draws before a variable.
  local line = text:gsub("^[%s▸▾>v]*", "")
  local lhs, value = line:match("^(.-) = (.*)$")
  if not lhs then
    return nil, { line }
  end
  local unq = value:match('^"(.*)"$')
  return vim.trim(lhs), pretty(unq or value) or { value }
end

local function close()
  if state.win and api.nvim_win_is_valid(state.win) then
    pcall(api.nvim_win_close, state.win, true)
  end
  state.win, state.src, state.line = nil, nil, nil
  pcall(api.nvim_del_augroup_by_name, "DapHover")
end
M.close = close

local function display_height(lines, width)
  local h = 0
  for _, l in ipairs(lines) do
    h = h + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  return h
end

function M.show()
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  local buf = api.nvim_get_current_buf()
  local row = api.nvim_win_get_cursor(win)[1]
  local text = api.nvim_get_current_line()
  local info = vim.fn.getwininfo(win)[1]
  if vim.fn.strdisplaywidth(text) <= info.width - info.textoff then
    close()
    return
  end
  if state.win and api.nvim_win_is_valid(state.win) and state.src == buf and state.line == row then
    return
  end
  close()

  local title, lines = content(text)
  local maxw = math.max(40, math.floor(vim.o.columns * 0.7))
  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  if title then
    width = math.max(width, vim.fn.strdisplaywidth(title) + 4)
  end
  width = math.min(width, maxw)

  -- Above the line: the panels sit at the bottom of the screen.
  local pos = vim.fn.screenpos(win, row, 1)
  local above = pos.row - 1 -- screen rows over the cursor line
  local height = math.min(display_height(lines, width), math.max(1, above - 2))
  local col = math.min(math.max(info.wincol - 1, 0), math.max(vim.o.columns - width - 2, 0))

  state.buf = api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  state.win = api.nvim_open_win(state.buf, false, {
    relative = "editor",
    anchor = "SW",
    row = pos.row - 1,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "single",
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "left" or nil,
    focusable = false,
    noautocmd = true,
    zindex = 60,
  })
  vim.wo[state.win].wrap = true
  vim.wo[state.win].linebreak = true
  vim.wo[state.win].breakindent = true
  vim.wo[state.win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"
  -- `name =` in the property colour, the rest plain.
  api.nvim_win_call(state.win, function()
    vim.fn.matchadd("@property", [[^\s*\zs[^=(\[{]\{-1,}\ze = ]])
  end)
  state.src, state.line = buf, row

  local group = api.nvim_create_augroup("DapHover", { clear = true })
  api.nvim_create_autocmd({ "WinLeave", "BufLeave", "TabLeave", "WinScrolled", "InsertEnter" }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      -- Scrolling keeps the popup only while the line is still where it was.
      if ev.event == "WinScrolled" and vim.fn.line(".") == state.line then
        local p = vim.fn.screenpos(0, state.line, 1)
        if p.row == pos.row then
          return
        end
      end
      close()
    end,
  })
end

--- Point dap-ui's long-line hook here.
function M.install()
  local ok, hover = pcall(require, "dapui.render.line_hover")
  if ok then
    hover.show = M.show
  end
end

return M
