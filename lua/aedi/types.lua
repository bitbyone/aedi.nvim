-- Kinds of run configuration, IntelliJ's Spring Boot / Gradle / Shell Script:
-- which fields each has, and the command line it turns into.
--
--   spring-boot   the project's build tool runs the app: `gradlew
--                 [:module:]bootRun --args='--spring.profiles.active=...'`
--                 or `mvnw spring-boot:run -Dspring-boot.run.profiles=...`
--   gradle        `gradlew <tasks> <args>` (or Maven's wrapper and goals)
--   shell         any command, in any directory

local spring = require("aedi.spring")

local M = {}

---@class aedi.Field
---@field label string
---@field placeholder string
---@field help? string shown beside the field while the cursor is on it

---@type table<string, aedi.Field>
M.fields = {
  name = { label = "Name", placeholder = "how it shows in the Run list" },
  module = { label = "Module", placeholder = "the project root", help = "Enter picks one" },
  profiles = { label = "Profiles", placeholder = "none: the default profile", help = "Enter picks them" },
  args = { label = "Arguments", placeholder = "none" },
  env = { label = "Environment", placeholder = "KEY=value KEY2='with space'" },
  tasks = { label = "Tasks", placeholder = "e.g. test --tests '*UserTest'" },
  command = { label = "Command", placeholder = "e.g. go run ./cmd/server" },
  cwd = { label = "Directory", placeholder = "the project root" },
}

---@class aedi.Type
---@field label string
---@field fields string[]
---@field args_placeholder? string

---@type table<string, aedi.Type>
M.types = {
  ["spring-boot"] = {
    label = "Spring Boot",
    fields = { "name", "module", "profiles", "args", "env" },
    args_placeholder = "none (program arguments, e.g. --server.port=8081)",
  },
  gradle = {
    label = "Gradle",
    fields = { "name", "tasks", "args", "env" },
    args_placeholder = "none (e.g. --info --offline)",
  },
  shell = {
    label = "Shell command",
    fields = { "name", "command", "args", "cwd", "env" },
    args_placeholder = "none (appended to the command)",
  },
}

M.order = { "spring-boot", "gradle", "shell" }

---@param c aedi.Configuration
---@return string
function M.of(c)
  return M.types[c.type or ""] and c.type or "shell"
end

---@param c aedi.Configuration
function M.label(c)
  return M.types[M.of(c)].label
end

-- ---------------------------------------------------------------------------
-- env as one line: KEY=value KEY2='a b' KEY3="c d"
-- ---------------------------------------------------------------------------

---@param s string
---@return table<string, string>?, string? error
function M.parse_env(s)
  local env, i, n = {}, 1, #s
  while i <= n do
    local ws = s:match("^%s+", i)
    if ws then
      i = i + #ws
    end
    if i > n then
      break
    end
    local key = s:match("^([%a_][%w_]*)=", i)
    if not key then
      return nil, "environment: expected KEY=value at " .. s:sub(i, i + 10)
    end
    i = i + #key + 1
    local q = s:sub(i, i)
    local value
    if q == "'" or q == '"' then
      local close = s:find(q, i + 1, true)
      if not close then
        return nil, "environment: unclosed " .. q
      end
      value = s:sub(i + 1, close - 1)
      i = close + 1
    else
      value = s:match("^[^%s]*", i)
      i = i + #value
    end
    env[key] = value
  end
  return env
end

---@param env? table<string, string>
---@return string
function M.format_env(env)
  local keys = vim.tbl_keys(env or {})
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = env[k]
    if v == "" or v:find("[%s'\"]") then
      v = v:find("'") and ('"' .. v .. '"') or ("'" .. v .. "'")
    end
    parts[#parts + 1] = k .. "=" .. v
  end
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- The command line
-- ---------------------------------------------------------------------------

local function nonempty(s)
  return s and s ~= "" and s or nil
end

---@class aedi.Launch
---@field cmd string the shell command line
---@field cwd string
---@field env? table<string, string>

--- What running `c` runs, or why it cannot.
---@param c aedi.Configuration
---@param root string
---@return aedi.Launch?, string? error
function M.build(c, root)
  local t = M.of(c)
  if t == "shell" then
    if not nonempty(c.command) then
      return nil, "no command"
    end
    local cwd = root
    if nonempty(c.cwd) and c.cwd ~= "." then
      cwd = vim.fn.expand(c.cwd)
      if cwd:sub(1, 1) ~= "/" then
        cwd = root .. "/" .. cwd
      end
      cwd = vim.fs.normalize(cwd)
    end
    return { cmd = c.command .. (nonempty(c.args) and (" " .. c.args) or ""), cwd = cwd, env = c.env }
  end

  local tool, kind = require("aedi.detect").build_tool(root)
  if not tool then
    return nil, "no gradlew / mvnw / build file in " .. root
  end

  if t == "gradle" then
    if not nonempty(c.tasks) then
      return nil, "no tasks"
    end
    return { cmd = tool .. " " .. c.tasks .. (nonempty(c.args) and (" " .. c.args) or ""), cwd = root, env = c.env }
  end

  -- spring-boot
  local profiles = spring.normalize(c.profiles)
  local module = nonempty(c.module)
  local cmd
  if kind == "maven" then
    cmd = tool .. " spring-boot:run"
    if module then
      cmd = cmd .. " -pl " .. module
    end
    if profiles ~= "" then
      cmd = cmd .. " -Dspring-boot.run.profiles=" .. profiles
    end
    if nonempty(c.args) then
      cmd = cmd .. " -Dspring-boot.run.arguments=" .. vim.fn.shellescape(c.args)
    end
  else
    cmd = tool .. " " .. (module and (":" .. module:gsub("/", ":") .. ":") or "") .. "bootRun"
    local app = {}
    if profiles ~= "" then
      app[#app + 1] = "--spring.profiles.active=" .. profiles
    end
    if nonempty(c.args) then
      app[#app + 1] = c.args
    end
    if #app > 0 then
      cmd = cmd .. " --args=" .. vim.fn.shellescape(table.concat(app, " "))
    end
  end
  return { cmd = cmd, cwd = root, env = c.env }
end

--- The command line as the list and the form show it.
---@param c aedi.Configuration
---@param root string
---@return string
function M.preview(c, root)
  local l, err = M.build(c, root)
  if not l then
    return "(" .. err .. ")"
  end
  return l.cmd
end

return M
