-- The project's Gradle tasks, indexed in the background -- IntelliJ's Gradle
-- tool window, as a picker.
--
-- A run of `./gradlew help` with aedi's init script (gradle/aedi-tasks.gradle)
-- writes every task of every project as JSON -- no `gradle tasks` text to
-- parse. It runs at low priority a few seconds after Neovim starts in a Gradle
-- project, and again when a build file changes; nothing is shown while it
-- does. The list is kept per project in
-- stdpath("data")/aedi/gradle/, keyed by the build files' modification
-- times, so a project whose build has not changed is never indexed twice.
--
-- `pick()`: the tasks, with group and description.
--   Enter    run the task (or, when what you typed matches none, run that:
--            `test --tests '*UserTest'`)
--   Ctrl-E   put the task into the input, to add arguments to it

local M = {}

---@class aedi.GradleTask
---@field name string as run: `build`, `playground:bootRun`
---@field group string
---@field desc string

---@type table<string, { running: boolean, error?: string, waiters: fun()[] }>
local state = {}

local function dir()
  return vim.fn.stdpath("data") .. "/aedi/gradle"
end

local function cache_file(root)
  return dir() .. "/" .. vim.fn.sha256(root):sub(1, 16) .. ".json"
end

--- The build files' sizes and modification times: the cache's key. The root
--- and one level of subprojects; that is where settings and builds live.
---@param root string
---@return string
function M.fingerprint(root)
  local parts = {}
  local names = {
    ["build.gradle"] = true,
    ["build.gradle.kts"] = true,
    ["settings.gradle"] = true,
    ["settings.gradle.kts"] = true,
    ["gradle.properties"] = true,
    ["libs.versions.toml"] = true,
  }
  local function look(d, depth)
    for name, type in vim.fs.dir(d) do
      local path = d .. "/" .. name
      if type == "file" and names[name] then
        local st = vim.uv.fs_stat(path)
        if st then
          parts[#parts + 1] = ("%s:%d:%d"):format(path:sub(#root + 2), st.size, st.mtime.sec)
        end
      elseif type == "directory" and depth > 0 and not name:match("^%.") and name ~= "build" and name ~= "node_modules" then
        look(path, depth - 1)
      end
    end
  end
  look(root, 1)
  if vim.uv.fs_stat(root .. "/gradle") then
    look(root .. "/gradle", 0)
  end
  table.sort(parts)
  return vim.fn.sha256(table.concat(parts, "\n"))
end

--- The init script that writes the task list, shipped with the plugin.
local function init_script()
  local here = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fs.dirname(here) .. "/../../gradle/aedi-tasks.gradle")
end
M.init_script = init_script

local GROUP_ORDER = { application = 1, build = 2, verification = 3, documentation = 4, distribution = 5, help = 8 }

--- The init script's JSON as tasks: grouped ones first (Application, Build,
--- Verification, ... then the project's own groups), "Other" last.
---@param json string
---@return aedi.GradleTask[]
function M.from_json(json)
  local ok, list = pcall(vim.json.decode, json)
  if not ok or type(list) ~= "table" then
    return {}
  end
  local out = {}
  for _, t in ipairs(list) do
    local g = t.group or ""
    out[#out + 1] = {
      name = t.name,
      group = g == "" and "Other" or (g:sub(1, 1):upper() .. g:sub(2)),
      desc = t.description or "",
      rank = g == "" and 9 or (GROUP_ORDER[g:lower()] or 6),
    }
  end
  table.sort(out, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    if a.group ~= b.group then
      return a.group < b.group
    end
    -- the root project's tasks before a subproject's
    local ca, cb = select(2, a.name:gsub(":", "")), select(2, b.name:gsub(":", ""))
    if ca ~= cb then
      return ca < cb
    end
    return a.name < b.name
  end)
  for _, t in ipairs(out) do
    t.rank = nil
  end
  return out
end

--- The cached tasks of `root` (nil: never indexed), and whether they are
--- current.
---@param root string
---@return aedi.GradleTask[]?, boolean fresh
function M.cached(root)
  local f = io.open(cache_file(root), "r")
  if not f then
    return nil, false
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not ok or type(data) ~= "table" then
    return nil, false
  end
  return data.tasks, data.key == M.fingerprint(root)
end

---@param root string
function M.status(root)
  return state[root] or { running = false, waiters = {} }
end

--- Index `root`'s tasks in the background (once at a time); `done` runs
--- when it finishes.
---@param root string
---@param done? fun()
function M.refresh(root, done)
  local tool, kind = require("aedi.detect").build_tool(root)
  if kind ~= "gradle" then
    return
  end
  local s = state[root] or { running = false, waiters = {} }
  state[root] = s
  if done then
    s.waiters[#s.waiters + 1] = done
  end
  if s.running then
    return
  end
  s.running = true
  local key = M.fingerprint(root)
  local out = vim.fn.tempname() .. ".json"
  -- `help` does nothing; the configuration cache would skip the script.
  local cmd = { tool, "help", "-q", "--console=plain", "--no-configuration-cache", "-I", init_script(), "-Paedi.tasksOut=" .. out }
  if vim.fn.executable("nice") == 1 then
    cmd = vim.list_extend({ "nice", "-n", "10" }, cmd)
  end
  -- the JDK mise pins for the project, when it does
  vim.system(cmd, { cwd = root, text = true, env = require("aedi.env").project(root) }, function(res)
    vim.schedule(function()
      s.running = false
      local f_out = io.open(out, "r")
      local json = f_out and f_out:read("*a")
      if f_out then
        f_out:close()
        os.remove(out)
      end
      if res.code == 0 and json then
        local tasks = M.from_json(json)
        s.error = nil
        vim.fn.mkdir(dir(), "p")
        local f = io.open(cache_file(root), "w")
        if f then
          f:write(vim.json.encode({ root = root, key = key, tasks = tasks }))
          f:close()
        end
      else
        local err = vim.trim(res.stderr or "")
        s.error = err:match("What went wrong:%s*\n([^\n]+)") or err:match("([^\n]+)") or ("exit " .. res.code)
      end
      local waiters = s.waiters
      s.waiters = {}
      for _, w in ipairs(waiters) do
        pcall(w)
      end
    end)
  end)
end

--- Index now if the cache is missing or stale.
---@param root string
function M.ensure(root)
  local tasks, fresh = M.cached(root)
  if not tasks or not fresh then
    M.refresh(root)
  end
end

--- Run `text` (`build`, `test --tests '*Foo'`) as a Gradle configuration,
--- in the Run panel.
---@param text string
function M.run(text)
  text = vim.trim(text)
  if text == "" then
    return
  end
  require("aedi.console").start({ name = "gradle " .. text, type = "gradle", tasks = text })
end

-- ---------------------------------------------------------------------------
-- Recent command lines
-- ---------------------------------------------------------------------------

local MAX_RECENT = 30

local function recent_file(root)
  return dir() .. "/" .. vim.fn.sha256(root):sub(1, 16) .. ".recent.json"
end

--- The task lines run in `root`, the last first.
---@param root string
---@return string[]
function M.recent(root)
  local f = io.open(recent_file(root), "r")
  if not f then
    return {}
  end
  local ok, list = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(list) == "table" and list or {}
end

local function save_recent(root, list)
  vim.fn.mkdir(dir(), "p")
  local f = io.open(recent_file(root), "w")
  if f then
    f:write(vim.json.encode(list))
    f:close()
  end
end

--- Put `text` first among the recent task lines of `root`.
---@param root string
---@param text string
function M.remember(root, text)
  local list = { text }
  for _, t in ipairs(M.recent(root)) do
    if t ~= text and #list < MAX_RECENT then
      list[#list + 1] = t
    end
  end
  save_recent(root, list)
end

---@param root string
---@param text string
function M.forget(root, text)
  save_recent(root, vim.tbl_filter(function(t)
    return t ~= text
  end, M.recent(root)))
end

--- The suggestions for `query`: recent task lines (matched on the whole
--- line), then the indexed tasks (matched on its first word, so `test --tests
--- …` still offers `test`), best match first.
---@param root string
---@param query string
---@return aedi.PromptItem[], integer total
function M.suggest(root, query)
  local recent = M.recent(root)
  local tasks = M.cached(root) or {}
  local out = {}
  local q = vim.trim(query)
  if q == "" then
    for _, r in ipairs(recent) do
      out[#out + 1] = { text = r, cols = { "Recent" }, recent = true }
    end
    for _, t in ipairs(tasks) do
      out[#out + 1] = { text = t.name, cols = { t.group, t.desc } }
    end
    return out, #recent + #tasks
  end
  local matched, pos = unpack(vim.fn.matchfuzzypos(recent, q))
  for i, r in ipairs(matched) do
    out[#out + 1] = { text = r, cols = { "Recent" }, recent = true, pos = pos[i] }
  end
  local by_name = {}
  local names = {}
  for _, t in ipairs(tasks) do
    by_name[t.name] = t
    names[#names + 1] = t.name
  end
  local word = q:match("^%S+")
  local tm, tp = unpack(vim.fn.matchfuzzypos(names, word))
  for i, name in ipairs(tm) do
    local t = by_name[name]
    out[#out + 1] = { text = name, cols = { t.group, t.desc }, pos = tp[i] }
  end
  return out, #recent + #tasks
end

--- The task prompt: type a task line (`build -x test`) or choose one of the
--- project's tasks and recent lines; Enter runs it (or, with `on_choose`,
--- gives it back). What runs is remembered as recent.
---@param opts? { on_choose?: fun(task: string), text?: string }
function M.pick(opts)
  opts = opts or {}
  local root = require("aedi.util").root()
  local _, kind = require("aedi.detect").build_tool(root)
  if kind ~= "gradle" then
    vim.notify("Not a Gradle project: " .. root, vim.log.levels.INFO)
    return
  end
  M.ensure(root)
  local function title()
    local s = M.status(root)
    if s.running then
      return M.cached(root) and "Gradle tasks · reindexing…" or "Gradle tasks · indexing…"
    elseif s.error then
      return "Gradle tasks · index failed: " .. s.error
    end
    return "Gradle tasks"
  end
  local handle = require("aedi.prompt").open({
    title = title(),
    text = opts.text,
    items = function(query)
      return M.suggest(root, query)
    end,
    submit = function(text)
      M.remember(root, text)
      if opts.on_choose then
        opts.on_choose(text)
      else
        M.run(text)
      end
    end,
    forget = function(item)
      M.forget(root, item.text)
    end,
    hints = {
      { "Enter", opts.on_choose and "choose" or "run" },
      { "↓↑", "pick into the input" },
      { "Ctrl-X", "forget a recent" },
      { "Esc", "close" },
    },
  })
  -- tasks arriving while it is open
  if M.status(root).running then
    M.refresh(root, function()
      handle.title(title())
      handle.refresh()
    end)
  end
end

--- Index in the background: a few seconds after startup (or a change of
--- directory) in a Gradle project, and after a build file is written.
function M.setup()
  local group = vim.api.nvim_create_augroup("aedi_gradle", { clear = true })
  local function later()
    vim.defer_fn(function()
      M.ensure(require("aedi.util").root())
    end, 3000)
  end
  vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, { group = group, callback = later })
  if vim.v.vim_did_enter == 1 then
    later()
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.gradle", "*.gradle.kts", "libs.versions.toml", "gradle.properties" },
    callback = function()
      M.ensure(require("aedi.util").root())
    end,
  })
end

return M
