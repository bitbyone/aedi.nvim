-- Configurations found in the project, offered next to the saved ones the way
-- IntelliJ offers the Gradle tasks and main classes it found: run straight
-- away, or edited into a saved configuration of their own.
--
-- Each detector looks at the project root and returns configurations; add
-- your own with `setup({ detectors = { function(root) ... end } })`.

local M = {}

local function exists(root, name)
  return vim.uv.fs_stat(root .. "/" .. name) ~= nil
end

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function cfg(name, command, kind)
  return { name = name, command = command, kind = kind, detected = true }
end

--- The project's build tool: its wrapper when it ships one.
---@param root string
---@return string? command, "gradle"|"maven"|nil tool
function M.build_tool(root)
  if exists(root, "gradlew") then
    return "./gradlew", "gradle"
  end
  if exists(root, "mvnw") then
    return "./mvnw", "maven"
  end
  for _, f in ipairs({ "build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle" }) do
    if exists(root, f) and vim.fn.executable("gradle") == 1 then
      return "gradle", "gradle"
    end
  end
  if exists(root, "pom.xml") and vim.fn.executable("mvn") == 1 then
    return "mvn", "maven"
  end
end

local function gradle(root)
  local cmd, tool = M.build_tool(root)
  if not cmd then
    return {}
  end
  local function task(name, tasks, kind)
    return { name = name, type = "gradle", tasks = tasks, kind = kind, detected = true }
  end
  if tool == "maven" then
    return {
      task("mvn test", "test", "test"),
      task("mvn package", "package", "build"),
    }
  end
  -- `run` exists only with the `application` plugin; Spring Boot apps are
  -- their own configurations.
  local build = (read(root .. "/build.gradle.kts") or read(root .. "/build.gradle") or "")
  local has_run = ("\n" .. build):match("\n%s*application%s*\n") ~= nil -- plugins { application }
    or build:match("id%s*%(?%s*[\"']application[\"']") ~= nil -- id("application")
  local out = {}
  if has_run then
    out[#out + 1] = task("gradle run", "run", "run")
  end
  vim.list_extend(out, {
    task("gradle test", "test", "test"),
    task("gradle build", "build", "build"),
  })
  return out
end

--- A Spring Boot configuration per application in the project: run and
--- debugged through the IntelliJ server.
local function spring_boot(root)
  local apps = require("aedi.spring").apps(root)
  local out = {}
  for _, dir in ipairs(apps) do
    local name = dir == "" and vim.fs.basename(root) or vim.fs.basename(dir)
    out[#out + 1] = {
      name = name,
      type = "spring-boot",
      module = dir ~= "" and dir or nil,
      kind = "run",
      detected = true,
    }
  end
  return out
end

--- An Application configuration per main class that is not a Spring Boot
--- application's (those have their own).
local function applications(root)
  local out = {}
  for _, m in ipairs(require("aedi.jvm").mains(root)) do
    if not m.spring then
      out[#out + 1] = {
        name = (m.class:match("[^.]+$") or m.class):gsub("Kt$", ""),
        type = "application",
        main = m.class,
        kind = "run",
        detected = true,
      }
    end
  end
  return out
end

--- Does `dir` hold a `package main`?
local function main_package(dir)
  for name, type in vim.fs.dir(dir) do
    if type == "file" and name:match("%.go$") and not name:match("_test%.go$") then
      local head = read(dir .. "/" .. name) or ""
      if head:match("^%s*package%s+main%f[%W]") or head:match("\n%s*package%s+main%f[%W]") then
        return true
      end
    end
  end
  return false
end

local function go(root)
  if not exists(root, "go.mod") then
    return {}
  end
  local out = {}
  if main_package(root) then
    out[#out + 1] = cfg("go run .", "go run .", "run")
  end
  if vim.uv.fs_stat(root .. "/cmd") then
    for name, type in vim.fs.dir(root .. "/cmd") do
      if type == "directory" and main_package(root .. "/cmd/" .. name) then
        out[#out + 1] = cfg("go run ./cmd/" .. name, "go run ./cmd/" .. name, "run")
      end
    end
  end
  vim.list_extend(out, {
    cfg("go test ./...", "go test ./...", "test"),
    cfg("go build ./...", "go build ./...", "build"),
  })
  return out
end

local function cargo(root)
  if not exists(root, "Cargo.toml") then
    return {}
  end
  return {
    cfg("cargo run", "cargo run", "run"),
    cfg("cargo test", "cargo test", "test"),
    cfg("cargo build", "cargo build", "build"),
  }
end

local function node(root)
  local pkg = read(root .. "/package.json")
  if not pkg then
    return {}
  end
  local ok, json = pcall(vim.json.decode, pkg)
  if not ok or type(json) ~= "table" or type(json.scripts) ~= "table" then
    return {}
  end
  local pm = "npm"
  for lock, name in pairs({ ["pnpm-lock.yaml"] = "pnpm", ["yarn.lock"] = "yarn", ["bun.lockb"] = "bun", ["bun.lock"] = "bun" }) do
    if exists(root, lock) then
      pm = name
    end
  end
  local names = vim.tbl_keys(json.scripts)
  table.sort(names)
  local out = {}
  for _, s in ipairs(names) do
    local kind = (s == "test" and "test") or (s == "build" and "build") or ((s == "start" or s == "dev") and "run") or nil
    out[#out + 1] = cfg(pm .. " run " .. s, pm .. " run " .. s, kind)
  end
  return out
end

local function make(root)
  local text = read(root .. "/Makefile") or read(root .. "/makefile")
  if not text then
    return {}
  end
  local out, seen = {}, {}
  for line in text:gmatch("[^\n]+") do
    local target = line:match("^([%w][%w_%-/]*)%s*:[^=]")
      or line:match("^([%w][%w_%-/]*)%s*:$")
    if target and not seen[target] then
      seen[target] = true
      local kind = (target == "test" and "test") or (target == "build" and "build") or (target == "run" and "run") or nil
      out[#out + 1] = cfg("make " .. target, "make " .. target, kind)
    end
  end
  return out
end

--- A Godot project: its main scene, and the scene of the file you are in.
local function godot(root)
  if not require("aedi.godot").project(root) then
    return {}
  end
  return {
    { name = "Main scene", type = "godot", kind = "run", detected = true },
    { name = "Current scene", type = "godot", scene = "current", kind = "run", detected = true },
  }
end

M.builtin = { spring_boot, applications, gradle, godot, go, cargo, node, make }

--- Everything the detectors find in `root`.
---@param root string
---@return aedi.Configuration[]
function M.all(root)
  local detectors = vim.list_extend(vim.list_slice(M.builtin), require("aedi.config").options.detectors or {})
  local out, seen = {}, {}
  for _, d in ipairs(detectors) do
    local ok, found = pcall(d, root)
    if ok and type(found) == "table" then
      for _, c in ipairs(found) do
        if not seen[c.name] then
          seen[c.name] = true
          c.detected = true
          out[#out + 1] = c
        end
      end
    end
  end
  return out
end

return M
