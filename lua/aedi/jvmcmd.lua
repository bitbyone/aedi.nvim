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

--- The mark (`-Daedi.launch=…`) a launch's JVM carries, if any.
---@param vm_args? string[]
---@return string?
function M.mark_of(vm_args)
  for _, a in ipairs(vm_args or {}) do
    local m = a:match("^%-Daedi%.launch=(.+)$")
    if m then
      return m
    end
  end
end

--- Does `cmd` carry `mark`?
function M.carries(cmd, mark)
  for word in cmd:gmatch("%S+") do
    if word == "-Daedi.launch=" .. mark then
      return true
    end
  end
  return false
end

--- Watch for the launch's JVM, up to `timeout` ms (it starts after the
--- build): by its mark when it has one -- certain -- else the first new
--- process (not among `before`) running `main`. `found` gets the command line
--- and whether it was matched by the mark. `stop()` gives up early.
---@param want { mark?: string, main: string, before?: table<integer, string> }
---@param found fun(cmd: string, by_mark: boolean)
---@param timeout? integer
---@return fun() stop
function M.watch(want, found, timeout)
  local timer = vim.uv.new_timer()
  local started = vim.uv.now()
  local function stop()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  timer:start(200, 250, vim.schedule_wrap(function()
    if vim.uv.now() - started > (timeout or 180000) then
      return stop()
    end
    for pid, cmd in pairs(M.processes()) do
      if want.mark then
        if M.carries(cmd, want.mark) and M.runs(cmd, want.main) then
          stop()
          return found(cmd, true)
        end
      elseif not (want.before or {})[pid] and M.runs(cmd, want.main) then
        stop()
        return found(cmd, false)
      end
    end
  end))
  return stop
end

--- A JVM command line in parts: java, VM options, classpath, main, args.
---@param cmd string
---@param main string
---@return { java: string, vm: string[], classpath: string[], main: string, args: string[] }
function M.parse(cmd, main)
  local words = vim.split(cmd, " ", { plain = true, trimempty = true })
  local out = { java = words[1], vm = {}, classpath = {}, main = main, args = {} }
  local i, past_main = 2, false
  while i <= #words do
    local w = words[i]
    if past_main then
      out.args[#out.args + 1] = w
    elseif w == main then
      past_main = true
    elseif (w == "-cp" or w == "-classpath" or w == "--class-path") and words[i + 1] then
      out.classpath = vim.split(words[i + 1], ":", { plain = true, trimempty = true })
      i = i + 1
    elseif not w:match("^%-Daedi%.launch=") then
      out.vm[#out.vm + 1] = w
    end
    i = i + 1
  end
  return out
end

return M
