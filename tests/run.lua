-- nvim -l tests/run.lua    (from the repository root)
vim.opt.rtp:prepend(vim.fn.getcwd())
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("aedi").setup({ store = tmp .. "/configurations.json", debug = { enabled = false } })

local failed, passed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(("FAIL %s\n  %s\n"):format(name, err))
  end
end
local function eq(a, b, what)
  if not vim.deep_equal(a, b) then
    error(("%s: expected %s, got %s"):format(what or "value", vim.inspect(b), vim.inspect(a)), 2)
  end
end
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local editor = require("aedi.editor")
test("editor round trip", function()
  local c = { name = "App", command = "go run .", args = "--port 1", cwd = "svc", env = { B = "2", A = "x=1" } }
  eq(editor.parse(editor.render(c)), c)
end)
test("editor defaults drop empty fields", function()
  eq(editor.parse({ "name: x", "command: make", "args:", "cwd: .", "env:" }), { name = "x", command = "make" })
end)
test("editor errors", function()
  local _, err = editor.parse({ "command: make" })
  eq(err, "name is empty")
  _, err = editor.parse({ "name: x", "command: y", "colour: red" })
  assert(err:find("unknown field"), err)
  _, err = editor.parse({ "name: x", "command: y", "env: nope" })
  assert(err:find("KEY=value"), err)
end)

local links = require("aedi.links")
test("links: JVM frame", function()
  eq(links.parse("\tat com.x.service.Foo$Inner.bar(Foo.kt:42)"), {
    line = 42,
    frame = { package = "com.x.service", class = "Foo", file = "Foo.kt" },
  })
  eq(links.parse("at java.base/java.lang.Thread.run(Thread.java:1583)").frame.package, "java.lang")
end)
test("links: path:line:col and the one under the cursor", function()
  eq(links.parse("./main.go:12:5: undefined: x"), { file = "./main.go", line = 12, col = 5 })
  local line = "a.go:1 and b.go:2"
  eq(links.parse(line, 14).file, "b.go")
  eq(links.parse("  --> src/main.rs:3:5").file, "src/main.rs")
  eq(links.parse('  File "app.py", line 3, in main'), { file = "app.py", line = 3 })
  eq(links.parse("version 1.2:3 nothing"), nil)
end)

local detect = require("aedi.detect")
local function names(list)
  return vim.tbl_map(function(c)
    return c.name
  end, list)
end
test("detect: go", function()
  local root = tmp .. "/go"
  write(root .. "/go.mod", "module x\n")
  write(root .. "/main.go", "package main\nfunc main() {}\n")
  write(root .. "/cmd/srv/main.go", "// x\npackage main\n")
  write(root .. "/cmd/lib/lib.go", "package lib\n")
  eq(names(detect.all(root)), { "go run .", "go run ./cmd/srv", "go test ./...", "go build ./..." })
end)
test("detect: gradle with spring boot, npm, make", function()
  local root = tmp .. "/jvm"
  write(root .. "/gradlew", "")
  write(root .. "/build.gradle.kts", 'plugins { id("org.springframework.boot") }')
  write(root .. "/package.json", '{"scripts":{"test":"vitest","dev":"vite"}}')
  write(root .. "/pnpm-lock.yaml", "")
  write(root .. "/Makefile", "VAR := 1\n.PHONY: all\nall: build\nbuild:\n\tgo build\n")
  local found = detect.all(root)
  eq(vim.list_slice(names(found), 1, 4), { "gradle bootRun", "gradle run", "gradle test", "gradle build" })
  assert(vim.tbl_contains(names(found), "pnpm run dev"))
  assert(vim.tbl_contains(names(found), "make all"))
  assert(vim.tbl_contains(names(found), "make build"))
  assert(not vim.tbl_contains(names(found), "make VAR"))
  eq(found[1].command, "./gradlew bootRun")
end)

local store = require("aedi.store")
test("store: put, rename, last, delete", function()
  local root = "/proj"
  store.put({ name = "A", command = "a" }, nil, root)
  store.put({ name = "B", command = "b", cwd = "." }, nil, root)
  eq(store.get("B", root), { name = "B", command = "b" })
  store.set_last({ name = "A", command = "a" }, root)
  store.put({ name = "A2", command = "a2" }, "A", root)
  eq(store.last(root), { name = "A2", command = "a2" })
  local ok = pcall(store.put, { name = "B", command = "x" }, "A2", root)
  eq(ok, false, "rename onto an existing name")
  store.reload()
  eq(names(store.list(root)), { "A2", "B" }, "persisted")
  store.delete("A2", root)
  eq(names(store.list(root)), { "B" })
  eq(store.last(root), nil)
end)

local console = require("aedi.console")
test("console: run, exit code, rerun in the same tab", function()
  local dir = tmp .. "/run"
  vim.fn.mkdir(dir, "p")
  local c = { name = "t", command = "printf '%s' \"$X\"; exit 3", cwd = dir, env = { X = "hello" } }
  local run = assert(console.start(c))
  assert(vim.wait(5000, function()
    return run.code ~= nil
  end), "did not exit")
  eq(run.code, 3)
  local text = table.concat(vim.api.nvim_buf_get_lines(run.buf, 0, -1, false), "\n")
  assert(text:find("hello", 1, true), text)
  local again = assert(console.start(c))
  eq(#console.runs, 1, "one tab per configuration")
  vim.wait(5000, function()
    return again.code ~= nil
  end)
  eq(vim.api.nvim_buf_is_valid(run.buf), false, "old output buffer is gone")
  console.close()
  eq(#console.runs, 0)
  eq(console.visible(), true, "closing the last tab leaves the panel up, empty")
  console.hide()
  console.show()
  eq(console.visible(), true, "the panel opens with nothing run")
  console.hide()
end)

vim.fn.delete(tmp, "rf")
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
