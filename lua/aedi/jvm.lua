-- JVM entry points in a project, and launching one through intellij-lsp.nvim
-- (the IntelliJ language server's debug adapter): its Run and Debug are one
-- launch, with or without the debugger, the same as its Run / Debug lenses.

local M = {}

local function read_head(path, n)
  local f = io.open(path, "r")
  if not f then
    return ""
  end
  local s = f:read(n or 8192) or ""
  f:close()
  return s
end

--- The package a source file declares.
local function package_of(text)
  for line in text:gmatch("[^\n]+") do
    local p = line:match("^%s*package%s+([%w_%.]+)")
    if p then
      return p
    end
  end
end

---@class aedi.Main
---@field class string fully qualified, as the JVM names it (`pkg.FileKt` for a top-level Kotlin main)
---@field file string absolute path of the source
---@field module string the directory (relative to the root) whose `src/main` holds it; "" for the root
---@field spring boolean the file is a `@SpringBootApplication`

--- The main classes under `src/main` of `root` and its modules. Needs ripgrep.
---@param root string
---@return aedi.Main[]
function M.mains(root)
  if vim.fn.executable("rg") ~= 1 then
    return {}
  end
  local res = vim.system({
    "rg", "-l", "--no-messages", "-g", "*.kt", "-g", "*.java", "-g", "!**/build/**", "-g", "!**/test/**",
    "-e", "^fun main\\(", "-e", "^suspend fun main\\(", "-e", "static\\s+(public\\s+)?void\\s+main\\s*\\(",
    ".",
  }, { cwd = root, text = true }):wait(10000)
  local out = {}
  for _, rel in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    rel = rel:gsub("^%./", "")
    local module = rel:match("^(.-)/?src/main/")
    if module then
      local path = root .. "/" .. rel
      local text = read_head(path, 65536)
      local pkg = package_of(text)
      local base = vim.fn.fnamemodify(rel, ":t:r")
      local class
      if rel:match("%.kt$") then
        local jvm_name = text:match('@file:JvmName%(%s*"([^"]+)"')
        class = jvm_name or (base:sub(1, 1):upper() .. base:sub(2) .. "Kt")
      else
        class = base
      end
      out[#out + 1] = {
        class = (pkg and (pkg .. ".") or "") .. class,
        file = path,
        module = module,
        spring = text:find("@SpringBootApplication", 1, true) ~= nil,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.class < b.class
  end)
  return out
end

--- The main class of the Spring Boot application in `module`.
---@param root string
---@param module? string
---@return aedi.Main?
function M.spring_main(root, module)
  module = module or ""
  local fallback
  for _, m in ipairs(M.mains(root)) do
    if m.module == module then
      if m.spring then
        return m
      end
      fallback = fallback or m
    end
  end
  return fallback
end

--- The main class `class` in `root`.
---@return aedi.Main?
function M.find(root, class)
  for _, m in ipairs(M.mains(root)) do
    if m.class == class then
      return m
    end
  end
end

--- Is the IntelliJ server up? (Asking `require` would load the plugin, and
--- loading it starts the server.)
---@param file? string
---@return vim.lsp.Client?
function M.client(file)
  if not package.loaded["intellij-lsp"] then
    return nil
  end
  local ok, client = pcall(require, "intellij-lsp.client")
  if not ok then
    return nil
  end
  local okc, c = pcall(client.find_ancestor_client, file or vim.uv.cwd())
  if okc and c then
    return c
  end
  return vim.lsp.get_clients({ name = require("intellij-lsp.client").NAME })[1]
end

--- Launch through the IntelliJ server: built by the project's build tool,
--- run (or debugged) as IntelliJ's Application configuration would.
---@param spec { name: string, mainClass: string, file: string, args?: string[], vmArgs?: string[], env?: table<string,string>, cwd?: string }
---@param debug boolean
---@return boolean started
function M.launch(spec, debug)
  local client = M.client(spec.file)
  if not client then
    vim.notify("The IntelliJ server is not running (:Lsp starts it)", vim.log.levels.WARN)
    return false
  end
  local config = {
    name = spec.name,
    mainClass = spec.mainClass,
    file = spec.file,
    args = spec.args and #spec.args > 0 and spec.args or nil,
    vmArgs = spec.vmArgs and #spec.vmArgs > 0 and spec.vmArgs or nil,
    env = spec.env and next(spec.env) and spec.env or nil,
    cwd = spec.cwd,
    noDebug = not debug,
    -- A debug launch runs the plain JVM (the build tool still builds first):
    -- intellij-lsp does the same for its Debug lens.
    tool = debug and "java" or nil,
    aedi = true,
  }
  require("intellij-lsp.run")._dap_run(client, config)
  return true
end

return M
