-- Resolves Steam's CEF remote-debugging port.
--
-- DroidDeck adaptation:
-- In DroidDeck on Android / Poco F9 Ultra, Steam is started by droiddeck-session,
-- which sets BL_CDP_PORT in the environment and writes the port to
-- $BL_LAUNCH_DIR/agent/cdp-port. When ~/.local/share/Steam/.cef-enable-remote-debugging
-- is set, Steam defaults to 8080.
--
-- This module checks:
--   1. BL_CDP_PORT environment variable (set directly by droiddeck-session)
--   2. $BL_LAUNCH_DIR/agent/cdp-port (published by droiddeck-session agent)
--   3. ~/.local/share/Lumen/cef_port (contract file written by slsteam-moon / hooks)
--   4. Fallback 8080 (vanilla Steam / standard CEF remote debugging)
local cefport = {}

cefport.FALLBACK = 8080

function cefport.contract_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return "" end
  return home .. "/.local/share/Lumen/cef_port"
end

function cefport.parse_port(s)
  if type(s) ~= "string" and type(s) ~= "number" then return nil end
  local n = tonumber(s)
  if not n then return nil end
  if n < 1024 or n > 65535 then return nil end
  if n ~= math.floor(n) then return nil end
  return math.floor(n)
end

function cefport.parse_contract(text)
  if type(text) ~= "string" then return nil end
  local first = text:match("^([^\n]*)") or ""
  local port = cefport.parse_port(first)
  if not port then return nil end
  local rest = text:sub(#first + 1)
  local pid, start = rest:match("owner%s+(%d+)%s+(%d+)")
  return {
    port = port,
    pid = pid and math.floor(tonumber(pid)) or nil,
    start = start and math.floor(tonumber(start)) or nil,
  }
end

function cefport.read_proc_stat(pid)
  if type(pid) ~= "number" or pid <= 0 then return nil end
  local f = io.open("/proc/" .. math.floor(pid) .. "/stat", "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

function cefport.stat_start_ticks(line)
  if type(line) ~= "string" then return nil end
  local close = nil
  for i = #line, 1, -1 do
    if line:sub(i, i) == ")" then close = i; break end
  end
  if not close then return nil end
  local field = 3
  for token in line:sub(close + 1):gmatch("%S+") do
    if field == 22 then
      local n = tonumber(token)
      return n and math.floor(n) or nil
    end
    field = field + 1
  end
  return nil
end

function cefport.owner_alive(pid, start, read_stat)
  if type(pid) ~= "number" or type(start) ~= "number" then return false end
  read_stat = read_stat or cefport.read_proc_stat
  local ok, line = pcall(read_stat, pid)
  if not ok or type(line) ~= "string" then return false end
  return cefport.stat_start_ticks(line) == start
end

function cefport.resolve(read_fn, fallback, read_stat)
  fallback = fallback or cefport.FALLBACK

  -- 1. Check DroidDeck BL_CDP_PORT env var
  local env_port = os.getenv("BL_CDP_PORT")
  if env_port and env_port ~= "" then
    local p = cefport.parse_port(env_port)
    if p then return p, true, "droiddeck_env" end
  end

  -- 2. Check DroidDeck agent cdp-port file
  local launch_dir = os.getenv("BL_LAUNCH_DIR")
  if launch_dir and launch_dir ~= "" then
    local agent_port_file = io.open(launch_dir .. "/agent/cdp-port", "r")
    if agent_port_file then
      local content = agent_port_file:read("*l")
      agent_port_file:close()
      local p = cefport.parse_port(content)
      if p then return p, true, "droiddeck_agent" end
    end
  end

  -- 3. Check ~/.local/share/Lumen/cef_port contract file
  read_fn = read_fn or cefport.read_contract
  local ok, content = pcall(read_fn)
  if ok and content then
    local contract = cefport.parse_contract(content)
    if contract then
      if not contract.pid or not contract.start then
        return contract.port, true
      end
      if cefport.owner_alive(contract.pid, contract.start, read_stat) then
        return contract.port, true
      end
      return fallback, false, "stale"
    end
  end

  -- 4. Fallback port (default 8080)
  return fallback, false
end

function cefport.read_contract()
  local path = cefport.contract_path()
  if path == "" then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if type(s) ~= "string" then return nil end
  return (s:gsub("%s+$", ""))
end

return cefport
