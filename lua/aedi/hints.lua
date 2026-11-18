-- Key hints, lit the way unagit lits them: the key in the key colour, what it
-- does dimmed, the parts apart by a dim ` · `.
--
--   Enter run · Ctrl-E edit · Ctrl-N new
--
-- A hint is a list of { key, what } pairs.

local M = {}

---@alias aedi.Hint { [1]: string, [2]: string }[]

--- `{ text, hl }` chunks, for a float's title or footer.
---@param hint aedi.Hint
---@return { [1]: string, [2]: string }[]
function M.chunks(hint)
  local out = { { " ", "AediHint" } }
  for i, h in ipairs(hint) do
    if i > 1 then
      out[#out + 1] = { " · ", "AediHintSep" }
    end
    out[#out + 1] = { h[1], "AediHintKey" }
    out[#out + 1] = { " " .. h[2], "AediHint" }
  end
  out[#out + 1] = { " ", "AediHint" }
  return out
end

--- The same as a 'statusline' / 'winbar' string.
---@param hint aedi.Hint
---@return string
function M.statusline(hint)
  local parts = {}
  for _, c in ipairs(M.chunks(hint)) do
    parts[#parts + 1] = "%#" .. c[2] .. "#" .. c[1]:gsub("%%", "%%%%")
  end
  return table.concat(parts)
end

function M.setup()
  local function link(name, to)
    vim.api.nvim_set_hl(0, name, { link = to, default = true })
  end
  link("AediHint", "Comment")
  link("AediHintSep", "NonText")
  link("AediHintKey", "Special")
end

return M
