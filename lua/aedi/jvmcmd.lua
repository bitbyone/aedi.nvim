-- The command line a launched JVM actually runs with, as IntelliJ prints it
-- at the top of a run: which `java` (so which JDK), every VM option, the main
-- class and its arguments.
--
-- A launch through the IntelliJ server does not say: the server starts the
-- JVM itself (through Gradle's `ideRun`, or a plain `java` for a debug).
-- So it is looked up where it is: the `java` process that runs the main
-- class and was not there before the launch, found in `ps`. The classpath is
-- shortened to its number of entries.

local M = {}

--- `pid -> command` of the running processes.
---@return table<integer, string>
function M.processes()
  local res = vim.system({ "ps", "-axww", "-o", "pid=,command=" }, { text = true }):wait(5000)
  local out = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local pid, cmd = line:match("^%s*(%d+)%s+(.*)$")
    if pid then
      out[tonumber(pid)] = cmd
    end
  end
  return out
end

--- Is `cmd` a JVM running `main`?
---@param cmd string
---@param main string
function M.runs(cmd, main)
  local exe = cmd:match("^(%S+)")
  if not exe or not exe:match("/java$") and exe ~= "java" then
    return false
  end
  for word in cmd:gmatch("%S+") do
    if word == main then
      return true
    end
  end
  return false
end

--- `cmd` with the classpath shortened: `-classpath <42 entries>`.
---@param cmd string
---@return string
function M.shorten(cmd)
  local words = vim.split(cmd, " ", { plain = true, trimempty = true })
  for i, w in ipairs(words) do
    if (w == "-cp" or w == "-classpath" or w == "--class-path" or w == "-p" or w == "--module-path") and words[i + 1] then
      local n = select(2, words[i + 1]:gsub(":", "")) + 1
      words[i + 1] = ("<%d entr%s>"):format(n, n == 1 and "y" or "ies")
    end
  end
  return table.concat(words, " ")
end

--- Watch for a new JVM running `main` (one not among `before`), up to
--- `timeout` ms: a launch builds first, which takes a while. `found` gets its
--- command line; `stop()` gives up early.
---@param main string
---@param before table<integer, string>
---@param found fun(cmd: string, pid: integer)
---@param timeout? integer
---@return fun() stop
function M.watch(main, before, found, timeout)
  local timer = vim.uv.new_timer()
  local started = vim.uv.now()
  local function stop()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  timer:start(200, 200, vim.schedule_wrap(function()
    if vim.uv.now() - started > (timeout or 180000) then
      return stop()
    end
    for pid, cmd in pairs(M.processes()) do
      if not before[pid] and M.runs(cmd, main) then
        stop()
        found(cmd, pid)
        return
      end
    end
  end))
  return stop
end

return M
