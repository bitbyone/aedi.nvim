-- Saved run configurations, per project.
--
-- One JSON file (`options.store`) for every project:
--
--   { "version": 1,
--     "projects": {
--       "/path/to/project": {
--         "configurations": [ { "name": "App", "command": "go run .", ... } ],
--         "last": "App" } } }

---@class aedi.Configuration
---@field name string
---@field command string shell command, run by 'shell' in `cwd`
---@field args? string appended to `command`
---@field cwd? string relative to the project root, or absolute
---@field env? table<string, string>
---@field detected? boolean found in the project, not saved
---@field kind? "run"|"test"|"build"
---@field type? "shell"|"spring-boot"|"gradle" (nil: shell)
---@field profiles? string Spring profiles, "a,b"
---@field module? string the Spring Boot application's directory
---@field tasks? string Gradle tasks
---@field launcher? "intellij"|"bootRun" how a Spring Boot one runs (nil: intellij)
---@field main? string an Application's main class
---@field vm? string VM options

local M = {}

---@type table?
local data

local function file()
  return require("aedi.config").options.store
end

local function load()
  if data then
    return data
  end
  data = { version = 1, projects = {} }
  local f = io.open(file(), "r")
  if f then
    local ok, decoded = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
    f:close()
    if ok and type(decoded) == "table" and type(decoded.projects) == "table" then
      data = decoded
    end
  end
  return data
end

local function save()
  local path = file()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(load()))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

---@param root? string
local function project(root)
  root = root or require("aedi.util").root()
  local projects = load().projects
  projects[root] = projects[root] or { configurations = {} }
  projects[root].configurations = projects[root].configurations or {}
  return projects[root]
end

--- Forget the cached file (tests; another nvim may have written it).
function M.reload()
  data = nil
end

--- A copy without the fields that only describe where it came from.
---@param c aedi.Configuration
---@return aedi.Configuration
local function clean(c)
  local out = {
    name = c.name,
    type = (c.type and c.type ~= "shell") and c.type or nil,
    profiles = (c.profiles and c.profiles ~= "") and c.profiles or nil,
    module = (c.module and c.module ~= "") and c.module or nil,
    tasks = (c.tasks and c.tasks ~= "") and c.tasks or nil,
    launcher = (c.launcher and c.launcher ~= "" and c.launcher ~= "intellij") and c.launcher or nil,
    main = (c.main and c.main ~= "") and c.main or nil,
    vm = (c.vm and c.vm ~= "") and c.vm or nil,
    command = c.command,
    args = (c.args and c.args ~= "") and c.args or nil,
    cwd = (c.cwd and c.cwd ~= "" and c.cwd ~= ".") and c.cwd or nil,
    env = (c.env and next(c.env)) and c.env or nil,
  }
  return out
end

--- The saved configurations of a project.
---@param root? string
---@return aedi.Configuration[]
function M.list(root)
  return vim.deepcopy(project(root).configurations)
end

---@param name string
---@param root? string
---@return aedi.Configuration?
function M.get(name, root)
  for _, c in ipairs(project(root).configurations) do
    if c.name == name then
      return vim.deepcopy(c)
    end
  end
end

--- Save `c`; `old` is the name it was saved under, when it is renamed.
---@param c aedi.Configuration
---@param old? string
---@param root? string
function M.put(c, old, root)
  local p = project(root)
  local list = p.configurations
  local at
  for i, x in ipairs(list) do
    if x.name == (old or c.name) then
      at = i
    elseif x.name == c.name then
      error(("A configuration named %q already exists"):format(c.name), 0)
    end
  end
  if at then
    list[at] = clean(c)
  else
    list[#list + 1] = clean(c)
  end
  if old and old ~= c.name and p.stats and p.stats[old] then
    p.stats[c.name], p.stats[old] = p.stats[old], nil
  end
  -- Rerun runs what was edited, not the copy taken when it last ran.
  if p.last == (old or c.name) then
    p.last = c.name
  p.stats = p.stats or {}
  local s = p.stats[c.name] or { count = 0 }
  s.count, s.at = s.count + 1, os.time()
  p.stats[c.name] = s
    p.last_config = clean(c)
  end
  save()
end

---@param name string
---@param root? string
function M.delete(name, root)
  local p = project(root)
  p.configurations = vim.tbl_filter(function(x)
    return x.name ~= name
  end, p.configurations)
  if p.last == name then
    p.last, p.last_config = nil, nil
  end
  if p.stats then
    p.stats[name] = nil
  end
  save()
end

--- The configuration run last in this project (saved or detected).
---@param root? string
---@return aedi.Configuration?
function M.last(root)
  return project(root).last_config and vim.deepcopy(project(root).last_config) or nil
end

---@param c aedi.Configuration
---@param root? string
function M.set_last(c, root)
  local p = project(root)
  p.last = c.name
  p.stats = p.stats or {}
  local s = p.stats[c.name] or { count = 0 }
  s.count, s.at = s.count + 1, os.time()
  p.stats[c.name] = s
  p.last_config = vim.tbl_extend("force", clean(c), { detected = c.detected, kind = c.kind })
  save()
end

--- How much `name` is used: runs, weighted by how recent the last one was
--- (frecency). 0 for one never run.
---@param name string
---@param root? string
---@param now? integer
---@return number
function M.score(name, root, now)
  local s = (project(root).stats or {})[name]
  if not s then
    return 0
  end
  local age = (now or os.time()) - (s.at or 0)
  local weight = age < 3600 and 8 or age < 86400 and 4 or age < 7 * 86400 and 2 or age < 30 * 86400 and 1 or 0.5
  return s.count * weight
end

return M
