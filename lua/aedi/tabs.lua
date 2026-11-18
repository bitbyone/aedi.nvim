-- Tabs in a winbar (the Run panel's runs, the Debug panel's Variables |
-- Console), drawn the way an editor tab line draws them: the current tab
-- marked by a bar down its left edge -- accented while its window has focus
-- -- and the tabs apart by a thin rule.
--
--   ▎● App  │ ✓ go test ./... 3.1s │ ✗ build 1
--
-- Groups (each links to the TabLine family by default; link them to your
-- tab line plugin's to look the same):
--   AediTab        a tab                AediTabSel     the current tab
--   AediTabMark    its edge, focused    AediTabMarkNC  its edge, unfocused
--   AediTabSep     the rule between     AediTabFill    the rest of the bar

local M = {}

local function get(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

--- `group`'s colour on `base`'s background: an icon inside a tab.
---@param group string
---@param base string
---@return string
function M.on(group, base)
  local name = group .. "_on_" .. base
  vim.api.nvim_set_hl(0, name, { fg = get(group).fg, bg = get(base).bg, bold = get(base).bold })
  return name
end

---@class aedi.Tab
---@field text string
---@field icon? string
---@field icon_group? string
---@field tail? string muted, after the text
---@field selected boolean
---@field click? string a global function's name: (id, clicks, button, mods)
---@field id? integer

--- The winbar string for `tabs`.
---@param tabs aedi.Tab[]
---@param focused boolean the window the bar is in has focus
---@return string
function M.render(tabs, focused)
  local parts = {}
  for _, t in ipairs(tabs) do
    local base = t.selected and "AediTabSel" or "AediTab"
    local s = {}
    if t.click then
      s[#s + 1] = ("%%%d@v:lua.%s@"):format(t.id or 0, t.click)
    end
    if t.selected then
      s[#s + 1] = "%#" .. (focused and "AediTabMark" or "AediTabMarkNC") .. "#▎"
    else
      s[#s + 1] = "%#" .. base .. "# "
    end
    if t.icon then
      s[#s + 1] = "%#" .. M.on(t.icon_group or base, base) .. "#" .. t.icon .. " "
    end
    s[#s + 1] = "%#" .. base .. "#" .. t.text:gsub("%%", "%%%%")
    if t.tail and t.tail ~= "" then
      s[#s + 1] = "%#" .. M.on("AediTabMuted", base) .. "# " .. t.tail:gsub("%%", "%%%%")
    end
    s[#s + 1] = "%#" .. base .. "# "
    if t.click then
      s[#s + 1] = "%X"
    end
    parts[#parts + 1] = table.concat(s)
  end
  return table.concat(parts, "%#AediTabSep#│") .. "%#AediTabFill#"
end

function M.setup()
  local function define()
    local sel, tab, fill = get("TabLineSel"), get("TabLine"), get("TabLineFill")
    local accent = get("FloatTitle").fg or sel.fg or get("Special").fg
    local muted = get("Comment").fg
    local set = function(name, val)
      val.default = true
      vim.api.nvim_set_hl(0, name, val)
    end
    set("AediTab", { link = "TabLine" })
    set("AediTabSel", { link = "TabLineSel" })
    set("AediTabFill", { link = "TabLineFill" })
    set("AediTabMark", { fg = accent, bg = sel.bg })
    set("AediTabMarkNC", { fg = muted, bg = sel.bg })
    set("AediTabSep", { fg = fill.bg or muted, bg = tab.bg })
    set("AediTabMuted", { fg = muted })
  end
  define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("aedi_tabs", { clear = true }),
    callback = function()
      vim.schedule(define)
    end,
  })
end

return M
