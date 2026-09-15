-- Per-command response cache for the MSP queue.
--
-- A page re-reads everything it shows on every entry: Common.resetPageState clears ui.loaded
-- and ui.runtime, so ensureLoaded reads unconditionally and the value the page had a moment
-- ago is issued again. The tool is the only writer while it is on screen -- widgets do not run
-- at all behind a fullscreen script -- so most of those round-trips answer a question that was
-- already answered.
--
-- Pages already compute the validity key this needs. buildSessionSignature() compares the live
-- profile (and, per page, the governor mode or a battery source) and re-reads only when it
-- changes. What is missing is that the key is thrown away on close together with ui.runtime,
-- so it can never say "nothing changed" across a page boundary. This module keeps it.
--
-- ## Nothing is cached unless it is listed here, with the key that makes it valid
--
-- The default is no caching, deliberately: a config tool showing a stale value is worse than
-- one that reads twice, so every entry below is a decision that can be reviewed on its own.
-- The key kind says what invalidates the entry beyond the two events that invalidate all of
-- them (a disconnect, and any write the tool issues).
--
--   connection   the value changes only when someone writes it or the board changes
--   pid_profile  the value is scoped to the live PID profile
--   rate_profile the value is scoped to the live rate profile
--
-- MSP_STATUS is deliberately NOT here: it carries arming flags, cycle time and the live
-- profile, so it is exactly the read a page should keep making.

local Cache = {}

local Sensors = nil

local CONNECTION = "connection"
local PID_PROFILE = "pid_profile"
local RATE_PROFILE = "rate_profile"

local CACHEABLE = {
  [10] = CONNECTION,   -- MSP_NAME
  [36] = CONNECTION,   -- MSP_FEATURE_CONFIG
  [90] = CONNECTION,   -- MSP_ADVANCED_CONFIG
  [112] = PID_PROFILE, -- MSP_PID_TUNING
}

-- The store hangs off the global root rather than off this chunk. lib/require.lua memoizes by
-- path and would hand every caller the same table -- but it is not guaranteed to be installed,
-- and the fallback path loads the file again. Two instances would mean the queue fills one
-- cache while a disconnect clears the other, which is the one failure this module must not
-- have.
_G.rfsuite = _G.rfsuite or {}
_G.rfsuite.mspResponseCache = _G.rfsuite.mspResponseCache or {}

local function entryStore()
  return _G.rfsuite.mspResponseCache
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then
    return nil
  end
  local ok, mod = pcall(chunk)
  if not ok then
    return nil
  end
  return mod
end

local Profile = nil

local function ensureProfileDep()
  if Profile == nil then
    Profile = loadModule("lib/profile.lua") or false
  end
  return (Profile ~= false and Profile) or nil
end

--- The key that makes a cached answer to `command` still valid, or nil when it is not cached.
--
-- Nil rather than a default, and the distinction is the whole point: this value is a CACHE
-- KEY. A default is a key that never moves, so a reply stored under it stays "valid" across a
-- profile switch and is then served for the wrong profile. An unknown profile therefore costs
-- a round trip -- Cache.get and Cache.put both treat a nil key as not cacheable -- instead of
-- costing a wrong answer.
function Cache.keyFor(command)
  local kind = CACHEABLE[command]
  if kind == nil then
    return nil
  end
  local profileHelper = ensureProfileDep()
  if kind == PID_PROFILE then
    local profile = profileHelper and profileHelper.getActivePidProfile()
    if profile == nil then return nil end
    return PID_PROFILE .. "=" .. tostring(profile)
  end
  if kind == RATE_PROFILE then
    local profile = profileHelper and profileHelper.getActiveRateProfile()
    if profile == nil then return nil end
    return RATE_PROFILE .. "=" .. tostring(profile)
  end
  return CONNECTION
end

--- The stored reply buffer for `command`, or nil when there is none or its key has moved on.
function Cache.get(command)
  local key = Cache.keyFor(command)
  if key == nil then
    return nil
  end
  local entry = entryStore()[command]
  if entry == nil or entry.key ~= key then
    return nil
  end
  return entry.buf
end

--- Keep a reply. Ignored for a command that is not listed above.
function Cache.put(command, buf)
  local key = Cache.keyFor(command)
  if key == nil or type(buf) ~= "table" then
    return false
  end
  local copy = {}
  for i = 1, #buf do
    copy[i] = buf[i]
  end
  entryStore()[command] = { key = key, buf = copy }
  return true
end

--- Drop everything. Called on a disconnect and after any write the tool issues.
--
-- A write is not matched to the command it invalidates on purpose: the write command number
-- is a different one from the read (11 against 10 for the craft name), the mapping lives in
-- the api/ modules rather than in the queue, and a Save is rare enough that dropping the whole
-- cache costs nothing next to getting the mapping subtly wrong.
function Cache.clear()
  local store = entryStore()
  for k in pairs(store) do
    store[k] = nil
  end
end

return Cache
