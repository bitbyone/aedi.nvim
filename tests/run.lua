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

local types = require("aedi.types")
local editor = require("aedi.editor")
test("env as one line", function()
  local env = assert(types.parse_env([[A=1 B='x y' C="it's"  D=]]))
  eq(env, { A = "1", B = "x y", C = "it's", D = "" })
  eq(types.parse_env(types.format_env(env)), env)
  local _, err = types.parse_env("nope")
  assert(err:find("KEY=value"), err)
end)
test("form values round trip", function()
  local c = { name = "App", type = "spring-boot", profiles = "local,dev", args = "--x=1", env = { A = "b c" } }
  local state = { type = "spring-boot", apps = { "" }, values = editor.values_of(c) }
  eq(state.values.profiles, "local, dev")
  eq(editor.to_config(state), c)
  local _, err = editor.to_config({ type = "shell", apps = {}, values = editor.values_of({ name = "x" }) })
  eq(err, "the command is empty")
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
test("detect: no gradle run without the application plugin", function()
  local root = tmp .. "/norun"
  write(root .. "/gradlew", "")
  write(root .. "/build.gradle.kts", 'plugins { kotlin("jvm") }')
  eq(names(detect.all(root)), { "gradle test", "gradle build" })
end)
test("detect: go", function()
  local root = tmp .. "/go"
  write(root .. "/go.mod", "module x\n")
  write(root .. "/main.go", "package main\nfunc main() {}\n")
  write(root .. "/cmd/srv/main.go", "// x\npackage main\n")
  write(root .. "/cmd/lib/lib.go", "package lib\n")
  eq(names(detect.all(root)), { "go run .", "go run ./cmd/srv", "go test ./...", "go build ./..." })
end)
test("detect: gradle, npm, make", function()
  local root = tmp .. "/jvm"
  write(root .. "/gradlew", "")
  write(root .. "/build.gradle.kts", "plugins {\n    application\n}\n")
  write(root .. "/package.json", '{"scripts":{"test":"vitest","dev":"vite"}}')
  write(root .. "/pnpm-lock.yaml", "")
  write(root .. "/Makefile", "VAR := 1\n.PHONY: all\nall: build\nbuild:\n\tgo build\n")
  local found = detect.all(root)
  eq(vim.list_slice(names(found), 1, 3), { "gradle run", "gradle test", "gradle build" })
  assert(vim.tbl_contains(names(found), "pnpm run dev"))
  assert(vim.tbl_contains(names(found), "make all"))
  assert(vim.tbl_contains(names(found), "make build"))
  assert(not vim.tbl_contains(names(found), "make VAR"))
  eq({ found[1].type, found[1].tasks }, { "gradle", "run" })
end)

test("build: spring boot on gradle and maven, shell, gradle", function()
  local g = tmp .. "/sb-gradle"
  write(g .. "/gradlew", "")
  local l = assert(types.build({ name = "a", type = "spring-boot", profiles = "local, dev", args = "--server.port=1" }, g))
  eq(l.cmd, "./gradlew bootRun --args='--spring.profiles.active=local,dev --server.port=1'")
  eq(l.cwd, g)
  eq(types.build({ name = "a", type = "spring-boot", module = "svc/api" }, g).cmd, "./gradlew :svc:api:bootRun")
  local m = tmp .. "/sb-maven"
  write(m .. "/mvnw", "")
  eq(
    types.build({ name = "a", type = "spring-boot", profiles = "local", module = "api" }, m).cmd,
    "./mvnw spring-boot:run -pl api -Dspring-boot.run.profiles=local"
  )
  eq(types.build({ name = "t", type = "gradle", tasks = "test", args = "--info" }, g).cmd, "./gradlew test --info")
  local s = types.build({ name = "s", command = "go run .", args = "a", cwd = "sub" }, "/r")
  eq({ s.cmd, s.cwd }, { "go run . a", "/r/sub" })
  local _, err = types.build({ name = "x", type = "gradle", tasks = "test" }, tmp .. "/nothing")
  assert(err and err:find("no gradlew"), err)
end)
test("spring: apps and profiles", function()
  local root = tmp .. "/sb"
  write(root .. "/gradlew", "")
  write(root .. "/svc/src/main/kotlin/App.kt", "@SpringBootApplication\nclass App")
  write(root .. "/lib/src/test/kotlin/T.kt", "@SpringBootApplication\nclass T")
  write(root .. "/svc/src/main/resources/application.yml", "a: 1\n---\nspring.config.activate.on-profile: docker\n")
  write(root .. "/svc/src/main/resources/application-local.yml", "")
  write(root .. "/svc/src/main/resources/application-openapi.properties", "")
  local spring = require("aedi.spring")
  if vim.fn.executable("rg") == 1 then
    eq(spring.apps(root), { "svc" })
    local found = detect.all(root)
    eq({ found[1].name, found[1].type, found[1].module }, { "svc", "spring-boot", "svc" })
  end
  eq(spring.profiles(root, "svc"), { "docker", "local", "openapi" })
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

test("store: frecency", function()
  local root = "/frec"
  store.put({ name = "A", command = "a" }, nil, root)
  store.put({ name = "B", command = "b" }, nil, root)
  for _ = 1, 3 do
    store.set_last({ name = "B", command = "b" }, root)
  end
  store.set_last({ name = "A", command = "a" }, root)
  assert(store.score("B", root) > store.score("A", root))
  assert(store.score("A", root) > store.score("never", root))
  -- a month-old habit counts for less than today's
  local month = os.time() + 40 * 86400
  assert(store.score("B", root, month) < store.score("A", root))
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

test("console: an external tab", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local stopped = false
  local run = console.external({ key = "x", name = "Ext", buf = buf, stop = function()
    stopped = true
  end })
  eq(console.running(run), false, "idle until it runs")
  console.show_run(run)
  console.set_state(run, "running")
  eq(console.running(run), true)
  assert(vim.wo[console.win].winbar:find("●", 1, true))
  eq(console.stop(run), true)
  eq(stopped, true)
  console.set_state(run, "exited", 1)
  eq(run.code, 1)
  eq(console.external({ key = "x", name = "Ext2", buf = buf }), run, "one tab per key")
  console.close()
  eq(vim.api.nvim_buf_is_valid(buf), true, "closing the tab leaves the producer's buffer")
  console.hide()
end)

vim.fn.delete(tmp, "rf")
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
