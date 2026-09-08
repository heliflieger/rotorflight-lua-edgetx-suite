local M = {}

local PREF_PATH        = "/SCRIPTS/TOOLS/rfsuite.user/preferences.ini"
-- Reload request file monitored by the dashboard widget via fstat size.
-- Uses a rotating byte counter (1..32 bytes) so changes are reliably detected
-- where fstat is available even without an RTC or when the INI byte-size doesn't change,
-- without ever consuming or deleting the file (which breaks multi-reader and drops armed events).
local RELOAD_REQ_PATH  = "/SCRIPTS/TOOLS/rfsuite.user/reload.req"

local cachedModelPreferences = nil

local function logD(fmt, ...)
  local L = _G.rfsuite and _G.rfsuite.Log
  if L and type(L.emitf) == "function" then
    L.emitf("rfsuite.reload", "debug", fmt, ...)
  end
end

local function getModelPreferences()
  if cachedModelPreferences then
    return cachedModelPreferences
  end
  if _G.rfsuite and _G.rfsuite.require then
    cachedModelPreferences = _G.rfsuite.require("lib/model_preferences.lua")
    return cachedModelPreferences
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      cachedModelPreferences = mod
      return cachedModelPreferences
    end
  end
  return nil
end

local function bumpReloadCounter(userRoot)
  local MP = getModelPreferences()
  if MP and type(MP.bumpReloadCounter) == "function" then
    MP.bumpReloadCounter(userRoot)
    return
  end

  local targetPath = userRoot and (userRoot .. "/reload.req") or RELOAD_REQ_PATH
  local prevN = 0
  local n = 1
  if type(fstat) == "function" then
    local ok, info = pcall(fstat, targetPath)
    if ok and type(info) == "table" then
      prevN = (info.size or 0)
      n = (prevN % 32) + 1
    end
  end
  local f = io.open(targetPath, "w")
  if f then
    io.write(f, string.rep("x", n))
    io.close(f)
    logD("Preferences.bumpReloadCounter: wrote %d bytes (was %d) to %s", n, prevN, targetPath)
  else
    logD("Preferences.bumpReloadCounter: FAILED to open %s for write", targetPath)
  end
end

-- How much is asked for per io.read() call. It is a chunk size, not a limit: the reader
-- below keeps going until the file ends.
local READ_CHUNK = 2048

local function trim(s)
  local asString = tostring(s or "")
  asString = string.gsub(asString, "^%s+", "")
  asString = string.gsub(asString, "%s+$", "")
  return asString
end

local function parseValue(v)
  local t = trim(v)
  local lower = string.lower(t)
  if lower == "true" then return true end
  if lower == "false" then return false end
  local n = tonumber(t)
  if n ~= nil then return n end
  return t
end

local function serializeValue(v)
  local vt = type(v)
  if vt == "boolean" then
    return v and "true" or "false"
  end
  if vt == "number" then
    return tostring(v)
  end
  return tostring(v)
end

local function defaultPreferences()
  return {
    general = {
      -- safety & prompts
      save_confirm                 = true,
      save_armed_warning           = true,
      reload_confirm               = true,
      -- preview features
      preview_setup_wizard         = false,
      preview_flight_log           = false,
      -- development
      developer_tools              = false,
      continuous_memory_log        = false,
      show_header_memory           = false,
      enable_serial_debug          = false,
      log_to_card                  = false,
      debug_level                  = "off",
    },
    localizations = {
      -- NOTE: `language` is intentionally not seeded here.
      -- Absence of the key means "auto": system_locale.lua will fall through
      -- to the baked package locale (release builds) or getGeneralSettings()
      -- (source / simulator).  Only set it once the user makes an explicit
      -- choice via Settings › Localization.
      temperature_unit = 0,
      altitude_unit    = 0,
    },
    audio_events = {
      arming_flags = true,
      governor_state = true,
      voltage_alert = true,
      pack_not_full = false,
      pack_not_full_margin = 100,
      pid_profile = true,
      rate_profile = true,
      esc_temperature = false,
      esc_threshold = 90,
      mcu_temperature = false,
      mcu_threshold = 80,
      lq_alert = false,
      lq_warn = 70,
      lq_critical = 50,
      adjustment_events = false,
      fuel_alerts = true,
      battery_profile = true,
      model_announcement = false,
      initial_fuel = true,
    },
    flightlog = {
      -- Off by default, and deliberately so: a suite that starts writing files to every pilot's
      -- card without being asked has made a decision that is the pilot's.
      enabled = false,
      -- An arm shorter than this is a check rather than a flight, and reaches neither the log
      -- nor a battery's cycle count. 0 logs every arm.
      min_seconds = 30,
    },
    dashboard = {
      theme_preflight = "system/default",
      -- Phase overrides on top of the theme above, read only while theme_per_phase is on.
      theme_inflight = "nil",
      theme_postflight = "nil",
      theme_per_phase = false,
      theme_config_target = "system/default",
      connection_guard = true,
    }
  }
end

function M.getPath(safeId)
  local mcuId = safeId
  if not mcuId and type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
    mcuId = _G.rfsuite.session.mcu_id
  end
  local MP = getModelPreferences()
  if MP and type(MP.preferencesPath) == "function" then
    return MP.preferencesPath(mcuId)
  end
  return PREF_PATH
end

-- The one place the defaults are declared. Callers that need them without touching the
-- card -- ui/preferences.lua is one -- ask for them here rather than keeping a copy.
function M.defaults()
  return defaultPreferences()
end

local function loadFileAsString(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  -- io.read() hands back at most the number of bytes asked for and "" once the file is
  -- exhausted, so a single call stops wherever that count lands. Stopping there is not
  -- merely a short read: M.save() writes the whole table back, so everything the parser
  -- never saw is dropped from the file by the next save.
  local parts = {}
  while true do
    local chunk = io.read(f, READ_CHUNK)
    if chunk == nil or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  io.close(f)

  local content = table.concat(parts)
  if content == "" then
    return nil
  end

  return content
end

function M.load()
  local prefs = defaultPreferences()
  local path = M.getPath()
  local content = loadFileAsString(path)
  if not content then
    return prefs, false
  end

  local section = nil
  for line in string.gmatch(content, "[^\r\n]+") do
    local normalized = trim(line)
    if normalized ~= "" and string.sub(normalized, 1, 1) ~= ";" and string.sub(normalized, 1, 1) ~= "#" then
      local sec = string.match(normalized, "^%[(.-)%]$")
      if sec then
        section = trim(sec)
        if prefs[section] == nil then
          prefs[section] = {}
        end
      else
        local k, v = string.match(normalized, "^([^=]+)=(.*)$")
        if k and v and section then
          prefs[section][trim(k)] = parseValue(v)
        end
      end
    end
  end

  return prefs, true
end

-- Writes ALL sections and keys from prefs to the INI file.
-- No field list to maintain — adding a key to prefs automatically persists it.

-- The install carries no directory entries, so /SCRIPTS/TOOLS/rfsuite.user exists on a card
-- only because a file was unpacked into it, and io.open(path, "w") does not create a missing
-- parent. Without this, the first save on such a card fails and every setting the pilot
-- changed is lost with it.
--
-- mkdir() is a bare global of the firmware's filesystem library, not a member of os: there is
-- no os table in this Lua at all, so a guard on os.mkdir can never be true. The shape follows
-- app/pages/logs/graph.lua, which tests fstat() the same way. mkdir() creates one level at a
-- time, so the tools root goes first.
local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  if type(path) ~= "string" or path == "" then return end
  pcall(mkdir, path)
end

local function ensureUserDir(targetPath)
  local userRoot = string.match(targetPath or M.getPath(), "^(.*)/[^/]+$")
  if not userRoot then return end
  local toolsRoot = string.gsub(userRoot, "/rfsuite%.user$", "")
  if toolsRoot ~= "" and toolsRoot ~= userRoot then
    makeDir(toolsRoot)
  end
  makeDir(userRoot)
end

function M.save(prefs)
  local path = M.getPath()
  ensureUserDir(path)

  local f, err = io.open(path, "w")
  if not f then
    logD("Preferences.save: FAILED to open %s for write: %s", path, tostring(err))
    return false, err
  end

  for section, values in pairs(prefs or {}) do
    if type(values) == "table" then
      io.write(f, "[" .. tostring(section) .. "]\n")
      for k, v in pairs(values) do
        io.write(f, tostring(k) .. "=" .. serializeValue(v) .. "\n")
      end
    end
  end

  io.close(f)

  -- Signal the dashboard widget that preferences have changed via rotating
  -- sequence length in reload.req. Multi-reader safe, armed-safe, and independent
  -- of RTC timestamp or INI file size equality.
  local userRoot = string.match(path, "^(.*)/[^/]+$")
  bumpReloadCounter(userRoot)
  logD("Preferences.save: saved to %s", path)

  return true
end

return M
