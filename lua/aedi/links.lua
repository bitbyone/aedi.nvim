-- `<CR>` on a line of run output: the place it names.
--
--   at com.x.Foo.bar(Foo.kt:42)          a JVM stack frame
--   ./main.go:12:5: undefined: x         path:line[:col], any tool
--   --> src/main.rs:3:5                  (the same, after rustc's arrow)
--   File "app.py", line 3, in main       Python
--
-- A path is tried against the run's working directory, then the project
-- root. A stack frame is looked up in the project by package path and file
-- name, then through the language server (`workspace/symbol`), which is how
-- a frame inside a library lands in its sources.

local M = {}

---@class aedi.Location
---@field file? string
---@field line integer
---@field col? integer
---@field frame? { package: string, class: string, file: string }

--- Every place `line` may point at, the one under `col` (1-based) first.
---@param line string
---@param col? integer
---@return aedi.Location[]
function M.candidates(line, col)
  local out = {}
  -- JVM frame: `at [module/]pkg.Cls[$Inner].method(File.kt:42)`.
  for qualified, file, lnum in line:gmatch("at%s+([%w_$%./]+)%(([%w_$%-]+%.%w+):(%d+)%)") do
    qualified = qualified:gsub("^.*/", "")
    local parts = vim.split(qualified, ".", { plain = true })
    -- drop the method, then the class
    table.remove(parts)
    local class = (table.remove(parts) or ""):gsub("%$.*$", "")
    out[#out + 1] = {
      line = tonumber(lnum),
      frame = { package = table.concat(parts, "."), class = class, file = file },
    }
  end
  if #out > 0 then
    return out
  end
  for py_file, py_line in line:gmatch('File "(.-)", line (%d+)') do
    out[#out + 1] = { file = py_file, line = tonumber(py_line) }
  end
  if #out > 0 then
    return out
  end
  -- path:line[:col]
  local init = 1
  while true do
    local s, e, path, l, c = line:find("([%w%._%-/~][%w%._%-/~]*%.%a%w*):(%d+):?(%d*)", init)
    if not s then
      break
    end
    local loc = { file = path, line = tonumber(l), col = tonumber(c) }
    if col and col >= s and col <= e then
      table.insert(out, 1, loc)
    else
      out[#out + 1] = loc
    end
    init = e + 1
  end
  return out
end

--- What `line` points at; with `col` (1-based), the match under it wins.
---@param line string
---@param col? integer
---@return aedi.Location?
function M.parse(line, col)
  return M.candidates(line, col)[1]
end

---@param file string
---@param dirs string[]
---@return string?
local function resolve_path(file, dirs)
  file = vim.fs.normalize(file)
  if file:sub(1, 1) == "/" then
    return vim.uv.fs_stat(file) and file or nil
  end
  for _, dir in ipairs(dirs) do
    local p = vim.fs.normalize(dir .. "/" .. file)
    if vim.uv.fs_stat(p) then
      return p
    end
  end
end

--- A frame's source in the project: `<package path>/<file>` anywhere under
--- `root`, respecting .gitignore when ripgrep is there.
---@return string?
local function find_frame_file(frame, root)
  local suffix = (frame.package ~= "" and frame.package:gsub("%.", "/") .. "/" or "") .. frame.file
  if vim.fn.executable("rg") == 1 then
    local res = vim.system({ "rg", "--files", "-g", "**/" .. suffix }, { cwd = root, text = true }):wait(5000)
    local first = res.code == 0 and vim.split(res.stdout, "\n", { trimempty = true })[1]
    if first then
      return vim.fs.normalize(root .. "/" .. first)
    end
    return nil
  end
  local hit = vim.fs.find(function(name, path)
    return name == frame.file and (path .. "/" .. name):sub(-#suffix) == suffix
  end, { path = root, type = "file", limit = 1 })[1]
  return hit
end

--- A frame's class through any language server that answers
--- `workspace/symbol`: a library class opens in whatever the server hands
--- out for it (its sources, when it has them).
---@return lsp.Location?, vim.lsp.Client?
local function lsp_frame(frame)
  for _, client in ipairs(vim.lsp.get_clients()) do
    if client:supports_method("workspace/symbol") then
      local bufnr = next(client.attached_buffers)
      local res = client:request_sync("workspace/symbol", { query = frame.class }, 5000, bufnr)
      for _, sym in ipairs(res and res.result or {}) do
        local container = sym.containerName or ""
        if sym.name == frame.class and (frame.package == "" or container == frame.package or container:sub(-#frame.package) == frame.package) then
          local loc = sym.location
          if loc and loc.uri then
            return loc, client
          end
        end
      end
    end
  end
end

--- Open what `loc` names in `win`.
---@param loc aedi.Location
---@param dirs string[] where a relative path is looked for, in order
---@param win integer
---@return boolean found
function M.open(loc, dirs, win)
  local function place(w)
    local buf = vim.api.nvim_win_get_buf(w)
    local last = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, w, { math.min(loc.line, last), math.max((loc.col or 1) - 1, 0) })
    vim.api.nvim_win_call(w, function()
      vim.cmd("normal! zz")
    end)
  end
  local path
  if loc.frame then
    path = find_frame_file(loc.frame, dirs[#dirs])
  elseif loc.file then
    path = resolve_path(loc.file, dirs)
  end
  if path then
    vim.api.nvim_set_current_win(win)
    vim.cmd.edit(vim.fn.fnameescape(path))
    place(win)
    return true
  end
  if loc.frame then
    local l, client = lsp_frame(loc.frame)
    if l and client then
      vim.api.nvim_set_current_win(win)
      vim.lsp.util.show_document(l, client.offset_encoding, { focus = true })
      place(vim.api.nvim_get_current_win())
      return true
    end
  end
  return false
end

return M
