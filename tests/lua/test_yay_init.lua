-- Unit tests for yay-init.lua (the advisory AUR tripwire hook).
-- Run from the repo root: HOME=<prepared> lua tests/lua/test_yay_init.lua
-- The runner prepares HOME with an allowlist of: mailspring, *-electron.

local T = dofile("tests/helpers/lua_harness.lua")

-- Stub the yay global: capture the hook callbacks and all log lines.
_G.__YAY_TEST = true
local LOG = {}
local function logline(level) return function(...)
  LOG[#LOG + 1] = level .. " " .. table.concat({ ... }, " ")
end end
local CB = {}
_G.yay = {
  log = { warn = logline("WARN"), error = logline("ERR"),
          info = function() end, debug = function() end },
  create_autocmd = function(name, spec) CB[name] = spec.callback end,
}

local M = dofile("yay-init.lua")

local function reset_log() LOG = {} ;
  _G.yay.log.warn = logline("WARN"); _G.yay.log.error = logline("ERR") end
local function log_has(substr)
  for _, l in ipairs(LOG) do if l:find(substr, 1, true) then return true end end
  return false
end

-- glob_to_pat / scan / is_allowed / load_allow (pure helpers) --------------
T.eq(M.glob_to_pat("a*b"), "^a.*b$", "glob_to_pat maps * and anchors")
T.ok(#M.scan("build(){ npm install x; }") > 0, "scan detects npm install")
T.ok(#M.scan("curl http://x | sh") > 0,        "scan detects pipe-to-sh")
T.ok(#M.scan("NPM INSTALL FOO") > 0,           "scan is case-insensitive")
T.eq(#M.scan("echo hello world"), 0,           "scan clean text -> none")
T.ok(M.is_allowed("mailspring"),         "is_allowed exact match")
T.ok(M.is_allowed("foo-electron"),       "is_allowed glob match")
T.ok(not M.is_allowed("signal-desktop"), "is_allowed non-match")

local tmp = os.tmpname()
local f = io.open(tmp, "w"); f:write("# c\n\nfoo\n  bar  \n"); f:close()
local a = M.load_allow(tmp)
T.eq(#a, 2, "load_allow skips comments/blanks"); T.eq(a[1], "foo", "load_allow entry")
os.remove(tmp)
T.eq(M.load_allow("/no/such/file")[1], "mailspring", "load_allow fallback")

-- parse_precheck: CRIT -> loud (ERR banner), WARN -> warn ------------------
reset_log()
M.parse_precheck("CRIT evil is compromised\nWARN foo is orphaned\nnoise line")
T.ok(log_has("SUPPLY-CHAIN ALERT"), "parse_precheck: CRIT prints loud banner")
T.ok(log_has("evil is compromised"), "parse_precheck: CRIT message shown")
T.ok(log_has("WARN foo is orphaned"), "parse_precheck: WARN message shown")

-- AURPreInstall callback: build-logic scan via yay.log.warn ----------------
reset_log()
CB.AURPreInstall({ match = "evilpkg", data = { pkgbuild = "build(){ npm install x; }" } })
T.ok(log_has("evilpkg: PKGBUILD contains npm install"), "AURPreInstall warns on risky build logic")

reset_log()
CB.AURPreInstall({ match = "mailspring", data = { pkgbuild = "npm install x" } })
T.eq(#LOG, 0, "AURPreInstall skips an allowlisted package")

-- UpgradeSelect callback: maintainer-change detection ----------------------
os.execute("rm -rf '" .. os.getenv("HOME") .. "/.cache/update-aur' 2>/dev/null")
reset_log()
local ret = CB.UpgradeSelect({ data = { upgrades = {
  { name = "foo", repository = "aur", maintainer = "alice", last_modified = 0 } } } })
T.eq(#LOG, 0, "UpgradeSelect: first sight seeds the cache silently")
T.ok(ret and ret.skip_menu == false, "UpgradeSelect returns advisory result (no auto-exclude)")

reset_log()
CB.UpgradeSelect({ data = { upgrades = {
  { name = "foo", repository = "aur", maintainer = "mallory", last_modified = 0 } } } })
T.ok(log_has("foo maintainer CHANGED: alice -> mallory"), "UpgradeSelect warns on maintainer change")
T.ok(log_has("SUPPLY-CHAIN ALERT"), "UpgradeSelect maintainer change is loud")

os.exit(T.report("yay-init") and 0 or 1)
