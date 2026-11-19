-- A command prompt with suggestions under it, like a shell's history and
-- completion -- not a picker. What is typed is what runs:
--
--   * typing filters the suggestions and selects none; Enter runs the text
--   * moving through them (Down / Up, Ctrl-N / Ctrl-P, Tab / Shift-Tab) puts
--     the one under the cursor into the input, to run as it is or to edit --
--     the list stays as the typing left it
--   * Enter runs whatever the input holds
--
--   ╭ Gradle tasks ───────────────────────────────────────── 36/573 ╮
--   │ › build -x test                                                │
--   ├────────────────────────────────────────────────────────────────┤
--   │ build -x test             Recent                               │
--   │ build                     Build     Assembles and tests this… │
--   ╰ Enter run · ↓↑ choose · Ctrl-X forget a recent · Esc close ────╯

local M = {}

local ns = vim.api.nvim_create_namespace("aedi_prompt")

---@class aedi.PromptItem
---@field text string what goes into the input
---@field cols string[] what the row shows after the text
---@field recent? boolean

---@class aedi.PromptSpec
---@field title string
---@field items fun(query: string): aedi.PromptItem[], integer total
---@field submit fun(text: string)
---@field forget? fun(item: aedi.PromptItem) Ctrl-X on a recent one
---@field hints? aedi.Hint
---@field text? string the input to start with

local function define()
  local function link(a, b)
    vim.api.nvim_set_hl(0, a, { link = b, default = true })
  end
  link("AediPromptSel", "PmenuSel")
  link("AediPromptMatch", "SnacksPickerMatch")
  link("AediPromptRecent", "AediFormKey")
  link("AediPromptCol", "AediFormMuted")
  link("AediPromptDesc", "AediFormPlaceholder")
  link("AediPromptMark", "FloatTitle")
end

---@param spec aedi.PromptSpec
function M.open(spec)
  define()
  local width = math.min(110, vim.o.columns - 6)
  local list_h = math.min(16, vim.o.lines - 10)
  local row = math.floor((vim.o.lines - list_h - 3) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)

  local in_buf = vim.api.nvim_create_buf(false, true)
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[in_buf].bufhidden = "wipe"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.b[in_buf].completion = false -- blink.cmp
  vim.b[in_buf].snacks_scroll = false

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor",
    row = row + 2,
    col = col,
    width = width,
    height = list_h,
    border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    footer = require("aedi.hints").chunks(spec.hints or {
      { "Enter", "run" },
      { "↓↑", "choose" },
      { "Esc", "close" },
    }),
    footer_pos = "left",
    focusable = false,
    zindex = 60,
  })
  local in_win = vim.api.nvim_open_win(in_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    border = { "╭", "─", "╮", "│", "", "", "", "│" },
    title = { { " " .. spec.title .. " ", "FloatTitle" } },
    title_pos = "left",
    zindex = 61,
  })
  for _, w in ipairs({ in_win, list_win }) do
    local wo = vim.wo[w]
    wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
    wo.list, wo.wrap, wo.spell, wo.cursorline = false, false, false, false
    wo.statuscolumn, wo.foldcolumn = "", "0"
  end

  local state = { query = spec.text or "", sel = nil, items = {}, total = 0 }

  -- Text put into the input by choosing (not typing). TextChangedI comes
  -- later, on its own, so the text itself says it was not typed.
  local function set_input(text)
    state.put = text
    vim.api.nvim_buf_set_lines(in_buf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(in_win, { 1, #text })
  end

  local function draw()
    local lines, marks = {}, {}
    local name_w, col_w = 20, 0
    for _, it in ipairs(state.items) do
      name_w = math.max(name_w, math.min(48, vim.fn.strdisplaywidth(it.text)))
      col_w = math.max(col_w, #(it.cols[1] or ""))
    end
    for i, it in ipairs(state.items) do
      local parts = { ("%-" .. name_w .. "s"):format(it.text) }
      for j, c in ipairs(it.cols) do
        parts[#parts + 1] = (j == 1 and it.cols[2]) and ("%-" .. col_w .. "s"):format(c) or c
      end
      lines[i] = " " .. table.concat(parts, "  ")
      marks[i] = { name_w = name_w, col_w = col_w, cols = it.cols, recent = it.recent }
    end
    if #lines == 0 then
      lines = { "  nothing matches -- Enter runs what you typed" }
    end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for i, m in ipairs(marks) do
      local start = 1 + m.name_w + 2
      if m.cols[1] then
        vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, start, {
          end_col = start + #m.cols[1],
          hl_group = m.recent and "AediPromptRecent" or "AediPromptCol",
        })
        if m.cols[2] then
          local s2 = start + m.col_w + 2
          vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, s2, { end_col = #lines[i], hl_group = "AediPromptDesc" })
        end
      end
      for _, pos in ipairs(state.items[i].pos or {}) do
        vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, 1 + pos, { end_col = 2 + pos, hl_group = "AediPromptMatch" })
      end
    end
    if state.sel then
      vim.api.nvim_buf_set_extmark(list_buf, ns, state.sel - 1, 0, {
        end_row = state.sel,
        end_col = 0,
        hl_group = "AediPromptSel",
        hl_eol = true,
        priority = 10,
      })
      vim.api.nvim_win_set_cursor(list_win, { state.sel, 0 })
    else
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
    end
    -- the count, at the end of the input line
    vim.api.nvim_buf_clear_namespace(in_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(in_buf, ns, 0, 0, {
      virt_text = { { ("%d/%d "):format(#state.items, state.total), "AediPromptCol" } },
      virt_text_pos = "right_align",
    })
  end

  local function refresh()
    state.items, state.total = spec.items(state.query)
    state.sel = nil
    draw()
  end

  local function move(delta)
    local n = #state.items
    if n == 0 then
      return
    end
    if not state.sel then
      state.sel = delta > 0 and 1 or n
    else
      state.sel = (state.sel - 1 + delta) % n + 1
    end
    set_input(state.items[state.sel].text)
    draw()
  end

  local function close()
    for _, w in ipairs({ in_win, list_win }) do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
    vim.cmd("stopinsert")
  end

  local function submit()
    local text = vim.trim(vim.api.nvim_buf_get_lines(in_buf, 0, 1, false)[1] or "")
    close()
    if text ~= "" then
      vim.schedule(function()
        spec.submit(text)
      end)
    end
  end

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = in_buf,
    callback = function()
      local line = vim.api.nvim_buf_get_lines(in_buf, 0, 1, false)[1] or ""
      if line == state.put then
        return
      end
      state.put = nil
      -- typed: the suggestions follow the text, and none is chosen
      state.query = line
      refresh()
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = in_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  local function k(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = in_buf, nowait = true })
  end
  k("<CR>", submit)
  k("<Esc>", close)
  k("<C-c>", close)
  for _, lhs in ipairs({ "<Down>", "<C-n>", "<Tab>", "<C-j>" }) do
    k(lhs, function()
      move(1)
    end)
  end
  for _, lhs in ipairs({ "<Up>", "<C-p>", "<S-Tab>", "<C-k>" }) do
    k(lhs, function()
      move(-1)
    end)
  end
  k("<C-x>", function()
    local it = state.sel and state.items[state.sel]
    if it and it.recent and spec.forget then
      spec.forget(it)
      local keep = state.sel
      state.items, state.total = spec.items(state.query)
      state.sel = #state.items > 0 and math.min(keep, #state.items) or nil
      if state.sel then
        set_input(state.items[state.sel].text)
      end
      draw()
    end
  end)

  set_input(state.query)
  refresh()
  vim.cmd("startinsert!")
  return { refresh = function()
    if vim.api.nvim_win_is_valid(in_win) then
      local keep = state.sel
      state.items, state.total = spec.items(state.query)
      state.sel = keep and #state.items > 0 and math.min(keep, #state.items) or nil
      draw()
    end
  end, title = function(t)
    if vim.api.nvim_win_is_valid(in_win) then
      vim.api.nvim_win_set_config(in_win, { title = { { " " .. t .. " ", "FloatTitle" } }, title_pos = "left" })
    end
  end }
end

return M
