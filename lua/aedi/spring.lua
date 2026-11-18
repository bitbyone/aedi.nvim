-- Spring Boot in a project: its applications, and the profiles each can run
-- with.

local M = {}

local MARKERS = { "org.springframework.boot", "spring.boot", "springBoot", "spring-boot" }

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function boot_build(dir)
  for _, f in ipairs({ "build.gradle.kts", "build.gradle", "pom.xml" }) do
    local text = read(dir .. "/" .. f)
    if text then
      for _, m in ipairs(MARKERS) do
        if text:find(m, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

--- The project's Spring Boot applications, as directories relative to
--- `root` ("" for the root itself): where a `@SpringBootApplication` lives
--- under `src/main`. Without ripgrep, the build files that apply the Boot
--- plugin.
---@param root string
---@return string[]
function M.apps(root)
  local dirs, seen = {}, {}
  local function add(d)
    if not seen[d] then
      seen[d] = true
      dirs[#dirs + 1] = d
    end
  end
  if vim.fn.executable("rg") == 1 then
    local res = vim.system({
      "rg", "-l", "--no-messages", "-g", "*.kt", "-g", "*.java", "-g", "!**/build/**", "-g", "!**/test/**",
      "@SpringBootApplication", ".",
    }, { cwd = root, text = true }):wait(10000)
    for _, path in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
      path = path:gsub("^%./", "")
      local dir = path:match("^(.-)/?src/main/")
      if dir then
        add(dir)
      end
    end
  else
    if boot_build(root) then
      add("")
    end
    for name, type in vim.fs.dir(root) do
      if type == "directory" and not name:match("^%.") and boot_build(root .. "/" .. name) then
        add(name)
      end
    end
  end
  table.sort(dirs)
  return dirs
end

--- Profiles an application can run with: `application-<profile>.yml` /
--- `.yaml` / `.properties` in its resources, and `on-profile:` documents in
--- its `application.yml`.
---@param root string
---@param dir? string the application, relative to `root`
---@return string[]
function M.profiles(root, dir)
  local base = root .. ((dir and dir ~= "") and ("/" .. dir) or "")
  local out, seen = {}, {}
  local function add(p)
    p = vim.trim(p)
    if p ~= "" and p ~= "default" and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  for _, res in ipairs({ base .. "/src/main/resources", base .. "/src/main/resources/config", base .. "/config" }) do
    if vim.uv.fs_stat(res) then
      for name, type in vim.fs.dir(res) do
        if type == "file" then
          local p = name:match("^application%-(.+)%.ya?ml$") or name:match("^application%-(.+)%.properties$")
          if p then
            add(p)
          end
          if name:match("^application%.ya?ml$") then
            for line in (read(res .. "/" .. name) or ""):gmatch("[^\n]+") do
              local v = line:match("on%-profile:%s*['\"]?([^'\"#]+)")
              if v then
                for x in v:gmatch("[^,%s!&|()]+") do
                  add(x)
                end
              end
            end
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- "a, b ,c" -> "a,b,c"
---@param s? string
---@return string
function M.normalize(s)
  local parts = {}
  for p in (s or ""):gmatch("[^,%s]+") do
    parts[#parts + 1] = p
  end
  return table.concat(parts, ",")
end

return M
