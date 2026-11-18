-- A small float to tick items in: Space toggles, Enter takes them.

local M = {}

local ns = vim.api.nvim_create_namespace("aedi_checklist")

---@param title string
---@param items string[]
---@param selected string[]
---@param on_done fun(chosen: string[])
---@param opts? { empty?: string }
function M.open(title, items, selected, on_done, opts)
  opts = opts or {}
  local ticked = {}
  for _, s in ipairs(selected) do
    ticked[s] = true
  end
  -- something already in the field that is not a known item stays a choice
  for _, s in ipairs(selected) do
    if not vim.tbl_contains(items, s) then
      items = vim.list_extend(vim.deepcopy(items), { s })
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local function draw()
    local lines = {}
    if #items == 0 then
      lines = { "  " .. (opts.empty or "Nothing to pick") }
    end
    for _, it in ipairs(items) do
      lines[#lines + 1] = ("  %s  %s"):format(ticked[it] and "■" or "□", it)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, it in ipairs(items) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, {
        end_col = 2 + #(ticked[it] and "■" or "□"),
        hl_group = ticked[it] and "AediFormKey" or "AediFormLabel",
      })
    end
  end
  draw()
  local hints = require("aedi.hints")
  local footer = hints.chunks({ { "Space", "tick" }, { "Enter", "done" }, { "Esc", "cancel" } })
  local width = 0
  for _, c in ipairs(footer) do
    width = width + vim.fn.strdisplaywidth(c[1])
  end
  width = width + 2
  for _, it in ipairs(items) do
    width = math.max(width, #it + 10)
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.max(#items, 1),
    row = math.floor((vim.o.lines - #items) / 2) - 2,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = { { " " .. title .. " ", "FloatTitle" } },
    title_pos = "left",
    footer = footer,
    footer_pos = "left",
    zindex = 60,
  })
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
  local function toggle()
    local it = items[vim.api.nvim_win_get_cursor(win)[1]]
    if it then
      ticked[it] = not ticked[it] or nil
      draw()
    end
  end
  k("<Space>", toggle)
  k("x", toggle)
  k("<Tab>", function()
    toggle()
    vim.cmd("normal! j")
  end)
  k("<CR>", function()
    local out = {}
    for _, it in ipairs(items) do
      if ticked[it] then
        out[#out + 1] = it
      end
    end
    close()
    on_done(out)
  end)
  k("<Esc>", close)
  k("q", close)
end

return M
