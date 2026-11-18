-- Key hints, lit the way unagit lits them: the key in the accent colour, what
-- it does muted, the parts apart by a dim ` · `, on the background of
-- whatever they sit in (a float's border, a winbar).
--
--   Enter run · Ctrl-E edit · Ctrl-N new
--
-- A hint is a list of { key, what } pairs.

local M = {}

---@alias aedi.Hint { [1]: string, [2]: string }[]

local function hl(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

local function first(field, ...)
  for _, name in ipairs({ ... }) do
    local v = hl(name)[field]
    if v then
      return v
    end
  end
end

--- Where hints sit, and the groups their background comes from.
local PLACES = {
  float = { "FloatBorder", "NormalFloat", "Normal" },
  form = { "AediFormBorder", "FloatBorder", "NormalFloat", "Normal" },
  picker = { "SnacksPickerBorder", "FloatBorder", "NormalFloat", "Normal" },
  bar = { "AediTabFill", "TabLineFill", "WinBar", "Normal" },
}

--- The groups of one place, from the colours as they are now (cheap, and
--- it follows a group relinked after setup).
local function define_place(place)
  local bg = first("bg", unpack(PLACES[place]))
  local function set(role, fg)
    vim.api.nvim_set_hl(0, "AediHint" .. role .. "_" .. place, { fg = fg, bg = bg })
  end
  set("Key", first("fg", "FloatTitle", "Special", "Title"))
  set("", first("fg", "Comment", "NonText"))
  set("Sep", first("fg", "NonText", "Comment"))
end

local function define()
  for place in pairs(PLACES) do
    define_place(place)
  end
end

--- `{ text, hl }` chunks, for a float's title or footer.
---@param hint aedi.Hint
---@param place? "float"|"form"|"picker"|"bar"
---@return { [1]: string, [2]: string }[]
function M.chunks(hint, place)
  place = place or "float"
  define_place(place)
  local key, text, sep = "AediHintKey_" .. place, "AediHint_" .. place, "AediHintSep_" .. place
  local out = { { " ", text } }
  for i, h in ipairs(hint) do
    if i > 1 then
      out[#out + 1] = { " · ", sep }
    end
    out[#out + 1] = { h[1], key }
    out[#out + 1] = { " " .. h[2], text }
  end
  out[#out + 1] = { " ", text }
  return out
end

--- The same as a 'statusline' / 'winbar' string.
---@param hint aedi.Hint
---@param place? "float"|"form"|"picker"|"bar"
---@return string
function M.statusline(hint, place)
  local parts = {}
  for _, c in ipairs(M.chunks(hint, place or "bar")) do
    parts[#parts + 1] = "%#" .. c[2] .. "#" .. c[1]:gsub("%%", "%%%%")
  end
  return table.concat(parts)
end

function M.setup()
  define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("aedi_hints", { clear = true }),
    callback = function()
      vim.schedule(define)
    end,
  })
end

return M
