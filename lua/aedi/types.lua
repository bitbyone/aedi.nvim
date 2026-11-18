-- Kinds of run configuration, IntelliJ's Application / Spring Boot / Gradle /
-- Shell Script: which fields each has, and what running it does.
--
--   application   a main class, launched through the IntelliJ server
--                 (intellij-lsp.nvim): Run, or Debug with the debugger
--   spring-boot   its application's main class the same way, profiles as
--                 `--spring.profiles.active`; or, with launcher `bootRun`,
--                 `gradlew [:module:]bootRun --args='...'` / `mvnw
--                 spring-boot:run -Dspring-boot.run.profiles=...`
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
  launcher = { label = "Launch", placeholder = "", help = "Enter changes it" },
  main = { label = "Main class", placeholder = "Enter picks one", help = "Enter picks one" },
  module = { label = "Module", placeholder = "the project root", help = "Enter picks one" },
  profiles = { label = "Profiles", placeholder = "none: the default profile", help = "Enter picks them" },
  args = { label = "Arguments", placeholder = "none" },
  vm = { label = "VM options", placeholder = "none (e.g. -Xmx1g -Dfoo=bar)" },
  env = { label = "Environment", placeholder = "KEY=value KEY2='with space'" },
  tasks = { label = "Tasks", placeholder = "e.g. test --tests '*UserTest'" },
  command = { label = "Command", placeholder = "e.g. go run ./cmd/server" },
  cwd = { label = "Directory", placeholder = "the project root" },
}

--- Spring Boot's launchers: the IntelliJ server (Run and Debug), or the
--- build tool's bootRun (Run only).
M.launchers = {
  { id = "intellij", label = "IntelliJ (Run and Debug)" },
  { id = "bootRun", label = "Gradle bootRun / Maven spring-boot:run (Run only)" },
}

---@class aedi.Type
---@field label string
---@field fields string[]
---@field args_placeholder? string
---@field hidden? fun(field: string, values: table): boolean a field this configuration does not use

---@type table<string, aedi.Type>
M.types = {
  application = {
    label = "Application",
    fields = { "name", "main", "args", "vm", "env", "cwd" },
    args_placeholder = "none (program arguments)",
  },
  ["spring-boot"] = {
    label = "Spring Boot",
    fields = { "name", "launcher", "module", "profiles", "args", "vm", "env" },
    args_placeholder = "none (program arguments, e.g. --server.port=8081)",
    hidden = function(field, values)
      return field == "vm" and values.launcher == "bootRun"
    end,
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

M.order = { "application", "spring-boot", "gradle", "shell" }

---@param c aedi.Configuration
---@return string
function M.of(c)
  return M.types[c.type or ""] and c.type or "shell"
end

---@param c aedi.Configuration
function M.label(c)
  return M.types[M.of(c)].label
end

--- Runs through the IntelliJ server, so it can be debugged.
---@param c aedi.Configuration
function M.debuggable(c)
  local t = M.of(c)
  return t == "application" or (t == "spring-boot" and c.launcher ~= "bootRun")
end

--- `-Xmx1g "-Dx=a b" 'c d'` -> { "-Xmx1g", "-Dx=a b", "c d" }
---@param s? string
---@return string[]
function M.split_args(s)
  local out, cur, quote, any = {}, {}, nil, false
  for ch in (s or ""):gmatch(".") do
    if quote then
      if ch == quote then
        quote = nil
      else
        cur[#cur + 1] = ch
      end
    elseif ch == "'" or ch == '"' then
      quote, any = ch, true
    elseif ch:match("%s") then
      if #cur > 0 or any then
        out[#out + 1] = table.concat(cur)
      end
      cur, any = {}, false
    else
      cur[#cur + 1] = ch
    end
  end
  if #cur > 0 or any then
    out[#out + 1] = table.concat(cur)
  end
  return out
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

  if t == "application" or (t == "spring-boot" and c.launcher ~= "bootRun") then
    local jvm = require("aedi.jvm")
    local main
    if t == "application" then
      if not nonempty(c.main) then
        return nil, "no main class"
      end
      main = jvm.find(root, c.main) or { class = c.main, file = root }
    else
      main = jvm.spring_main(root, c.module)
      if not main then
        return nil, "no @SpringBootApplication main class" .. (nonempty(c.module) and (" in " .. c.module) or "")
      end
    end
    local args = M.split_args(c.args)
    local profiles = spring.normalize(c.profiles)
    if t == "spring-boot" and profiles ~= "" then
      table.insert(args, 1, "--spring.profiles.active=" .. profiles)
    end
    local cwd = root
    if nonempty(c.cwd) and c.cwd ~= "." then
      cwd = vim.fs.normalize(c.cwd:sub(1, 1) == "/" and c.cwd or (root .. "/" .. c.cwd))
    end
    local vm = M.split_args(c.vm)
    local shown = { "java" }
    vim.list_extend(shown, vm)
    shown[#shown + 1] = main.class
    vim.list_extend(shown, args)
    return {
      cmd = table.concat(vim.tbl_map(function(a)
        return a:find("[%s'\"]") and vim.fn.shellescape(a) or a
      end, shown), " "),
      cwd = cwd,
      env = c.env,
      intellij = {
        name = c.name,
        mainClass = main.class,
        file = main.file,
        args = args,
        vmArgs = vm,
        env = c.env,
        cwd = cwd,
      },
    }
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
