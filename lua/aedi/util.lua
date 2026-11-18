local M = {}

local function options()
  return require("aedi.config").options
end

--- The project root.
---@return string
function M.root()
  return options().root()
end

--- A window in a split holding real code: not a float, a panel, the explorer
--- or anything `ignore_buf` turns down.
---@param win integer
---@return boolean
function M.is_code_win(win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local b = vim.api.nvim_win_get_buf(win)
  local ignore = options().ignore_buf
  if ignore and ignore(b) then
    return false
  end
  return vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= ""
end

--- The current window if it holds code, else the first one in this tab that
--- does.
---@return integer?
function M.code_win()
  local cur = vim.api.nvim_get_current_win()
  if M.is_code_win(cur) then
    return cur
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_code_win(win) then
      return win
    end
  end
end

--- Tell the host (a tab line plugin) that aedi draws this window's winbar.
---@param win integer
function M.panel(win)
  vim.w[win].aedi_panel = true
  local hook = options().on_panel
  if hook then
    hook(win)
  end
end

--- Panel windows: no gutter, no numbers.
---@param win integer
function M.bare(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.spell = false
  wo.list = false
end

return M
