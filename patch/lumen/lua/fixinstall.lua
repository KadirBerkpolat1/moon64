-- fixinstall.lua — install a user-downloaded fix archive into a Steam game
-- WITH a manifest, so Un-fix can revert it.
--
-- Why: fixes from outside lua.tools (FreeTP's setup .exe, an archive the user
-- downloaded) would otherwise be extracted by hand, which leaves NO record —
-- Un-fix then cannot know which files to remove, and the fix's own overwrite
-- of a game DLL is invisible. This module runs that same manual flow through
-- Lumen: list the archive, note which game files it overwrites, extract it
-- into the game folder, and record everything under
--   ~/.local/share/Lumen/fix_installs/<appid>/manifest.json
-- Un-fix then removes the added files. No backups are kept: the overwritten
-- game files are Steam's own, so Steam's "Verify integrity of game files"
-- restores them (revert reports needsVerify and the menu offers it).
--
-- Pure helpers are unit-tested (tools/test_fixinstall.lua); the install and
-- revert paths take injectable deps and never touch Millennium in tests.

local fixinstall = {}

fixinstall.MAX_ARCHIVES_LISTED = 12
-- Each probe is a synchronous innoextract run on the single-threaded RPC loop.
fixinstall.MAX_SETUPS_PROBED = 8
-- Extraction is synchronous too: a multi-GB repack would stall every RPC.
fixinstall.MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
-- online-fix.me encrypts its archives with this published password; 7-Zip
-- ignores it for archives that are not encrypted.
fixinstall.ARCHIVE_PASSWORD = "online-fix.me"

local json = require("json")

-- Single-quote a value for the shell ('' escaping), like the rest of Lumen.
local function shq(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- download_dir(home) -> where Lumen stores a fix it downloaded itself; install
-- deletes an archive from here once it is extracted.
function fixinstall.download_dir(home)
  return home .. "/.local/share/Lumen/freetp_dl"
end

function fixinstall.is_archive_name(name)
  if type(name) ~= "string" then return false end
  local low = name:lower()
  return low:match("%.zip$") ~= nil or low:match("%.rar$") ~= nil
    or low:match("%.7z$") ~= nil
end

-- Inno Setup installers are how fix sites commonly ship their payload
-- ("CRACK-Multiplayer-Fix-Online.exe" style). innoextract reads them.
function fixinstall.is_inno_name(name)
  return type(name) == "string" and name:lower():match("%.exe$") ~= nil
end

function fixinstall.installable_name(name)
  return fixinstall.is_archive_name(name) or fixinstall.is_inno_name(name)
end

-- filter_archives(entries) -> installable entries no larger than
-- MAX_ARCHIVE_BYTES, newest-first, deduped, capped. Each entry:
-- { name, path, size, mtime }.
function fixinstall.filter_archives(entries)
  local out, seen = {}, {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and fixinstall.installable_name(e.name)
        and (tonumber(e.size) or 0) <= fixinstall.MAX_ARCHIVE_BYTES
        and not seen[e.path or e.name] then
      seen[e.path or e.name] = true
      out[#out + 1] = {
        name = tostring(e.name),
        path = tostring(e.path or ""),
        size = tonumber(e.size) or 0,
        mtime = math.floor(tonumber(e.mtime) or 0),
      }
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.name < b.name
  end)
  while #out > fixinstall.MAX_ARCHIVES_LISTED do table.remove(out) end
  return out
end

-- parse_7z_listing(text) -> { { path, size } } from `7zz l -ba -slt` output.
-- Directory entries (Attributes containing D) are skipped; blocks are
-- separated by "Path = ..." lines. PURE.
function fixinstall.parse_7z_listing(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local path, size, is_dir
  local function flush()
    if path and not is_dir then
      out[#out + 1] = { path = path, size = tonumber(size) or 0 }
    end
    path, size, is_dir = nil, nil, nil
  end
  for line in text:gmatch("([^\r\n]*)\r?\n") do
    local k, v = line:match("^([%w_]+) = (.-)%s*$")
    if k == "Path" then
      flush(); path = v
    elseif k == "Size" and path then
      size = v
    elseif k == "Folder" and path and v:find("+", 1, true) then
      is_dir = true
    elseif k == "Attributes" and path then
      is_dir = v:find("D", 1, true) ~= nil
    end
  end
  flush()
  return out
end

-- safe_entries(entries) -> normalized list, or nil + reason when the archive
-- carries an absolute path or a ".." segment (zip-slip: the extractor would
-- write outside the game folder), or a backslash: 7-Zip on Linux extracts
-- "sub\fix.dll" as ONE file of that name in the game root, which neither the
-- game loads nor a "sub/fix.dll" record would let Un-fix remove. PURE.
function fixinstall.safe_entries(entries)
  local out = {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    local p = tostring(type(e) == "table" and e.path or "")
    if p ~= "" and not p:find("[\0\r\n]") then
      if p:find("\\", 1, true) then return nil, "backslash_path" end
      if p:sub(1, 1) == "/" or p:match("^%a:") then
        return nil, "absolute_path"
      end
      for seg in p:gmatch("[^/]+") do
        if seg == ".." then return nil, "parent_escape" end
      end
      if p:sub(-1) == "/" then p = p:sub(1, -2) end
      if p ~= "" then out[#out + 1] = { path = p, size = tonumber(e.size) or 0 } end
    end
  end
  return out
end

-- The game-folder file LuaTools' fix_overlays reads a fix's DLLs from.
local FIX_DLL_LIST = ".slssteam_fix_dlls"

-- fix_dll_list(entries) -> that file's text: the base name of each .dll the
-- archive ships, one per line, deduplicated ignoring case. PURE.
function fixinstall.fix_dll_list(entries)
  local lines, seen = {}, {}
  for _, e in ipairs(entries) do
    local name = e.path:match("[^/]+$")
    if name:lower():match("%.dll$") and not seen[name:lower()] then
      seen[name:lower()] = true
      lines[#lines + 1] = name .. "\n"
    end
  end
  return table.concat(lines)
end

-- parse_inno_listing(text) -> { { path, size } } from `innoextract -l`
-- output. Only the {app} payload matters: lines like
--   - "app/SteamFix.ini" (284 B)
--   - "tmp/botva2.dll" [temp] (32 KiB)
-- Entries carrying a flag ([temp], [lang:..] — Lua patterns cannot make a
-- group optional, and the unflagged form below simply never matches a
-- flagged line) are installer machinery, never payload; non-app/ destina-
-- tions are dropped, and the "app/" prefix is stripped so paths match the
-- game folder. PURE.
function fixinstall.parse_inno_listing(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local units = { B = 1, KiB = 1024, MiB = 1048576, GiB = 1073741824 }
  for line in text:gmatch("([^\r\n]*)\r?\n") do
    local path, num, unit = line:match(
      '^%s*%-%s+"([^"]+)"%s+%(([%d%.]+)%s+([BKMG]i?B?)%)$')
    if path and path:sub(1, 4) == "app/" then
      local p = path:sub(5)
      if p ~= "" and not p:find("[\0\r\n]") and units[unit] then
        out[#out + 1] = { path = p, size = math.floor(tonumber(num) * units[unit]) }
      end
    end
  end
  return out
end

-- under_home(path, home) -> path lies inside home and carries no ".." segment.
-- The install RPC only accepts archives the user could have downloaded. PURE.
function fixinstall.under_home(path, home)
  path, home = tostring(path or ""), tostring(home or "")
  if path == "" or home == "" then return false end
  if path:sub(1, #home) ~= home then return false end
  local rest = path:sub(#home + 1)
  if rest:sub(1, 1) ~= "/" then return false end
  for seg in rest:gmatch("[^/]+") do
    if seg == ".." then return false end
  end
  return true
end

local function store_root()
  return (os.getenv("HOME") or "") .. "/.local/share/Lumen/fix_installs"
end

local function popen_read(cmd)
  local p = io.popen(cmd, "r")
  if not p then return "" end
  local out = p:read("*a")
  p:close()
  return out or ""
end

local function popen_line(cmd)
  local p = io.popen(cmd, "r")
  if not p then return nil end
  local l = p:read("*l")
  p:close()
  return l
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

-- The LuaTools plugin's 7zz, or "" without the plugin.
local function shipped_7zz()
  local backend = require("utils").get_backend_path()
  return backend ~= "" and backend .. "/bin/7zz" or ""
end

-- read_manifest(root) -> the record, or nil + errorCode when one exists but
-- cannot be read or decoded (nil alone: there is none).
local function read_manifest(root)
  local f, _, errno = io.open(root .. "/manifest.json", "rb")
  if not f then return nil, errno ~= 2 and "record_unreadable" or nil end
  local raw = f:read("*a")
  f:close()
  if not raw then return nil, "record_unreadable" end
  local ok, m = pcall(json.decode, raw)
  if not (ok and type(m) == "table") then return nil, "record_invalid" end
  return m
end

-- first_bin(candidates) -> the first candidate that exists: absolute paths
-- are probed directly, bare names resolved through PATH; nil when none.
local function first_bin(candidates)
  for _, c in ipairs(candidates) do
    if c:sub(1, 1) == "/" then
      if exists(c) then return c end
    else
      local out = popen_line("command -v -- " .. shq(c) .. " 2>/dev/null")
      if out and out ~= "" then return out end
    end
  end
  return nil
end

-- find_7z() -> absolute path of a 7-zip binary, or nil.
function fixinstall.find_7z()
  return first_bin({ "7zz", "7z", shipped_7zz() })
end

-- find_inno() -> absolute path of innoextract, or nil.
function fixinstall.find_inno()
  return first_bin({ "innoextract" })
end

-- list_archives(home, deps) -> recent archives from the user's real
-- downloads directory (xdg-user-dir DOWNLOAD, e.g. Turkish "İndirilenler"),
-- with ~/Downloads as a fallback; both are scanned and merged when distinct.
-- deps.read_pipe(cmd) -> text and deps.downloads_dir (single dir override)
-- are injectable for tests.
function fixinstall.list_archives(home, deps)
  deps = deps or {}
  home = home or os.getenv("HOME") or ""
  if home == "" then return {} end
  local read_pipe = deps.read_pipe or popen_read
  local read_line = deps.read_line or popen_line

  -- The dirs to scan: the explicit override, else xdg DOWNLOAD + ~/Downloads.
  local dirs = {}
  if deps.downloads_dir then
    dirs[#dirs + 1] = deps.downloads_dir
  else
    local xdg = read_line("xdg-user-dir DOWNLOAD 2>/dev/null")
    if type(xdg) == "string" and xdg:sub(1, 1) == "/" then dirs[#dirs + 1] = xdg end
    if dirs[1] ~= home .. "/Downloads" then dirs[#dirs + 1] = home .. "/Downloads" end
  end

  local entries = {}
  for _, dir in ipairs(dirs) do
    if os.execute("test -d " .. shq(dir) .. " 2>/dev/null") == true then
      local text = read_pipe(
        "find -- " .. shq(dir) .. " -maxdepth 1 -type f "
        .. "\\( -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' "
        .. "-o -iname '*.exe' \\) "
        .. "-printf '%s|%T@|%p\\n' 2>/dev/null | sort -t'|' -k2 -nr | head -60")
      -- Lua's '.' also matches newlines, so a single greedy (.+) would glue
      -- every find line into one bogus entry. Split into
      -- lines first (the same line splitter parse_7z_listing uses), then
      -- parse each line with an anchored pattern.
      if text:sub(-1) ~= "\n" then text = text .. "\n" end
      for line in text:gmatch("([^\r\n]*)\r?\n") do
        local size, mtime, path = line:match("^(%d+)%|([%d%.]+)%|(.+)$")
        if size and mtime and path and path ~= "" then
          entries[#entries + 1] = {
            name = path:match("([^/]+)$") or path,
            path = path,
            size = tonumber(size) or 0,
            mtime = math.floor(tonumber(mtime) or 0),
          }
        end
      end
    end
  end
  -- Classify exes: keep only Inno Setup installers innoextract can actually
  -- read — a random downloaded program must never appear in the fix picker.
  -- Newest first, so the setup just downloaded is always among those probed;
  -- setups too big to list are skipped before probing, so they never use up
  -- the probe budget.
  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  local inno_bin = fixinstall.find_inno()
  local kept, probed = {}, 0
  for _, e in ipairs(entries) do
    if not fixinstall.is_inno_name(e.name) then
      kept[#kept + 1] = e
    elseif inno_bin and probed < fixinstall.MAX_SETUPS_PROBED
        and e.size <= fixinstall.MAX_ARCHIVE_BYTES then
      probed = probed + 1
      local ltext = read_pipe(shq(inno_bin) .. " -l -- " .. shq(e.path) .. " 2>/dev/null")
      if #fixinstall.parse_inno_listing(ltext) > 0 then kept[#kept + 1] = e end
    end
  end
  return fixinstall.filter_archives(kept)
end

-- How deep the fix scan walks below the game root. Unreal and Unity depots
-- nest their payload (Satisfactory keeps the fix in Engine/Binaries/Win64), so
-- a root+one-level scan reported "no fix" for a correctly installed one.
fixinstall.FIX_SCAN_DEPTH = 4
-- Ceiling on entries visited; the scan runs on the single-threaded RPC loop.
fixinstall.FIX_SCAN_MAX_ENTRIES = 20000

-- scan_fix_files(root, fs_mod) -> { { name, path } } for every file under root
-- within FIX_SCAN_DEPTH, breadth-first, capped at FIX_SCAN_MAX_ENTRIES.
-- Unreadable directories are skipped. fs_mod follows Lumen's fs.list contract.
function fixinstall.scan_fix_files(root, fs_mod)
  local out, seen = {}, 0
  if type(root) ~= "string" or root == "" or type(fs_mod) ~= "table"
      or type(fs_mod.list) ~= "function" then
    return out
  end
  local queue, head = { { dir = root, depth = 0 } }, 1
  while head <= #queue do
    local item = queue[head]
    head = head + 1
    local ok, entries = pcall(fs_mod.list, item.dir)
    for _, e in ipairs(ok and type(entries) == "table" and entries or {}) do
      if type(e) == "table" then
        seen = seen + 1
        if seen > fixinstall.FIX_SCAN_MAX_ENTRIES then return out end
        local path = tostring(e.path or "")
        if path == "" and e.name then path = item.dir .. "/" .. tostring(e.name) end
        if e.is_directory then
          if item.depth + 1 < fixinstall.FIX_SCAN_DEPTH then
            queue[#queue + 1] = { dir = path, depth = item.depth + 1 }
          end
        else
          out[#out + 1] = { name = tostring(e.name or ""), path = path }
        end
      end
    end
  end
  return out
end

-- parse_fix_appids(text) -> realAppId, fakeAppId from an OnlineFix/SteamFix
-- ini body. Both spellings seen in the wild are accepted; a missing, zero or
-- self-referential fake id means the fix needs no appid swap. PURE.
function fixinstall.parse_fix_appids(text)
  if type(text) ~= "string" then return nil, nil end
  local real = text:match("\n%s*RealAppId%s*=%s*(%d+)") or text:match("^RealAppId%s*=%s*(%d+)")
  local fake = text:match("\n%s*FakeAppId%s*=%s*(%d+)") or text:match("^FakeAppId%s*=%s*(%d+)")
  real, fake = tonumber(real), tonumber(fake)
  if not fake or fake <= 0 then return real, nil end
  if real and real == fake then return real, nil end
  return real, fake
end

local function read_text_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- read_fix_appids(install_dir, files, deps) -> real, fake, ini_path.
-- Reads the appid pair the fix's own config declares. `files` is an existing
-- scan (or nil to scan); deps.read_file is injectable for tests.
function fixinstall.read_fix_appids(install_dir, files, deps)
  deps = deps or {}
  local read_file = deps.read_file or read_text_file
  local list = files
  if not list then
    local fs_mod = deps.fs
    if not fs_mod then
      local ok, f = pcall(require, "fs")
      fs_mod = ok and f or nil
    end
    list = fixinstall.scan_fix_files(install_dir, fs_mod)
  end
  for _, e in ipairs(list) do
    local low = tostring(e.name or ""):lower()
    if low == "onlinefix.ini" or low == "steamfix.ini" then
      local real, fake = fixinstall.parse_fix_appids(read_file(e.path) or "")
      return real, fake, e.path
    end
  end
  return nil, nil, nil
end

-- sync_fake_appid(appid, install_dir, deps) -> { success, fakeAppId, status }
-- or nil when the fix declares no swap. `deps.ini_path` skips the scan when the
-- caller already knows where the fix's config landed (install does).
-- Applies the appid swap a Windows online fix declares in its own config
-- (FakeAppId) through SLSsteam's FakeAppIds map. A Windows fix makes the game
-- report the fake AppID at the client layer; without the same swap on Linux the
-- lobby is hosted/joined under another AppID and SteamNetworkingSockets refuses
-- the P2P cert ("Cert is not authorized for appid X, only 480").
function fixinstall.sync_fake_appid(appid, install_dir, deps)
  deps = deps or {}
  appid = tonumber(appid)
  if not appid then return nil end
  if type(install_dir) ~= "string" and type(deps.ini_path) ~= "string" then return nil end
  local read_file = deps.read_file or read_text_file
  local real, fake
  if type(deps.ini_path) == "string" then
    real, fake = fixinstall.parse_fix_appids(read_file(deps.ini_path) or "")
  else
    real, fake = fixinstall.read_fix_appids(install_dir, nil, deps)
  end
  if not fake then return nil end
  if real and real ~= appid then return nil end
  local ok_sls, sls = pcall(require, "slsteam")
  if not (ok_sls and sls and sls.set_fake_appid) then
    return { success = false, fakeAppId = fake, status = "slsteam_unavailable" }
  end
  local ok, status = sls.set_fake_appid(appid, fake)
  return { success = ok == true, fakeAppId = fake, status = tostring(status or "") }
end

-- detect_local(install_path, deps) -> { found, broken, fakeAppId }: is a REAL
-- fix installed in this game folder? A fix announces itself with a loader list
-- file (winmm.txt / dlllist.txt), a fix config (onlinefix.ini /
-- steamfix.ini), or a fix payload DLL (onlinefix*/steamfix*). A proxy DLL
-- (winmm/winhttp/version) alone is not enough: mod loaders such as BepInEx
-- ship one too. Only fix-specific names count: a game-shipped DirectX redist
-- (D3D12/D3D12Core.dll) must NEVER read as "a fix is installed". deps.fs is
-- injectable for tests.
function fixinstall.detect_local(install_path, deps)
  deps = deps or {}
  local res = { found = false, broken = false }
  if type(install_path) ~= "string" or install_path == "" then return res end
  local fs_mod = deps.fs
  if not fs_mod then
    local ok, f = pcall(require, "fs")
    fs_mod = ok and f or nil
  end
  if type(fs_mod) ~= "table" or type(fs_mod.list) ~= "function" then return res end
  local files = fixinstall.scan_fix_files(install_path, fs_mod)
  local proxies = { winmm = true, winhttp = true, version = true }
  local proxy, loader, ini_path = false, false, nil
  for _, e in ipairs(files) do
    local low = tostring(e.name or ""):lower()
    local stem = low:match("^(.-)%.dll$")
    if stem and proxies[stem] then proxy = true end
    if low == "winmm.txt" or low == "dlllist.txt" then loader = true end
    if low == "onlinefix.ini" or low == "steamfix.ini"
        or (stem and (stem:match("^onlinefix%d*$") or stem:match("^steamfix%d*$"))) then
      res.found = true
      if low == "onlinefix.ini" or low == "steamfix.ini" then ini_path = e.path end
    end
  end
  res.found = res.found or loader
  -- A loader list without its proxy DLL cannot load (LuaTools' UnFixGame
  -- deletes winmm.dll even when no fix of its own is recorded).
  res.broken = loader and not proxy
  -- The appid the fix itself asks for, so the menu can show/offer the swap.
  if ini_path then
    local _, fake = fixinstall.parse_fix_appids((deps.read_file or read_text_file)(ini_path) or "")
    res.fakeAppId = fake
  end
  return res
end

-- game_root(install_dir, entries, list_dir) -> the folder the fix belongs
-- in. Some depots nest the game one level down ("How to Fish/How to Fish/
-- How to Fish.exe"), so the target is whichever of the install dir and its
-- direct subfolders already holds the most of the archive's top-level names
-- (the game exe, its _Data folder); ties keep the install dir.
-- list_dir(path) -> { { name, is_directory } } (lumen fs.list contract).
function fixinstall.game_root(install_dir, entries, list_dir)
  local tops = {}
  for _, e in ipairs(entries) do tops[e.path:match("^[^/]+")] = true end
  local function score(dir)
    local ok, list = pcall(list_dir, dir)
    local n = 0
    for _, x in ipairs(ok and type(list) == "table" and list or {}) do
      if tops[x.name] then n = n + 1 end
    end
    return n, ok and list or {}
  end
  local best, best_n, list = install_dir, score(install_dir)
  for _, x in ipairs(list) do
    if x.is_directory then
      local n = score(install_dir .. "/" .. x.name)
      if n > best_n then best, best_n = install_dir .. "/" .. x.name, n end
    end
  end
  return best
end

local function resolve_install_default(appid)
  local ok, su = pcall(require, "steam_utils")
  if ok and su and su.get_game_install_path_response then
    return su.get_game_install_path_response(appid)
  end
  return nil
end

-- resolve_install_dir(appid, deps) -> Steam's install path for appid, or nil.
-- The single place that answers "where is this game", so the install, the RPC
-- and the boot reconcile cannot drift apart.
function fixinstall.resolve_install_dir(appid, deps)
  deps = deps or {}
  appid = tonumber(appid)
  if not appid then return nil end
  local info = (deps.resolve_install or resolve_install_default)(appid)
  if type(info) == "table" and info.success == true
      and type(info.installPath) == "string" and info.installPath ~= "" then
    return info.installPath
  end
  return nil
end

-- trusted_install_dir(appid, hint, resolve) -> Steam's own install dir for
-- appid, or nil + errorCode when the game is not installed or the frontend's
-- hint names another folder.
local function trusted_install_dir(appid, hint, resolve)
  local info = (resolve or resolve_install_default)(appid)
  if type(info) ~= "table" or info.success ~= true
      or type(info.installPath) ~= "string" or info.installPath == "" then
    return nil, "not_installed"
  end
  hint = tostring(hint or "")
  if hint ~= "" and hint ~= info.installPath then return nil, "invalid_destination" end
  return info.installPath
end

-- remove_added(m) -> how many of record m's added files were removed from its
-- game folder, or nil for no record or one naming a path outside that folder.
local function remove_added(m)
  local install_dir = m and tostring(m.installPath or "") or ""
  if install_dir == "" then return nil end
  local added = {}
  for _, p in ipairs(type(m.added) == "table" and m.added or {}) do
    added[#added + 1] = { path = tostring(p) }
  end
  -- A tampered record must never delete outside the game folder.
  added = fixinstall.safe_entries(added)
  if not added then return nil end

  for _, e in ipairs(added) do
    local p = e.path
    os.execute("rm -f -- " .. shq(install_dir .. "/" .. p))
    -- Folders the fix brought along go too, but only once empty.
    local parent = p:match("^(.*)/[^/]+$")
    if parent then
      os.execute("cd " .. shq(install_dir) .. " && rmdir -p --ignore-fail-on-non-empty -- "
        .. shq(parent) .. " 2>/dev/null")
    end
  end
  return #added
end

-- write_manifest(root, data, open) -> true once data is root/manifest.json in
-- full. It goes to a temporary file renamed over the record, so a failed
-- write (unwritable folder, full disk) leaves the previous record whole.
local function write_manifest(root, data, open)
  local tmp = root .. "/manifest.json.tmp"
  local f = open(tmp, "wb")
  if not f then return false end
  local written = f:write(data)
  local closed = f:close()
  if not (written and closed and os.rename(tmp, root .. "/manifest.json")) then
    os.remove(tmp)
    return false
  end
  return true
end

local function install_archive(appid, archive_path, install_path_hint, deps)
  local res = { success = false }
  appid = tonumber(appid)
  if not appid or appid <= 0 or appid ~= math.floor(appid) then
    res.errorCode = "invalid_appid"
    return res
  end

  local install_dir, why = trusted_install_dir(appid, install_path_hint, deps.resolve_install)
  if not install_dir then
    res.errorCode = why
    return res
  end

  archive_path = tostring(archive_path or "")
  local home = deps.home or os.getenv("HOME") or ""
  if not fixinstall.under_home(archive_path, home)
      or not fixinstall.installable_name(archive_path) then
    res.errorCode = "invalid_archive"
    return res
  end
  if not exists(archive_path) then
    res.errorCode = "archive_missing"
    return res
  end

  local is_inno = fixinstall.is_inno_name(archive_path)
  local bin = deps.bin or (not is_inno and fixinstall.find_7z()) or nil
  if not is_inno and not bin then
    res.errorCode = "no_extractor"
    return res
  end
  local inno_bin = is_inno and fixinstall.find_inno() or nil
  if is_inno and not inno_bin then
    res.errorCode = "no_extractor_inno"
    return res
  end

  -- The extractor commands run through deps.read_pipe / deps.execute
  -- (injectable for tests).
  local read_pipe, execute = deps.read_pipe or popen_read, deps.execute or os.execute
  -- 7-Zip waits on stdin for the password of an encrypted archive, which
  -- would stall the single-threaded RPC loop; with no stdin it fails at once.
  local function list_7z(b)
    return fixinstall.safe_entries(fixinstall.parse_7z_listing(read_pipe(shq(b)
      .. " l -ba -slt -p" .. shq(fixinstall.ARCHIVE_PASSWORD) .. " -- " .. shq(archive_path)
      .. " </dev/null 2>/dev/null")))
  end
  local entries
  if is_inno then
    local itext = read_pipe(shq(inno_bin) .. " -l -- " .. shq(archive_path) .. " 2>/dev/null")
    entries = fixinstall.safe_entries(fixinstall.parse_inno_listing(itext))
  else
    entries = list_7z(bin)
    -- A PATH 7z without the RAR codec lists nothing; the bundled 7zz has it.
    if entries and #entries == 0 and not deps.bin and bin ~= shipped_7zz()
        and exists(shipped_7zz()) then
      bin = shipped_7zz()
      entries = list_7z(bin)
    end
  end
  if not entries then
    res.errorCode = "unsafe_archive"
    return res
  end
  if #entries == 0 then
    res.errorCode = "bad_archive"
    return res
  end

  -- A previous install of ours is removed first so records stay truthful;
  -- the game files IT overwrote still hold fix content, so they stay listed.
  -- Its record stays until the new one replaces it.
  local root = (deps.store_root or store_root)() .. "/" .. appid
  local prev = read_manifest(root)
  remove_added(prev)
  install_dir = fixinstall.game_root(install_dir, entries,
    function(p) return require("fs").list(p) end)
  local stage = root .. "/stage"
  os.execute("mkdir -p -- " .. shq(root))
  os.execute("rm -rf -- " .. shq(stage))

  -- Which game files will be overwritten: decided BEFORE any file lands.
  local added, replaced, replaced_set = {}, {}, {}
  for _, e in ipairs(entries) do
    if exists(install_dir .. "/" .. e.path) then
      replaced[#replaced + 1] = e.path
      replaced_set[e.path] = true
    end
  end
  for _, e in ipairs(entries) do
    if not replaced_set[e.path] then added[#added + 1] = e.path end
  end
  -- The fix's DLL list for the launch options, as LuaTools' downloader writes
  -- it: without one, its fix_overlays derives overrides from every DLL in the
  -- game folder (the game's own D3D12/D3D12Core.dll included). It is written
  -- even when empty, which reads as "no override needed". One already there
  -- belongs to a LuaTools fix and is left alone.
  local dll_list = install_dir .. "/" .. FIX_DLL_LIST
  -- Rewrite the list when we wrote it last time (a re-apply with a different
  -- archive must not keep the previous fix's override set); a list we do not
  -- own belongs to the LuaTools downloader or a manual fix and is left alone.
  local dll_list_owned = false
  if prev and type(prev.added) == "table" then
    for _, p in ipairs(prev.added) do
      if p == FIX_DLL_LIST then dll_list_owned = true break end
    end
  end
  local write_dll_list = dll_list_owned or not exists(dll_list)
  if not exists(dll_list) then added[#added + 1] = FIX_DLL_LIST end
  -- Even when this archive picks another game root: revert only counts them.
  if prev and type(prev.replaced) == "table" then
    for _, p in ipairs(prev.replaced) do
      if not replaced_set[p] then
        replaced[#replaced + 1] = p
        replaced_set[p] = true
      end
    end
  end

  local lumen = home .. "/.local/share/Lumen/"
  local source = archive_path:find(lumen .. "freetp_dl/", 1, true) == 1 and "freetp"
    or archive_path:find(lumen .. "onlinefix_dl/", 1, true) == 1 and "onlinefix"
    or "archive"
  -- Recorded BEFORE extraction: a half-finished extract stays revertible.
  if not write_manifest(root, json.encode({
    installedAt = os.time(),
    archive = archive_path:match("([^/]+)$") or archive_path,
    source = source,
    installPath = install_dir,
    added = added,
    replaced = replaced,
  }), deps.open_file or io.open) then
    res.errorCode = "record_failed"
    return res
  end

  if is_inno then
    -- innoextract recreates app/ (the {app} payload) and tmp/ (wizard
    -- resources) under the stage; only app/* moves into the game folder.
    if execute(shq(inno_bin) .. " -d " .. shq(stage) .. " -- "
        .. shq(archive_path) .. " >/dev/null 2>&1") ~= true then
      res.errorCode = "extract_failed"
      return res
    end
    for _, e in ipairs(entries) do
      local dst = install_dir .. "/" .. e.path
      local parent = dst:match("^(.*)/[^/]+$")
      if parent then os.execute("mkdir -p -- " .. shq(parent) .. " 2>/dev/null") end
      os.execute("mv -f -- " .. shq(stage .. "/app/" .. e.path) .. " " .. shq(dst))
    end
    os.execute("rm -rf -- " .. shq(stage))
  elseif execute(shq(bin) .. " x -y -p" .. shq(fixinstall.ARCHIVE_PASSWORD) .. " -o"
      .. shq(install_dir) .. " -- " .. shq(archive_path) .. " </dev/null >/dev/null 2>&1") ~= true then
    res.errorCode = "extract_failed"
    return res
  end
  if write_dll_list then
    local f = io.open(dll_list, "wb")
    if f then
      f:write(fixinstall.fix_dll_list(entries))
      f:close()
    end
  end

  -- A Windows online fix swaps the AppID at the client layer itself; the same
  -- swap has to happen in SLSsteam, or this side reports the real AppID while
  -- the other players' fixes report the fake one and SteamNetworkingSockets
  -- refuses the P2P cert. The ini path comes from the archive listing, so no
  -- second tree scan is needed. Best-effort: a failure leaves files installed.
  local ini_path
  for _, e in ipairs(entries) do
    local low = e.path:match("[^/]+$"):lower()
    if low == "onlinefix.ini" or low == "steamfix.ini" then
      ini_path = install_dir .. "/" .. e.path
      break
    end
  end
  local ok_sync, synced = pcall(fixinstall.sync_fake_appid, appid, install_dir,
    { read_file = deps.read_file, ini_path = ini_path })
  if ok_sync and type(synced) == "table" and synced.success then
    res.fakeAppId = synced.fakeAppId
    local rec = read_manifest(root)
    if type(rec) == "table" then
      rec.fakeAppId = res.fakeAppId
      write_manifest(root, json.encode(rec), deps.open_file or io.open)
    end
  end

  res.success = true
  res.added = #added
  res.replaced = #replaced
  return res
end

-- install(appid, archive_path, install_path_hint, deps)
--   -> { success, added, replaced } or { success=false, errorCode }
-- The install dir is always re-derived from Steam's own manifests; the
-- frontend's hint must agree with it or the call is refused. What Lumen
-- downloaded itself (a download_dir file, an online-fix.me download folder)
-- is deleted afterwards, installed or not: Un-fix works from the manifest,
-- and a failed one is downloaded again.
function fixinstall.install(appid, archive_path, install_path_hint, deps)
  deps = deps or {}
  local res = install_archive(appid, archive_path, install_path_hint, deps)
  local path, home = tostring(archive_path or ""), deps.home or os.getenv("HOME") or ""
  if fixinstall.under_home(path, home)
      and path:find(fixinstall.download_dir(home) .. "/", 1, true) == 1 then
    os.execute("rm -f -- " .. shq(path))
  end
  local od = path:match("^(.-/onlinefix_dl/%d+)/")
  if od and od:find(home .. "/.local/share/Lumen/onlinefix_dl/", 1, true) == 1
      and fixinstall.under_home(od, home) then
    os.execute("rm -rf -- " .. shq(od))
  end
  return res
end

-- revert(appid, deps) -> { success, reverted, removed, replacedCount,
-- needsVerify }. Removes the files the fix added; game files it overwrote
-- come back only through Steam's verify (needsVerify). With no recorded
-- install it reports reverted=false and touches nothing; a record it cannot
-- read or use (bad JSON, a path outside the game folder) fails with an
-- errorCode, as its files may still be in place.
function fixinstall.revert(appid, deps)
  deps = deps or {}
  local res = { success = true, reverted = false, removed = 0,
    replacedCount = 0, needsVerify = false }
  appid = tonumber(appid)
  if not appid then return res end
  local root = (deps.store_root or store_root)() .. "/" .. appid
  local m, why = read_manifest(root)
  if why then
    res.success = false
    res.errorCode = why
    return res
  end
  if not m then return res end
  local removed = remove_added(m)
  if not removed then
    res.success = false
    res.errorCode = "record_invalid"
    return res
  end
  res.removed = removed
  res.replacedCount = #(type(m.replaced) == "table" and m.replaced or {})
  res.needsVerify = res.replacedCount > 0
  -- Drop only the swap this record installed: a mapping the user set by hand (or
  -- the SpaceFix tile) survives, because the recorded id must still match.
  local recorded_fake = tonumber(m.fakeAppId)
  if recorded_fake then
    local ok_sls, sls = pcall(require, "slsteam")
    if ok_sls and sls and sls.get_fake_appid and sls.unset_fake_appid
        and tonumber(sls.get_fake_appid(appid)) == recorded_fake then
      pcall(sls.unset_fake_appid, appid)
      res.fakeAppIdCleared = recorded_fake
    end
  end
  os.execute("rm -rf -- " .. shq(root))
  res.reverted = true
  return res
end

-- managed_appids(deps) -> sorted list of appids SLSsteam manages, from the
-- stplug-in scripts the client reads. Those are exactly the games whose online
-- fix the Fixes menu can be used on, whichever path installed it.
function fixinstall.managed_appids(deps)
  deps = deps or {}
  local home = deps.home or os.getenv("HOME") or ""
  if home == "" then return {} end
  local dir = deps.stplug_dir or (home .. "/.steam/steam/config/stplug-in")
  local list_dir = deps.list_dir
  if not list_dir and type(deps.fs) == "table" and type(deps.fs.list) == "function" then
    list_dir = deps.fs.list
  end
  if not list_dir then
    list_dir = function(d)
      local ok_fs, fs_mod = pcall(require, "fs")
      if not (ok_fs and type(fs_mod) == "table" and type(fs_mod.list) == "function") then
        return {}
      end
      local ok, entries = pcall(fs_mod.list, d)
      return ok and type(entries) == "table" and entries or {}
    end
  end
  local ids, seen = {}, {}
  for _, e in ipairs(list_dir(dir)) do
    local name = tostring(e.name or "")
    local id = tonumber(name:match("^(%d+)%.lua$"))
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

-- reconcile_fake_appids(deps) -> { checked, applied, skipped }.
-- Runs at boot so a fix installed by ANY path (LuaTools' own downloader, the
-- FreeTP/online-fix archive install, a manual extraction) gets the appid swap
-- its own config declares. It never invents a mapping: a game whose fix config
-- declares no FakeAppId is left alone, an existing mapping is never
-- overwritten, and a game with no fix on disk is skipped.
function fixinstall.reconcile_fake_appids(deps)
  deps = deps or {}
  local out = { checked = 0, applied = 0, skipped = 0 }
  local ok_sls, sls = pcall(require, "slsteam")
  if not (ok_sls and sls and sls.get_fake_appid and sls.set_fake_appid) then return out end
  local fs_mod = deps.fs
  if not fs_mod then
    local ok_fs, f = pcall(require, "fs")
    fs_mod = ok_fs and f or nil
  end
  if type(fs_mod) ~= "table" or type(fs_mod.list) ~= "function" then return out end
  local resolve = deps.resolve_install
  if not resolve then
    local ok_su, su = pcall(require, "steam_utils")
    if not (ok_su and type(su) == "table" and su.get_game_install_path_response) then return out end
    resolve = function(id)
      local ok, info = pcall(su.get_game_install_path_response, id)
      return ok and type(info) == "table" and info.success == true and info.installPath or nil
    end
  end
  for _, id in ipairs(fixinstall.managed_appids(deps)) do
    out.checked = out.checked + 1
    local install_dir = resolve(id)
    local current = tonumber(sls.get_fake_appid(id))
    if not install_dir or current then
      out.skipped = out.skipped + 1
    else
      local detected = fixinstall.detect_local(install_dir, { fs = fs_mod })
      local fake = detected and detected.fakeAppId
      if not fake then
        out.skipped = out.skipped + 1
      else
        local ok, status = sls.set_fake_appid(id, fake)
        if ok == true then out.applied = out.applied + 1 else out.skipped = out.skipped + 1 end
      end
    end
  end
  return out
end

-- register(registry, deps): `deps` reaches install and revert — inject it
-- from tests; production leaves it nil.
function fixinstall.register(registry, deps)
  -- A fix applied before this module knew about appid swaps (or by the plugin's
  -- own downloader) still needs the mapping once SLSsteam is up. Boot is the
  -- only moment that is guaranteed to run after the client injected the hook.
  pcall(fixinstall.reconcile_fake_appids, deps)

  -- The plugin's own downloader extracts a Windows fix without ever touching the
  -- client layer, so its completion path asks for the swap explicitly. Returns
  -- { success, applied, fakeAppId } — `applied` is false when the fix declares
  -- no swap, which is a normal answer, not a failure.
  registry.LumenSyncFixAppId = function(appid, contentScriptQuery, installPath)
    if type(appid) == "table" then
      installPath = appid.installPath
      appid = appid.appid
    end
    appid = tonumber(appid)
    local res = { success = true, applied = false }
    if not appid then return json.encode({ success = false, error = "invalid_appid" }) end
    local dir = trusted_install_dir(appid, installPath, deps and deps.resolve_install)
    if not dir then
      dir = fixinstall.resolve_install_dir(appid, deps)
    end
    if not dir then return json.encode({ success = false, error = "not_installed" }) end
    local ok, synced = pcall(fixinstall.sync_fake_appid, appid, dir, deps)
    if ok and type(synced) == "table" then
      res.applied = synced.success == true
      res.fakeAppId = synced.fakeAppId
      res.status = synced.status
      if res.applied then
        local root = (deps and deps.store_root or store_root)() .. "/" .. appid
        local rec = read_manifest(root)
        if type(rec) == "table" and rec.fakeAppId ~= synced.fakeAppId then
          rec.fakeAppId = synced.fakeAppId
          write_manifest(root, json.encode(rec), deps and deps.open_file or io.open)
        end
      end
    end
    return json.encode(res)
  end
  -- Bridge contract: JS object keys arrive alphabetically positional; the
  -- table form is tolerated too.
  registry.LumenDetectLocalFix = function(appid, contentScriptQuery, installPath)
    if type(appid) == "table" then
      installPath = appid.installPath
      appid = appid.appid
    end
    appid = tonumber(appid)
    local res = { success = true, found = false }
    local dir = appid and trusted_install_dir(appid, installPath)
    if not dir then return json.encode(res) end
    local ok, det = pcall(fixinstall.detect_local, dir, deps)
    res.found = ok and type(det) == "table" and det.found == true
    res.broken = res.found and det.broken == true
    if res.found and type(det) == "table" and det.fakeAppId then
      res.fakeAppId = det.fakeAppId
    end
    local m = read_manifest((deps and deps.store_root or store_root)() .. "/" .. appid)
    res.recorded = m and m.source or nil
    return json.encode(res)
  end
  registry.LumenListFixArchives = function()
    local ok, res = pcall(fixinstall.list_archives, nil, {})
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode({ success = true, archives = res })
  end
  -- {appid, archivePath, contentScriptQuery, installPath} sorted.
  registry.LumenInstallFixArchive = function(appid, archivePath, contentScriptQuery, installPath)
    if type(appid) == "table" then
      archivePath = appid.archivePath
      installPath = appid.installPath
      appid = appid.appid
    end
    local ok, res = pcall(fixinstall.install, appid, archivePath, installPath, deps)
    if not ok then
      return json.encode({ success = false, errorCode = "crash", error = tostring(res) })
    end
    return json.encode(res)
  end
  registry.LumenRevertFixInstall = function(appid, contentScriptQuery)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixinstall.revert, appid, deps)
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode(res)
  end
  return registry
end

return fixinstall
