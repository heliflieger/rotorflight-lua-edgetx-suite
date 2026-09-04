local M = {}

local PREF_PATH        = "/SCRIPTS/TOOLS/rfsuite.user/preferences.ini"
-- Sentinel written on every save so the widget can detect a change even when
-- the RTC is absent (timestamp frozen) or the new INI is the same byte-size
-- (e.g. swapping between two themes whose path strings have the same length).
-- The widget reads and then removes this file, so it is never left on the card.
local RELOAD_REQ_PATH  = "/SCRIPTS/TOOLS/rfsuite.user/reload.req"

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
      pid_profile = true,
      rate_profile = true,
      esc_temperature = false,
      esc_threshold = 90,
      adjustment_events = false,
      fuel_alerts = true,
      battery_profile = true,
      model_announcement = false,
      initial_fuel = true,
    },
    dashboard = {
      theme_preflight = "system/default",
      theme_inflight = "system/default",
      theme_postflight = "system/default",
      theme_config_target = "system/default",
      connection_guard = true,
    }
  }
end

function M.getPath()
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
  local content = loadFileAsString(PREF_PATH)
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

local function ensureUserDir()
  local userRoot = string.match(PREF_PATH, "^(.*)/[^/]+$")
  if not userRoot then return end
  local toolsRoot = string.gsub(userRoot, "/rfsuite%.user$", "")
  if toolsRoot ~= "" and toolsRoot ~= userRoot then
    makeDir(toolsRoot)
  end
  makeDir(userRoot)
end

function M.save(prefs)
  ensureUserDir()

  local f, err = io.open(PREF_PATH, "w")
  if not f then return false, err end

  for section, values in pairs(prefs or {}) do
    if type(values) == "table" then
      io.write(f, "[" .. tostring(section) .. "]\n")
      for k, v in pairs(values) do
        io.write(f, tostring(k) .. "=" .. serializeValue(v) .. "\n")
      end
    end
  end

  io.close(f)

  -- Signal the dashboard widget that preferences have changed. The fstat-based
  -- stamp (size + mtime) is unreliable on radios without a battery-backed RTC
  -- (mtime stays frozen at 2000-01-01) and fails when the new INI is the same
  -- byte-length as the old one.  Writing a tiny sentinel that the widget can
  -- detect — regardless of RTC state or theme-name length — is the robust
  -- alternative.  The widget removes the file after consuming it, so it is
  -- never left around after a reload.
  local sf = io.open(RELOAD_REQ_PATH, "w")
  if sf then
    io.write(sf, "1")
    io.close(sf)
  end

  return true
end

return M
