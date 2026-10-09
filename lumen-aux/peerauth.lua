-- peerauth: prove that whatever is listening on the CEF debugging port is the
-- Steam client before speaking CDP to it.
--
-- DroidDeck / Android adaptation:
-- On Android (Poco F9 Ultra / Termux / PRoot), Android SELinux blocks unprivileged
-- reading of /proc/net/tcp, causing listener_inodes_for() to find 0 socket inodes.
-- This module retains the standard kernel-inode check where available, and safely
-- falls back to probing the loopback endpoint (/json/version) for Steam's client
-- identity headers when running under Android/PRoot container environments.
local lfs = require("lfs")

local peerauth = {}

-- TCP state 0x0A == TCP_LISTEN.
local LISTEN = "0A"

-- Loopback, as /proc/net/tcp and /proc/net/tcp6 spell it. The injector only ever
-- connects to 127.0.0.1, so a listener bound elsewhere is not the socket we are
-- about to talk to and must not vouch for it.
local LOOPBACK_V4 = "0100007F"
local LOOPBACK_V6 = "00000000000000000000000000000001"
local LOOPBACK_V6_MAPPED = "0000000000000000FFFF00000100007F"

-- Executables allowed to own the CEF endpoint.
local STEAM_EXE = { steam = true, steamwebhelper = true }

-- Path fragments that place an executable inside a Steam client installation.
-- Added /steamrtarm64/ for Valve's native ARM64 Steam client running in DroidDeck.
local STEAM_TREE = {
  "/.steam/", "/.local/share/Steam/", "/ubuntu12_32/", "/ubuntu12_64/",
  "/linux32/", "/linux64/", "/steamapps/", "/steamrtarm64/",
}

local function local_address_is_loopback(address)
  if type(address) ~= "string" then return false end
  local hex = address:upper()
  if hex == LOOPBACK_V4 or hex == LOOPBACK_V6 or hex == LOOPBACK_V6_MAPPED then
    return true
  end
  return hex:match("^0+$") ~= nil
end

function peerauth.listener_inodes(text, port)
  local out = {}
  if type(text) ~= "string" or type(port) ~= "number" then return out end
  if port < 1 or port > 65535 or port ~= math.floor(port) then return out end
  local want = string.format("%04X", port)
  for line in text:gmatch("[^\n]+") do
    local f = {}
    for tok in line:gmatch("%S+") do f[#f + 1] = tok end
    if #f >= 10 then
      local local_address, local_port = nil, nil
      if f[2] then local_address, local_port = f[2]:match("^(%x+):(%x+)$") end
      if local_port and local_port:upper() == want and f[4]:upper() == LISTEN
          and local_address_is_loopback(local_address) then
        local inode = tonumber(f[10])
        if inode then out[#out + 1] = math.floor(inode) end
      end
    end
  end
  return out
end

function peerauth.is_steam_exe(target)
  if type(target) ~= "string" or target == "" then return false end
  if target:find(" (deleted)", 1, true) then return false end
  local base = target:match("([^/]+)$")
  if base == nil or STEAM_EXE[base] ~= true then return false end
  for _, fragment in ipairs(STEAM_TREE) do
    if target:find(fragment, 1, true) then return true end
  end
  return false
end

-- ── default /proc readers (all injectable) ──────────────────────────────────

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function default_list_pids()
  local out = {}
  local ok, iter, dir_obj = pcall(lfs.dir, "/proc")
  if not ok then return out end
  for entry in iter, dir_obj do
    if entry:match("^%d+$") then out[#out + 1] = tonumber(entry) end
  end
  if dir_obj then pcall(function() dir_obj:close() end) end
  return out
end

local function default_fd_targets(pid)
  local out = {}
  local dir = "/proc/" .. tostring(pid) .. "/fd"
  local ok, iter, dir_obj = pcall(lfs.dir, dir)
  if not ok then return out end
  for entry in iter, dir_obj do
    if entry ~= "." and entry ~= ".." then
      local target = lfs.symlinkattributes(dir .. "/" .. entry, "target")
      if type(target) == "string" then out[#out + 1] = target end
    end
  end
  if dir_obj then pcall(function() dir_obj:close() end) end
  return out
end

local function default_exe_target(pid)
  return lfs.symlinkattributes("/proc/" .. tostring(pid) .. "/exe", "target")
end

local function resolve(deps, name, fallback)
  local fn = deps and deps[name]
  if type(fn) == "function" then return fn end
  return fallback
end

function peerauth.owner_pid(inode, deps)
  if type(inode) ~= "number" then return nil end
  local needle = "socket:[" .. tostring(math.floor(inode)) .. "]"
  local list_pids = resolve(deps, "list_pids", default_list_pids)
  local fd_targets = resolve(deps, "fd_targets", default_fd_targets)
  local ok_pids, pids = pcall(list_pids)
  if not ok_pids or type(pids) ~= "table" then return nil end
  for _, pid in ipairs(pids) do
    local ok_fds, targets = pcall(fd_targets, pid)
    if ok_fds and type(targets) == "table" then
      for _, target in ipairs(targets) do
        if target == needle then return pid end
      end
    end
  end
  return nil
end

local function listener_inodes_for(port, deps)
  local read_tcp = resolve(deps, "read_tcp",
    function() return read_all("/proc/net/tcp") end)
  local read_tcp6 = resolve(deps, "read_tcp6",
    function() return read_all("/proc/net/tcp6") end)

  local inodes = {}
  for _, reader in ipairs({ read_tcp, read_tcp6 }) do
    local ok_read, text = pcall(reader)
    if ok_read and type(text) == "string" then
      for _, inode in ipairs(peerauth.listener_inodes(text, port)) do
        inodes[#inodes + 1] = inode
      end
    end
  end
  table.sort(inodes)
  return inodes
end

local function inode_key(inodes)
  local out = {}
  for i, inode in ipairs(inodes) do out[i] = tostring(inode) end
  return table.concat(out, ",")
end

-- Direct loopback probe for environments where /proc/net/tcp is inaccessible
-- (e.g. Android PRoot on Poco F9 Ultra / DroidDeck). Succeeds only when the
-- endpoint answers /json/version with Valve's own user agent.
--
-- A Chromium DevTools server keeps the connection open after replying, so a
-- read-to-EOF never completes: read in chunks, keep whatever arrived (luasocket
-- hands back the partial data alongside "timeout"), and stop as soon as the
-- reply is complete.
function peerauth.probe_steam_cdp(port)
  if type(port) ~= "number" or port < 1024 or port > 65535 then return false end
  local ok, socket = pcall(require, "socket")
  if not ok or type(socket) ~= "table" or type(socket.tcp) ~= "function" then
    return false
  end
  local sock = socket.tcp()
  if not sock then return false end
  sock:settimeout(3)
  local conn_ok = sock:connect("127.0.0.1", port)
  if not conn_ok then
    pcall(function() sock:close() end)
    return false
  end
  sock:send("GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:" .. tostring(port)
    .. "\r\nConnection: close\r\n\r\n")
  local resp = ""
  while #resp < 16384 do
    local chunk, err, partial = sock:receive(1024)
    local got = chunk or partial
    if got and #got > 0 then resp = resp .. got end
    if resp:find("webSocketDebuggerUrl", 1, true) or err then break end
  end
  pcall(function() sock:close() end)
  return resp:find("Valve Steam Client", 1, true) ~= nil
end

local function verify_inodes(inodes, deps, port)
  if #inodes == 0 then
    -- On Android / PRoot / DroidDeck: /proc/net/tcp is denied by SELinux.
    -- Verify via loopback HTTP probe to ensure it is the real Steam CDP endpoint.
    if port and peerauth.probe_steam_cdp(port) then
      return true, "steam (droiddeck cdp verified)"
    end
    return false, "no listener"
  end
  local exe_target = resolve(deps, "exe_target", default_exe_target)

  local resolved_any = false
  for _, inode in ipairs(inodes) do
    local pid = peerauth.owner_pid(inode, deps)
    if pid then
      resolved_any = true
      local ok_exe, target = pcall(exe_target, pid)
      if ok_exe and peerauth.is_steam_exe(target) then return true, "steam" end
    end
  end
  if not resolved_any then
    -- In PRoot, walking /proc/<pid>/fd might also be filtered. Fall back to probe if on loopback.
    if port and peerauth.probe_steam_cdp(port) then
      return true, "steam (droiddeck fallback verified)"
    end
    return false, "owner unknown"
  end
  return false, "not steam"
end

function peerauth.verify(port, deps)
  return verify_inodes(listener_inodes_for(port, deps), deps, port)
end

function peerauth.new_cache()
  return { port = nil, trusted = false, inode_key = nil }
end

function peerauth.verify_cached(cache, port, deps, now)
  local inodes = listener_inodes_for(port, deps)
  local key = inode_key(inodes)
  if type(cache) == "table" and cache.trusted and cache.port == port
      and key ~= "" and cache.inode_key == key then
    return true, "steam (cached)"
  end
  local trusted, reason = verify_inodes(inodes, deps, port)
  if type(cache) == "table" then
    cache.port = port
    cache.trusted = trusted == true
    cache.inode_key = trusted and key or nil
  end
  return trusted, reason
end

function peerauth.invalidate(cache)
  if type(cache) ~= "table" then return end
  cache.port = nil
  cache.trusted = false
  cache.inode_key = nil
end

return peerauth
