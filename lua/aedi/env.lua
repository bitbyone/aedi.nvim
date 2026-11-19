-- The project's own environment: what mise (mise.jdx.dev) sets in it.
--
-- A project with a mise config (`mise.toml`, `.mise.toml`, `.tool-versions`,
-- ...) pins its tools there -- `java = "temurin-21"`. A shell with mise
-- activated picks that up on `cd`; Neovim started elsewhere, or one that
-- changed directory since, would not. So aedi asks mise itself -- `mise env
-- --json` in the project root -- and runs with that: the background Gradle
-- index, and Gradle and shell configurations in the Run panel (their own
-- `env` still wins). IntelliJ launches use the JDK the IntelliJ server chose.
--
-- Nothing happens without mise on PATH or a config for the project; off with
-- `setup({ mise = false })`. Kept per project until a config file changes.

local M = {}

local CONFIGS = {
  "mise.toml",
  ".mise.toml",
  "mise.local.toml",
  ".mise.local.toml",
  ".config/mise.toml",
  ".config/mise/config.toml",
  "mise/config.toml",
  ".tool-versions",
}

---@type table<string, { key: string, env: table<string, string>? }>
local cache = {}
local warned = {}

--- The mise config files that apply to `root`: in it and above it.
---@param root string
---@return string[]
function M.configs(root)
  local found = {}
  local dir = root
  while dir do
    for _, name in ipairs(CONFIGS) do
      local path = dir .. "/" .. name
      if vim.uv.fs_stat(path) then
        found[#found + 1] = path
      end
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return found
end

--- Environment variables mise sets for `root`; nil without mise or a config.
---@param root string
---@return table<string, string>?
function M.project(root)
  if require("aedi.config").options.mise == false or vim.fn.executable("mise") ~= 1 then
    return nil
  end
  local configs = M.configs(root)
  if #configs == 0 then
    return nil
  end
  local key = {}
  for _, path in ipairs(configs) do
    local st = vim.uv.fs_stat(path)
    key[#key + 1] = path .. ":" .. (st and st.mtime.sec or 0) .. ":" .. (st and st.size or 0)
  end
  key = table.concat(key, "|")
  local hit = cache[root]
  if hit and hit.key == key then
    return hit.env
  end
  local res = vim.system({ "mise", "env", "--json" }, { cwd = root, text = true }):wait(15000)
  local env
  if res.code == 0 then
    local ok, decoded = pcall(vim.json.decode, res.stdout or "")
    env = ok and type(decoded) == "table" and decoded or nil
  elseif not warned[root] then
    warned[root] = true
    local err = vim.trim(res.stderr or "")
    if err:find("trust") then
      err = err .. "\n(`mise trust` in " .. root .. ")"
    end
    vim.notify("mise env failed, running without it: " .. err, vim.log.levels.WARN)
  end
  cache[root] = { key = key, env = env }
  return env
end

--- `extra` over the project's mise environment.
---@param root string
---@param extra? table<string, string>
---@return table<string, string>?
function M.merge(root, extra)
  local base = M.project(root)
  if not base then
    return extra
  end
  return vim.tbl_extend("force", vim.deepcopy(base), extra or {})
end

--- Forget what mise said (tests).
function M.reset()
  cache, warned = {}, {}
end

return M
