-- IntelliJ's Edit Configuration dialog, laid out the way unagit lays out its
-- forms: a rounded float with the title in its top edge and the keys in its
-- bottom one, muted capital labels on the left, the values beside them.
--
--   ╭ Run configuration ─────────────────────────────────────────╮
--   │  TYPE         Spring Boot                     Enter change │
--   │  NAME         access-control                               │
--   │  PROFILES     local                   local · openapi      │
--   │  ARGUMENTS    none                                         │
--   │  ENVIRONMENT  KEY=value KEY2='with space'                  │
--   │                                                            │
--   │  RUNS         ./gradlew bootRun --args='--spring.profi…'   │
--   │               in ~/workspace/my2n/access-control           │
--   ╰ Tab next · Enter pick · :w save · Ctrl-Enter run · q close ╯
--
-- Each value is one line of the buffer, edited like any text; the labels,
-- the placeholders and the command line below are drawn around it and
-- follow it as you type. A field with choices (type, profiles, module) has
-- them on Enter.

local types = require("aedi.types")
local spring = require("aedi.spring")
local util = require("aedi.util")

local M = {}

local ns = vim.api.nvim_create_namespace("aedi_form")
local LABEL_W = 14

--- The fields of a form: the type first, then the type's own. A Spring Boot
--- form has Module only when the project has more than one application.
---@param state table
---@return string[]
local function fields_of(state)
  local out = { "type" }
  local t = types.types[state.type]
  for _, f in ipairs(t.fields) do
    local skip = (f == "module" and #state.apps <= 1 and (state.values.module or "") == "")
      or (t.hidden and t.hidden(f, state.values))
    if not skip then
      out[#out + 1] = f
    end
  end
  return out
end

--- The configuration the form holds.
---@param state table
---@return aedi.Configuration?, string? error
local function to_config(state)
  local v = state.values
  local c = { type = state.type ~= "shell" and state.type or nil }
  for _, f in ipairs(fields_of(state)) do
    if f ~= "type" then
      local value = vim.trim(v[f] or "")
      if f == "env" then
        local env, err = types.parse_env(value)
        if not env then
          return nil, err
        end
        c.env = next(env) and env or nil
      elseif f == "launcher" then
        c.launcher = value == "bootRun" and "bootRun" or nil
      elseif f == "profiles" then
        c.profiles = spring.normalize(value) ~= "" and spring.normalize(value) or nil
      elseif value ~= "" then
        c[f] = value
      end
    end
  end
  if not c.name then
    return nil, "the name is empty"
  end
  if state.type == "shell" and not c.command then
    return nil, "the command is empty"
  end
  if state.type == "gradle" and not c.tasks then
    return nil, "no tasks"
  end
  if state.type == "application" and not c.main then
    return nil, "no main class"
  end
  return c
end
M.to_config = to_config

--- Fields whose line shows a choice's label rather than text you type.
local CHOICE = { type = true, launcher = true }

local function launcher_label(id)
  for _, l in ipairs(types.launchers) do
    if l.id == id then
      return l.label
    end
  end
  return types.launchers[1].label
end

--- The text a choice field's line holds.
local function choice_text(state, f)
  if f == "type" then
    return types.types[state.type].label
  end
  return launcher_label(state.values.launcher)
end

--- Values of the form's fields, from a configuration.
---@param c aedi.Configuration
local function values_of(c)
  return {
    name = c.name or "",
    command = c.command or "",
    args = c.args or "",
    cwd = (c.cwd and c.cwd ~= ".") and c.cwd or "",
    env = types.format_env(c.env),
    profiles = (c.profiles or ""):gsub(",", ", "),
    module = c.module or "",
    tasks = c.tasks or "",
    launcher = c.launcher or "intellij",
    main = c.main or "",
    vm = c.vm or "",
  }
end
M.values_of = values_of

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

local function short(path)
  return vim.fn.fnamemodify(path, ":~")
end

--- Break `text` into lines of at most `width`, at spaces where it can.
local function wrap(text, width)
  local out = {}
  while #text > width do
    local cut = text:sub(1, width):match(".*() ") or width
    if cut < width / 2 then
      cut = width
    end
    out[#out + 1] = text:sub(1, cut)
    text = text:sub(cut + 1)
  end
  out[#out + 1] = text
  return out
end

local function decorate(state)
  local buf = state.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local fields = fields_of(state)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor = vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_cursor(state.win)[1] or 1
  for i, f in ipairs(fields) do
    local spec = f == "type" and { label = "Type" } or types.fields[f]
    local label = ("  %-" .. LABEL_W .. "s"):format(spec.label:upper())
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      virt_text = { { label, i == cursor and "AediFormLabelActive" or "AediFormLabel" } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      right_gravity = false,
    })
    local value = lines[i] or ""
    if CHOICE[f] then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #value, hl_group = "AediFormValue" })
    end
    if value == "" and not CHOICE[f] then
      local ph = spec.placeholder
      if f == "args" then
        ph = types.types[state.type].args_placeholder or ph
      end
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { ph, "AediFormPlaceholder" } },
        virt_text_pos = "inline",
        hl_mode = "combine",
      })
    end
    -- what the field offers, on its right
    local right
    if CHOICE[f] then
      right = { { "Enter", "AediFormKey" }, { " change", "AediFormMuted" } }
    elseif f == "main" and i == cursor then
      right = { { "Enter", "AediFormKey" }, { " pick", "AediFormMuted" } }
    elseif f == "profiles" then
      local avail = spring.profiles(state.root, state.values.module ~= "" and state.values.module or state.apps[1])
      right = { { #avail > 0 and table.concat(avail, " · ") or "no application-*.yml", "AediFormMuted" } }
      if i == cursor then
        vim.list_extend(right, { { "  Enter", "AediFormKey" }, { " pick", "AediFormMuted" } })
      end
    elseif f == "module" and i == cursor then
      right = { { "Enter", "AediFormKey" }, { " pick", "AediFormMuted" } }
    end
    if right then
      table.insert(right, { "  ", "AediFormMuted" })
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { virt_text = right, virt_text_pos = "right_align", hl_mode = "combine" })
    end
  end

  -- what it runs
  local width = (vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_width(state.win) or 80) - LABEL_W - 6
  local virt = { { { "", "" } } }
  local c, err = to_config(state)
  local launch
  if c then
    launch, err = types.build(c, state.root)
  end
  local pad = (" "):rep(LABEL_W + 2)
  local label = ("  %-" .. LABEL_W .. "s"):format("RUNS")
  if not launch then
    virt[#virt + 1] = { { label, "AediFormLabel" }, { err or "?", "AediFormError" } }
  else
    local env = types.format_env(launch.env)
    local text = (launch.intellij and "IntelliJ · " or "") .. (env ~= "" and (env .. " ") or "") .. launch.cmd
    for j, part in ipairs(wrap(text, width)) do
      virt[#virt + 1] = { { j == 1 and label or pad, "AediFormLabel" }, { part, "AediFormCommand" } }
    end
    virt[#virt + 1] = { { pad, "AediFormLabel" }, { "in " .. short(launch.cwd), "AediFormMuted" } }
  end
  vim.api.nvim_buf_set_extmark(buf, ns, #fields - 1, 0, { virt_lines = virt })
  state.extra = #virt
end

--- Put the fields in the buffer.
local function render(state)
  local fields = fields_of(state)
  local lines = {}
  for _, f in ipairs(fields) do
    lines[#lines + 1] = CHOICE[f] and choice_text(state, f) or (state.values[f] or "")
  end
  state.rendering = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  state.rendering = false
  decorate(state)
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_height(state.win, #fields + state.extra)
  end
end

--- The buffer's lines back into the values; the shape put back if an edit
--- broke it (a pasted line, a joined one, the type typed over).
local function read(state)
  if state.rendering then
    return
  end
  local fields = fields_of(state)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local broken = #lines ~= #fields
  for i, f in ipairs(fields) do
    if CHOICE[f] then
      broken = broken or lines[i] ~= choice_text(state, f)
    else
      state.values[f] = lines[i] or ""
    end
  end
  if broken then
    if #lines > #fields then
      -- what spilled over joins the last field
      state.values[fields[#fields]] = table.concat(vim.list_slice(lines, #fields), " ")
    end
    vim.schedule(function()
      local cur = vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_cursor(state.win)
      render(state)
      if cur then
        pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(cur[1], #fields), cur[2] })
      end
    end)
    return
  end
  decorate(state)
end

-- ---------------------------------------------------------------------------
-- Choices
-- ---------------------------------------------------------------------------

local function field_at(state)
  return fields_of(state)[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function goto_field(state, name)
  for i, f in ipairs(fields_of(state)) do
    if f == name then
      vim.api.nvim_set_current_win(state.win)
      vim.api.nvim_win_set_cursor(state.win, { i, #(vim.api.nvim_buf_get_lines(state.buf, i - 1, i, false)[1] or "") })
      return
    end
  end
end

local function choose_type(state)
  local labels = vim.tbl_map(function(t)
    return types.types[t].label
  end, types.order)
  vim.ui.select(types.order, {
    prompt = "Configuration type",
    format_item = function(t)
      return types.types[t].label
    end,
  }, function(t)
    if not t or t == state.type then
      return
    end
    state.type = t
    if t == "spring-boot" and state.values.name == "" then
      state.values.name = vim.fs.basename(state.root)
    end
    render(state)
    goto_field(state, "name")
  end)
  return labels
end

local function choose_profiles(state)
  local module = state.values.module ~= "" and state.values.module or state.apps[1]
  local avail = spring.profiles(state.root, module)
  local current = vim.split(spring.normalize(state.values.profiles), ",", { trimempty = true })
  require("aedi.checklist").open("Profiles", avail, current, function(chosen)
    state.values.profiles = table.concat(chosen, ", ")
    render(state)
    goto_field(state, "profiles")
  end, { empty = "No application-<profile>.yml found" })
end

local function choose_module(state)
  vim.ui.select(state.apps, {
    prompt = "Spring Boot application",
    format_item = function(d)
      return d == "" and "(project root)" or d
    end,
  }, function(d)
    if d then
      state.values.module = d
      render(state)
      goto_field(state, "module")
    end
  end)
end

local function choose_launcher(state)
  vim.ui.select(types.launchers, {
    prompt = "Launch Spring Boot with",
    format_item = function(l)
      return l.label
    end,
  }, function(l)
    if l then
      state.values.launcher = l.id
      render(state)
      goto_field(state, "launcher")
    end
  end)
end

local function choose_main(state)
  local mains = require("aedi.jvm").mains(state.root)
  if #mains == 0 then
    vim.notify("No main class under src/main (fun main / static void main)", vim.log.levels.INFO)
    return
  end
  vim.ui.select(mains, {
    prompt = "Main class",
    format_item = function(m)
      return m.class .. (m.module ~= "" and ("  (" .. m.module .. ")") or "")
    end,
  }, function(m)
    if m then
      state.values.main = m.class
      if state.values.name == "" then
        state.values.name = (m.class:match("[^.]+$") or m.class):gsub("Kt$", "")
      end
      render(state)
      goto_field(state, "main")
    end
  end)
end

--- Enter on a field: its choices, or else typing at its end.
local function enter(state, insert)
  local f = field_at(state)
  if f == "type" then
    vim.cmd("stopinsert")
    return choose_type(state)
  elseif f == "profiles" then
    vim.cmd("stopinsert")
    return choose_profiles(state)
  elseif f == "module" then
    vim.cmd("stopinsert")
    return choose_module(state)
  elseif f == "launcher" then
    vim.cmd("stopinsert")
    return choose_launcher(state)
  elseif f == "main" then
    vim.cmd("stopinsert")
    return choose_main(state)
  end
  if insert then
    -- next field
    local row = vim.api.nvim_win_get_cursor(state.win)[1]
    local n = #fields_of(state)
    if row < n then
      local line = vim.api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1] or ""
      vim.api.nvim_win_set_cursor(state.win, { row + 1, #line })
    end
  else
    vim.cmd("startinsert!")
  end
end

local function step(state, delta)
  local n = #fields_of(state)
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  row = (row - 1 + delta) % n + 1
  local line = vim.api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(state.win, { row, #line })
end

-- ---------------------------------------------------------------------------
-- The form
-- ---------------------------------------------------------------------------

--- Open the form for `c` (a new configuration when nil). `on_save` gets the
--- saved configuration.
---@param c? aedi.Configuration
---@param on_save? fun(c: aedi.Configuration)
function M.open(c, on_save)
  local store = require("aedi.store")
  local root = util.root()
  local apps = spring.apps(root)
  local original = c and not c.detected and store.get(c.name) and c.name or nil
  local state = {
    root = root,
    apps = apps,
    original = original,
    type = c and types.of(c) or (#apps > 0 and "spring-boot" or "shell"),
    values = values_of(c or {}),
    extra = 4,
  }
  if not c and state.type == "spring-boot" then
    state.values.name = vim.fs.basename(root)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, ("aedi://configuration/%d"):format(buf))

  local hints = require("aedi.hints")
  local width = math.min(100, vim.o.columns - 4)
  local title = original and ("Run configuration · " .. original) or "New run configuration"
  state.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 8,
    row = math.floor(vim.o.lines * 0.25),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = { { " " .. title .. " ", "FloatTitle" } },
    title_pos = "left",
    footer = hints.chunks({
      { "Tab", "next" },
      { "Enter", "pick" },
      { ":w", "save" },
      { "Ctrl-Enter", "save and run" },
      { "Ctrl-D", "save and debug" },
      { "q", "close" },
    }),
    footer_pos = "left",
  })
  local win = state.win
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  wo.winhighlight = "CursorLine:AediFormCursorLine"
  vim.bo[buf].filetype = "aedi-configuration"
  render(state)
  vim.bo[buf].modified = false

  local function save()
    local parsed, err = to_config(state)
    if not parsed then
      vim.notify("Not saved: " .. err, vim.log.levels.ERROR)
      return nil
    end
    local ok, perr = pcall(store.put, parsed, state.original)
    if not ok then
      vim.notify("Not saved: " .. tostring(perr), vim.log.levels.ERROR)
      return nil
    end
    state.original = parsed.name
    vim.bo[buf].modified = false
    vim.api.nvim_win_set_config(win, {
      title = { { " Run configuration · " .. parsed.name .. " ", "FloatTitle" } },
      title_pos = "left",
    })
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
      read(state)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      decorate(state)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMovedI", {
    buffer = buf,
    callback = function()
      decorate(state)
    end,
  })
  local function k(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  k("n", "q", close, "Close")
  k("n", "<Esc>", close, "Close")
  k("n", "<CR>", function()
    enter(state, false)
  end, "Pick / edit the field")
  k("i", "<CR>", function()
    enter(state, true)
  end, "Pick / next field")
  k({ "n", "i" }, "<Tab>", function()
    step(state, 1)
  end, "Next field")
  k({ "n", "i" }, "<S-Tab>", function()
    step(state, -1)
  end, "Previous field")
  -- the shape stays one line per field
  k("n", "o", function()
    step(state, 1)
    vim.cmd("startinsert!")
  end, "Next field")
  k("n", "O", function()
    step(state, -1)
    vim.cmd("startinsert!")
  end, "Previous field")
  k("n", "dd", function()
    if not CHOICE[field_at(state)] then
      vim.api.nvim_set_current_line("")
    end
  end, "Clear the field")
  k("n", "J", "<Nop>", "")
  k({ "n", "i" }, "<C-CR>", function()
    vim.cmd("stopinsert")
    local saved = save()
    if saved then
      vim.api.nvim_win_close(win, true)
      require("aedi.console").start(saved)
    end
  end, "Save and run")
  k({ "n", "i" }, "<C-d>", function()
    vim.cmd("stopinsert")
    local saved = save()
    if saved then
      vim.api.nvim_win_close(win, true)
      require("aedi.console").start(saved, { debug = true })
    end
  end, "Save and debug")

  -- start where there is something to fill in
  local fields = fields_of(state)
  local first = 2
  for i, f in ipairs(fields) do
    if f ~= "type" and (state.values[f] or "") == "" and (f == "name" or f == "command" or f == "tasks") then
      first = i
      break
    end
  end
  if c and first == 2 then
    first = vim.tbl_contains(fields, "profiles") and vim.fn.index(fields, "profiles") + 1 or 2
  end
  vim.api.nvim_win_set_cursor(win, { first, #(state.values[fields[first]] or "") })
  decorate(state)
end

function M.setup()
  local function hl(name)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and h or {}
  end
  local function define()
    local muted = hl("Comment").fg
    local accent = hl("FloatTitle").fg or hl("Special").fg
    local set = vim.api.nvim_set_hl
    set(0, "AediFormLabel", { fg = muted, default = true })
    set(0, "AediFormLabelActive", { fg = accent, bold = true, default = true })
    set(0, "AediFormMuted", { fg = muted, default = true })
    set(0, "AediFormKey", { fg = accent, default = true })
    set(0, "AediFormPlaceholder", { fg = hl("NonText").fg or muted, default = true })
    set(0, "AediFormCommand", { fg = hl("String").fg, default = true })
    set(0, "AediFormError", { link = "DiagnosticError", default = true })
    set(0, "AediFormValue", { bold = true, default = true })
    set(0, "AediFormCursorLine", { link = "CursorLine", default = true })
  end
  define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("aedi_form", { clear = true }),
    callback = function()
      vim.schedule(define)
    end,
  })
end

return M
