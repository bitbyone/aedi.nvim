-- IntelliJ's Run... popup (alt+shift+F10): the project's configurations, the
-- one run last on top, then the ones found in the project.
--
--   <CR>    run              <C-e>   edit (a found one: save a copy)
--   <C-n>   new              <C-y>   duplicate
--   <C-x>   delete a saved one

local M = {}

local NEW = { name = "New configuration…", new = true }

--- Saved configurations and the ones found in the project (a saved one
--- shadows a found one of the same name), the most used first: runs,
--- weighted by how recent (frecency). Ties keep saved before found.
---@return aedi.Configuration[]
function M.items()
  local store = require("aedi.store")
  local list, seen = {}, {}
  for _, c in ipairs(store.list()) do
    seen[c.name] = true
    list[#list + 1] = c
  end
  if require("aedi.config").options.detect then
    for _, c in ipairs(require("aedi.detect").all(require("aedi.util").root())) do
      if not seen[c.name] then
        list[#list + 1] = c
      end
    end
  end
  local now = os.time()
  local score, order = {}, {}
  for i, c in ipairs(list) do
    score[c] = store.score(c.name, nil, now)
    order[c] = i
  end
  table.sort(list, function(x, y)
    if score[x] ~= score[y] then
      return score[x] > score[y]
    end
    return order[x] < order[y]
  end)
  return list
end

local function run(c, debug)
  require("aedi.console").start(c, { debug = debug })
end

local function edit(c)
  require("aedi.editor").open(c)
end

local function duplicate(c)
  local copy = vim.deepcopy(c)
  copy.detected = nil
  copy.name = c.name .. " (copy)"
  require("aedi.editor").open(copy)
end

local function delete(c)
  if c.detected then
    vim.notify(c.name .. " is found in the project, not saved", vim.log.levels.INFO)
    return false
  end
  if vim.fn.confirm(("Delete run configuration %q?"):format(c.name), "&Delete\n&Cancel", 2) == 1 then
    require("aedi.store").delete(c.name)
    return true
  end
  return false
end

--- The Run list on a plain float's ground, darker than snacks' pickers: it
--- has no backdrop, and the configuration form (which has) is the lighter
--- one. Every SnacksPicker* group its windows use is swapped for a copy on
--- NormalFloat's ground (FloatBorder's for borders and titles).
local function get(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

--- `grounds` are taken before the picker opens: while it is up, snacks
--- shows NormalFloat / FloatBorder in its own colours.
local function darken(picker, grounds)
  local body, edge = grounds.body, grounds.edge
  local function dark(group)
    local name = "AediDark_" .. group
    local h = get(group)
    local bg = (group:find("Border") or group:find("Title")) and edge or body
    vim.api.nvim_set_hl(0, name, { fg = h.fg, bg = bg, bold = h.bold, italic = h.italic })
    return name
  end
  local wins = {}
  for _, w in pairs(picker.layout.wins or {}) do
    wins[#wins + 1] = w.win
  end
  for _, w in pairs(picker.layout.box_wins or {}) do
    wins[#wins + 1] = w.win
  end
  for _, win in ipairs(wins) do
    if win and vim.api.nvim_win_is_valid(win) then
      local pairs_ = {}
      for from, to in vim.wo[win].winhighlight:gmatch("([^:,]+):([^,]+)") do
        pairs_[#pairs_ + 1] = from .. ":" .. (to:find("^Snacks") and dark(to) or to)
      end
      vim.wo[win].winhighlight = table.concat(pairs_, ",")
    end
  end
end

---@param opts? { debug?: boolean }
local function snacks_pick(opts)
  local debug = opts and opts.debug
  local grounds = { body = get("NormalFloat").bg or get("Normal").bg, edge = get("FloatBorder").bg }
  local console = require("aedi.console")
  local width = { name = 0, type = 0, profiles = 0 }
  local function make_items()
    local items = {}
    local types = require("aedi.types")
    for _, c in ipairs(M.items()) do
      width.name = math.max(width.name, vim.fn.strdisplaywidth(c.name))
      width.type = math.max(width.type, #types.label(c))
      width.profiles = math.max(width.profiles, #(c.profiles or ""))
      local text = table.concat({ c.name, types.label(c), c.profiles or "" }, " ")
      items[#items + 1] = { text = text, config = c }
    end
    items[#items + 1] = { text = NEW.name, config = NEW }
    return items
  end
  local function act(fn, close)
    return function(picker, item)
      if not item then
        return
      end
      if close ~= false then
        picker:close()
      end
      fn(item.config, picker)
    end
  end
  Snacks.picker.pick({
    title = debug and "Debug" or "Run",
    on_show = function(picker)
      darken(picker, grounds)
    end,
    layout = {
      preset = "select",
      layout = {
        title_pos = "left",
        footer = require("aedi.hints").chunks({
          { "Enter", debug and "debug" or "run" },
          { "Ctrl-D", "debug" },
          { "Ctrl-E", "edit" },
          { "Ctrl-N", "new" },
          { "Ctrl-Y", "copy" },
          { "Ctrl-X", "delete" },
        }, "float"),
        footer_pos = "left",
      },
    },
    format = function(item)
      local c = item.config
      if c.new then
        return { { "  + ", "AediFormKey" }, { c.name, "AediFormKey" } }
      end
      local running = false
      for _, r in ipairs(console.runs) do
        if r.config.name == c.name and console.running(r) then
          running = true
        end
      end
      local types = require("aedi.types")
      local ret = {}
      ret[#ret + 1] = { running and "● " or "  ", "AediRunning" }
      ret[#ret + 1] = { ("%-" .. width.name .. "s"):format(c.name), "SnacksPickerFile" }
      ret[#ret + 1] = { "  " }
      ret[#ret + 1] = { ("%-" .. width.type .. "s"):format(types.label(c)), "AediFormMuted" }
      ret[#ret + 1] = { "  " }
      local profiles = c.profiles and c.profiles ~= "" and c.profiles or ""
      ret[#ret + 1] = { ("%-" .. width.profiles .. "s"):format(profiles), "AediFormKey" }
      if width.profiles > 0 then
        ret[#ret + 1] = { "  " }
      end
      ret[#ret + 1] = { c.detected and "found in the project" or "", "AediFormPlaceholder" }
      return ret
    end,
    confirm = act(function(c)
      if c.new then
        edit(nil)
      else
        run(c, debug)
      end
    end),
    actions = {
      aedi_debug = act(function(c)
        if not c.new then
          run(c, true)
        end
      end),
      aedi_edit = act(function(c)
        edit(not c.new and c or nil)
      end),
      aedi_new = act(function()
        edit(nil)
      end),
      aedi_duplicate = act(function(c)
        if not c.new then
          duplicate(c)
        end
      end),
      aedi_delete = act(function(c, picker)
        if not c.new and delete(c) then
          picker:find({ refresh = true })
        end
      end, false),
    },
    finder = function()
      return make_items()
    end,
    win = {
      input = {
        keys = {
          ["<c-d>"] = { "aedi_debug", mode = { "n", "i" } },
          ["<c-e>"] = { "aedi_edit", mode = { "n", "i" } },
          ["<c-n>"] = { "aedi_new", mode = { "n", "i" } },
          ["<c-y>"] = { "aedi_duplicate", mode = { "n", "i" } },
          ["<c-x>"] = { "aedi_delete", mode = { "n", "i" } },
        },
      },
    },
  })
end

--- Pick a configuration and run it (`debug`: debug it).
---@param opts? { debug?: boolean }
function M.pick(opts)
  if rawget(_G, "Snacks") and Snacks.picker then
    return snacks_pick(opts)
  end
  local items = M.items()
  items[#items + 1] = NEW
  vim.ui.select(items, {
    prompt = "Run",
    format_item = function(c)
      return c.new and c.name or (c.name .. "  " .. require("aedi.types").label(c))
    end,
  }, function(c)
    if c and c.new then
      edit(nil)
    elseif c then
      run(c, opts and opts.debug)
    end
  end)
end

--- Pick a configuration and edit it.
function M.pick_edit()
  local items = M.items()
  items[#items + 1] = NEW
  vim.ui.select(items, {
    prompt = "Edit configuration",
    format_item = function(c)
      return c.name
    end,
  }, function(c)
    if c then
      edit(not c.new and c or nil)
    end
  end)
end

return M
