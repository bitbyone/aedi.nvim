-- IntelliJ's Run... popup (alt+shift+F10): the project's configurations, the
-- one run last on top, then the ones found in the project.
--
--   <CR>    run              <C-e>   edit (a found one: save a copy)
--   <C-n>   new              <C-y>   duplicate
--   <C-x>   delete a saved one

local M = {}

local NEW = { name = "New configuration…", new = true }

--- Saved configurations (the one run last first), then detected ones whose
--- name is not taken.
---@return aedi.Configuration[]
function M.items()
  local store = require("aedi.store")
  local saved = store.list()
  local last = store.last()
  local out, seen = {}, {}
  if last then
    for i, c in ipairs(saved) do
      if c.name == last.name then
        table.remove(saved, i)
        table.insert(saved, 1, c)
        break
      end
    end
  end
  for _, c in ipairs(saved) do
    seen[c.name] = true
    out[#out + 1] = c
  end
  if require("aedi.config").options.detect then
    local found = require("aedi.detect").all(require("aedi.util").root())
    -- the detected one run last goes first among them
    if last and last.detected then
      for i, c in ipairs(found) do
        if c.name == last.name then
          table.remove(found, i)
          table.insert(found, 1, c)
          break
        end
      end
    end
    for _, c in ipairs(found) do
      if not seen[c.name] then
        out[#out + 1] = c
      end
    end
  end
  return out
end

local function run(c)
  require("aedi.console").start(c)
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

local function snacks_pick()
  local console = require("aedi.console")
  local function make_items()
    local items = {}
    for _, c in ipairs(M.items()) do
      items[#items + 1] = { text = c.name .. " " .. c.command, config = c }
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
    title = "Run",
    layout = {
      preset = "select",
      layout = {
        footer = require("aedi.hints").chunks({
          { "Enter", "run" },
          { "Ctrl-E", "edit" },
          { "Ctrl-N", "new" },
          { "Ctrl-Y", "copy" },
          { "Ctrl-X", "delete" },
        }),
        footer_pos = "left",
      },
    },
    format = function(item)
      local c = item.config
      if c.new then
        return { { "＋ ", "Special" }, { c.name, "Special" } }
      end
      local ret = {}
      local running = false
      for _, r in ipairs(console.runs) do
        if r.config.name == c.name and console.running(r) then
          running = true
        end
      end
      ret[#ret + 1] = { running and "● " or "  ", "AediRunning" }
      ret[#ret + 1] = { c.name, c.detected and "SnacksPickerComment" or "SnacksPickerFile" }
      ret[#ret + 1] = { "  " }
      ret[#ret + 1] = { console.command_line(c), "SnacksPickerComment" }
      if c.cwd and c.cwd ~= "." then
        ret[#ret + 1] = { "  in " .. c.cwd, "SnacksPickerDir" }
      end
      return ret
    end,
    confirm = act(function(c)
      if c.new then
        edit(nil)
      else
        run(c)
      end
    end),
    actions = {
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
          ["<c-e>"] = { "aedi_edit", mode = { "n", "i" } },
          ["<c-n>"] = { "aedi_new", mode = { "n", "i" } },
          ["<c-y>"] = { "aedi_duplicate", mode = { "n", "i" } },
          ["<c-x>"] = { "aedi_delete", mode = { "n", "i" } },
        },
      },
    },
  })
end

--- Pick a configuration and run it.
function M.pick()
  if rawget(_G, "Snacks") and Snacks.picker then
    return snacks_pick()
  end
  local items = M.items()
  items[#items + 1] = NEW
  vim.ui.select(items, {
    prompt = "Run",
    format_item = function(c)
      return c.new and c.name or (c.name .. "  " .. require("aedi.console").command_line(c))
    end,
  }, function(c)
    if c and c.new then
      edit(nil)
    elseif c then
      run(c)
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
