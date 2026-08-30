--[[
  Central sensor definition for RFSuite dashboard
  Based on RF2 telemetry sensor schema (4-character names)
  Provides unified mapping for simulator and hardware
]]--

local Sensors = {}
Sensors.sim_search_misses = {}
local Log = nil
do
  local okLoad, chunk = pcall(loadScript, "/SCRIPTS/TOOLS/rfsuite-core/lib/log.lua", "t")
  if okLoad and type(chunk) == "function" then
    local okMod, mod = pcall(chunk)
    if okMod and type(mod) == "table" and type(mod.emit) == "function" then
      Log = mod
    end
  end
end

local SIM_FILE_ALIASES = {
  ["PID#"] = "pid_profile",
  ["RTE#"] = "rate_profile",
  ["BatP"] = "battery_profile",
  ["Bat%"] = "fuel",
  ["SmFt"] = "smartfuel",
  ["SmCp"] = "smartconsumption",
  ["RQly"] = "link",
  ["Vbat"] = "voltage",
  ["Vbec"] = "bec_voltage",
  ["BecV"] = "bec_voltage",
  ["Hspd"] = "rpm",
  ["EscT"] = "temp_esc",
  ["Tesc"] = "temp_esc",
  ["TescT"] = "temp_esc",
  ["TmcuT"] = "temp_mcu",
  ["Thr%"] = "throttle_percent",
  ["Thr"] = "throttle_percent",
  ["Cel#"] = "cell_count",
  ["Alt"] = "altitude",
  ["voltage"] = "voltage",
  ["fuel"] = "fuel",
  ["rpm"] = "rpm",
}

local debugEnabled = false
local loggedSimulatorState = false
local loggedSources = {}
local simValueCache = {}
local SIM_SOURCE_RELOAD_SECONDS = 0.5

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then
      return v / 100
    end
  end
  if os and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function debugLog(key, msg)
  if not debugEnabled then return end
  if key and loggedSources[key] then return end
  if key then loggedSources[key] = true end
  if Log then
    Log.emit("rfsuite.sensors", tostring(msg), "debug", true)
  end
end

local fieldInfoCache = {}
local valueMisses = {}

local function readTelemetryValue(name)
  if type(name) ~= "string" then return nil end
  local getV = _G.getValue
  if type(getV) ~= "function" then return nil end

  local now = nowSeconds()
  if now - (valueMisses[name] or 0) < 1.0 then return nil end

  local getFInfo = _G.getFieldInfo
  if type(getFInfo) == "function" then
    local info = fieldInfoCache[name]
    if not info then
      info = getFInfo(name)
      if type(info) == "table" and info.id ~= nil then
        fieldInfoCache[name] = info
      else
        valueMisses[name] = now
        return nil
      end
    end
  end

  local ok, value = pcall(getV, name)
  if ok and type(value) == "number" then
    return value
  end

  valueMisses[name] = now
  return nil
end

local SIM_SENSOR_PATHS = {
  "/SCRIPTS/TOOLS/rfsuite-core/sim/sensors/",
  "/SCRIPTS/TOOLS/rfsuite.user/sim/sensors/",
  "/SCRIPTS/rfsuite-core/sim/sensors/",
  "SCRIPTS/TOOLS/rfsuite-core/sim/sensors/",
  "/rfsuite-core/sim/sensors/",
  "rfsuite-core/sim/sensors/",
}
local function readSimSensorFile(name, source)
  if type(name) ~= "string" or name == "" then return nil end

  local now = nowSeconds()
  -- Negativ-Cache wieder aktivieren um CPU Last bei fehlenden Dateien zu senken
  if (Sensors.sim_search_misses[name] or 0) > 0 and (now - Sensors.sim_search_misses[name]) < 2.0 then
    return nil
  end

  local function tryReadFile(filePath)
    local cached = simValueCache[filePath]
    if cached then
      if cached.exists then
        local v = cached.v
        -- Führe das gecachte Skript aus, um dynamische Werte (math.random) zu erhalten
        if cached.chunk then
          local ok, result = pcall(cached.chunk)
          if ok and type(result) == "number" then
            v = result
          end
        end
        
        -- Source-Reload deutlich drosseln, um Telemetrie-Flapping im Simulator zu vermeiden.
        if (now - cached.t) > SIM_SOURCE_RELOAD_SECONDS then
          -- Drosselung: Maximal ein Skript-Reload pro Tick, um CPU-Spitzen zu vermeiden
          if Sensors.sim_last_reload ~= now then
            Sensors.sim_last_reload = now
            local chunk = loadScript(filePath, "t")
            if chunk then
              cached.chunk = chunk
            else
              -- Datei wurde evtl. gelöscht
              local f = io.open(filePath, "r")
              if not f then cached.exists = false end
              if f then io.close(f) end
            end
            cached.t = now
          end
        end
        return v, true
      else
        -- Datei existierte beim letzten Check nicht, 2 Sekunden lang ignorieren
        if (now - cached.t) <= 2.0 then
          return nil, false
        end
      end
    end

    -- Erst mit io.open prüfen ob die Datei existiert um -E- Log-Spam von loadScript zu vermeiden
    local f = io.open(filePath, "r")
    if not f then 
      simValueCache[filePath] = { t = now, exists = false, v = nil }
      return nil, false 
    end
    io.close(f)

    -- Datei existiert, nun als Lua-Skript ausführen und cachen
    local chunk = loadScript(filePath, "t")
    local v = nil
    if chunk then
      local ok, result = pcall(chunk)
      if ok and type(result) == "number" then
        v = result
      end
    end
    simValueCache[filePath] = { t = now, exists = true, v = v, chunk = chunk }
    return v, true
  end

  -- 1. Bereits erfolgreichen Pfad probieren (O(1))
  -- ... (rest of the logic)


  local activePath = Sensors.sim_active_paths and Sensors.sim_active_paths[name]
  if activePath then
    local v, hit = tryReadFile(activePath)
    if hit then return v end
  end

  -- 2. Kandidatenliste aufbauen
  -- Drosselung: Nur ein intensiver Suchlauf nach fehlenden Dateien pro Tick, um CPU-Limit zu vermeiden
  if Sensors.sim_last_search == now then
    return nil
  end
  Sensors.sim_last_search = now

  local candidates = {}
  local seenCands = {}
  local function addCandidate(value)
    if type(value) ~= "string" or value == "" or seenCands[value] then return end
    candidates[#candidates + 1] = value
    seenCands[value] = true
  end

  addCandidate(name)
  addCandidate(string.lower(name))
  if source then
    addCandidate(source)
    addCandidate(string.lower(source))
    addCandidate(SIM_FILE_ALIASES[source])
  end
  addCandidate(SIM_FILE_ALIASES[name])

  -- 3. In Pfaden suchen
  for p = 1, #SIM_SENSOR_PATHS do
    local base = SIM_SENSOR_PATHS[p]
    for i = 1, #candidates do
      local filePath = base .. candidates[i] .. ".lua"
      local v, hit = tryReadFile(filePath)
      if hit and v ~= nil then
        Sensors.sim_active_paths = Sensors.sim_active_paths or {}
        Sensors.sim_active_paths[name] = filePath
        debugLog("sim-hit:" .. name, "sim file hit " .. filePath .. " = " .. tostring(v))
        return v
      end
    end
  end

  -- Füge Jitter hinzu, damit nicht alle Sensoren im exakt gleichen Tick ablaufen
  Sensors.sim_search_misses[name] = now + (math.random() * 2.0)
  return nil
end

local function normalizeSimValue(name, value)
  if type(value) ~= "number" then return value end
  
  -- Wenn der Wert bereits Nachkommastellen hat, ist er bereits skaliert (z.B. return 25.2)
  if value % 1 ~= 0 then return value end
  
  -- Wenn es ein Integer ist (z.B. return 2520), skalieren wir ihn anhand der Metadaten
  local meta = Sensors.getMetadata(name)
  local prec = meta and tonumber(meta.prec) or 0
  if prec > 0 then
    return value / (10 ^ prec)
  end
  
  return value
end

-- Sensor definitions: 4-char name → metadata
-- ... (rest of Sensors.map)
Sensors.map = {
-- ... (rest of metadata)
  -- Flight Control
  ARM  = { label = "Arm Flags", unit = "raw", prec = 0, fallback = 0 },
  Gov  = { label = "Governor", unit = "raw", prec = 0, fallback = 0 },

  -- Power System
  Vbat = { label = "Main Voltage", unit = "V", prec = 2, fallback = 24.2 },
  Curr = { label = "Current", unit = "A", prec = 2, fallback = 0 },
  Capa = { label = "Consumption", unit = "mAh", prec = 0, fallback = 0 },
  ["Bat%"] = { label = "Fuel", unit = "%", prec = 0, fallback = 100 },
  Vbec = { label = "BEC Voltage", unit = "V", prec = 2, fallback = 8.0 },
  SmFt = { label = "Smart Fuel", unit = "%", prec = 0, fallback = 100 },
  SmCp = { label = "Smart Consumption", unit = "mAh", prec = 0, fallback = 0 },

  -- Flight Profiles
  ["PID#"] = { label = "PID Profile", unit = "raw", prec = 0, fallback = 1 },
  ["RTE#"] = { label = "Rate Profile", unit = "raw", prec = 0, fallback = 1 },
  BatP = { label = "Battery Profile", unit = "raw", prec = 0, fallback = 1 },

  -- Speeds / RPM
  Hspd = { label = "Headspeed", unit = "rpm", prec = 0, fallback = 0 },
  Tspd = { label = "Tailspeed", unit = "rpm", prec = 0, fallback = 0 },
  RQly = { label = "Link Quality", unit = "dB", prec = 0, fallback = 0 },

  -- Attitude
  Ptch = { label = "Pitch", unit = "°", prec = 1, fallback = 0 },
  Roll = { label = "Roll", unit = "°", prec = 1, fallback = 0 },
  Yaw  = { label = "Yaw", unit = "°", prec = 1, fallback = 0 },

  -- Temperature
  TescT = { label = "ESC Temp", unit = "°C", prec = 0, fallback = 25 },
  TmcuT = { label = "MCU Temp", unit = "°C", prec = 0, fallback = 25 },

  -- Other
  ["Thr%"] = { label = "Throttle %", unit = "%", prec = 0, fallback = 0 },
  Alt  = { label = "Altitude", unit = "m", prec = 1, fallback = 0 },
  ["Cel#"] = { label = "Cell Count", unit = "raw", prec = 0, fallback = 6 },
}

-- Aliases: dashboard/internal names → 4-char sensor names
Sensors.aliases = {
  voltage = "Vbat",
  rpm = "Hspd",
  link = "RQly",
  fuel = "Bat%",
  smartfuel = "SmFt",
  smartconsumption = "SmCp",
  consumption = "Capa",
  current = "Curr",
  bec_voltage = "Vbec",
  pid_profile = "PID#",
  rate_profile = "RTE#",
  battery_profile = "BatP",
  battery_cell_count = "Cel#",
  armdisableflags = "ARMD",
  throttle_percent = "Thr%",
  altitude = "Alt",
  pitch = "Ptch",
  roll = "Roll",
  yaw = "Yaw",
  armflags = "ARM",
  governor = "Gov",
}

Sensors.search_paths = {
  voltage = { "Vbat", "VFAS", "voltage", "VBAT" },
  fuel = { "Bat%", "Fuel", "fuel" },
  smartfuel = { "SmFt", "Smart Fuel", "smartfuel", "Bat%", "fuel" },
  rpm = { "Hspd", "RPM", "rpm" },
  link = { "RQly", "LQ", "Link", "link_quality", "1RSS", "2RSS" },
  current = { "Curr", "Current", "current" },
  bec_voltage = { "Vbec", "BecV", "BECV", "bec_voltage" },
  pid_profile = { "PID#", "PIDP", "PidP", "PID Profile", "PID" },
  rate_profile = { "RTE#", "RateP", "RTPR", "Rate Profile", "Rate" },
  battery_profile = { "BAT#", "BatP", "BatProfile", "Battery Profile" },
  battery_cell_count = { "Cel#", "cell_count", "cells", "Cells", "battery_cell_count" },
  throttle_percent = { "Thr%", "Thr", "Throttle", "throttle", "throttle_percent" },
  altitude = { "Alt", "Altitude", "altitude" },
  pitch = { "Ptch", "Pitch", "pitch" },
  roll = { "Roll", "roll" },
  yaw = { "Yaw", "yaw" },
  armflags = { "ARM", "Arm", "ARMF", "ArmF", "armflags" },
  armdisableflags = { "ARMD", "ArmD", "arming_disable_flags", "armdisableflags" },
  smartconsumption = { "SmCp", "Smart Consumption", "smartconsumption", "Capa", "consumption" },
  governor = { "Gov", "Governor", "governor" },
  temp_esc = { "EscT", "Tesc", "ESC_TMP", "TescT", "ESC Temp", "temp_esc" },
  temp_mcu = { "Tmcu", "TmcuT", "temp_mcu" }
}

-- Detect if running in simulator
local isSimulatorCached = nil
function Sensors.isSimulator()
  if isSimulatorCached ~= nil then return isSimulatorCached end
  
  -- EdgeTX 2.10+
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, info = pcall(system.getVersion)
    if ok and type(info) == "table" and info.simulation then
      isSimulatorCached = true
      return true
    end
  end

  -- Fallback für ältere Versionen
  if getVersion then
    local ok, _, fw = pcall(getVersion)
    if ok and type(fw) == "string" then
      isSimulatorCached = (string.sub(fw, -4) == "simu")
      return isSimulatorCached
    end
  end
  isSimulatorCached = false
  return false
end

-- Resolve alias to 4-char sensor name
-- Memoised: the answer depends only on the source string and on Sensors.map / Sensors.aliases,
-- both of which are written once as literals and only read afterwards --
-- and getValue resolves a name on every read -- about twenty-five of them per background pass of
-- the dashboard widget. `false` records a name that resolves to nothing, so a miss is answered
-- from the table instead of running the pattern again.
local resolvedNames = {}

local function resolveNameUncached(source)
  if type(source) ~= "string" then return nil end
  local baseSource, suffix = string.match(source, "^(.-)([+-])$")
  if baseSource and suffix then
    if Sensors.aliases[baseSource] then
      return Sensors.aliases[baseSource] .. suffix
    end
    if Sensors.map[baseSource] then
      return baseSource .. suffix
    end
  end
  if Sensors.aliases[source] then
    return Sensors.aliases[source]
  end
  if Sensors.map[source] then
    return source
  end
  return nil
end

function Sensors.resolveName(source)
  if type(source) ~= "string" then return nil end
  local memo = resolvedNames[source]
  if memo ~= nil then
    if memo == false then return nil end
    return memo
  end
  local resolved = resolveNameUncached(source)
  resolvedNames[source] = (resolved == nil) and false or resolved
  return resolved
end

-- Get sensor metadata by 4-char name or alias
function Sensors.getMetadata(source)
  local name = Sensors.resolveName(source)
  if name then
    local meta = Sensors.map[name]
    if meta then
      return meta
    end

    local baseName = string.match(name, "^(.-)[+-]$")
    if baseName then
      return Sensors.map[baseName]
    end
  end
  return nil
end

function Sensors.getValue(source)
  if type(source) ~= "string" then return nil end

  if not loggedSimulatorState then
    loggedSimulatorState = true
    debugLog(nil, "simulator detected = " .. tostring(Sensors.isSimulator()))
  end

  local resolved = Sensors.resolveName(source)

  -- In simulator mode we prefer file-based values so widget updates follow the sensor tool.
  if Sensors.isSimulator() then
    if resolved then
      local simValue = readSimSensorFile(resolved, source)
      if type(simValue) == "number" then
        local normalized = normalizeSimValue(resolved, simValue)
        if debugEnabled then debugLog("sim-use:" .. source, "using sim value " .. resolved .. " = " .. tostring(normalized)) end
        return normalized
      end
    end

    local simDirect = readSimSensorFile(source, source)
    if type(simDirect) == "number" then
      local normalized = normalizeSimValue(source, simDirect)
      if debugEnabled then debugLog("sim-direct-use:" .. source, "using sim direct value " .. source .. " = " .. tostring(normalized)) end
      return normalized
    end

    local paths = Sensors.search_paths[source]
    if paths then
      for i = 1, #paths do
        local simPathValue = readSimSensorFile(paths[i], source)
        if type(simPathValue) == "number" then
          local normalized = normalizeSimValue(paths[i], simPathValue)
          if debugEnabled then debugLog("sim-search-hit:" .. source, "using sim search value " .. paths[i] .. " = " .. tostring(normalized)) end
          return normalized
        end
      end
    end
    
    -- WICHTIG: Im Simulator kein Hardware-Fallback!
    return nil
  end

  local activePath = Sensors.active_paths and Sensors.active_paths[source]
  if activePath then
    local val = readTelemetryValue(activePath)
    if type(val) == "number" then
      if debugEnabled then debugLog("telemetry-hit-cached:" .. source, "hit " .. activePath .. " = " .. tostring(val)) end
      return val
    end
  end

  local now = nowSeconds()
  Sensors.search_misses = Sensors.search_misses or {}
  if now - (Sensors.search_misses[source] or 0) < 2.0 then
    return nil
  end

  local paths = Sensors.search_paths[source]
  if paths then
    for i = 1, #paths do
      local val = readTelemetryValue(paths[i])
      if type(val) == "number" then
        Sensors.active_paths = Sensors.active_paths or {}
        Sensors.active_paths[source] = paths[i]
        if debugEnabled then debugLog("telemetry-hit:" .. source, "hit " .. paths[i] .. " = " .. tostring(val)) end
        return val
      end
    end
  end

  if resolved then
    local value = readTelemetryValue(resolved)
    if type(value) == "number" then
      Sensors.active_paths = Sensors.active_paths or {}
      Sensors.active_paths[source] = resolved
      if debugEnabled then debugLog("telemetry-hit:" .. source, "telemetry hit " .. resolved .. " = " .. tostring(value)) end
      return value
    end
  end

  local direct = readTelemetryValue(source)
  if type(direct) == "number" then
    Sensors.active_paths = Sensors.active_paths or {}
    Sensors.active_paths[source] = source
    if debugEnabled then debugLog("telemetry-direct-hit:" .. source, "telemetry direct hit " .. source .. " = " .. tostring(direct)) end
    return direct
  end

  Sensors.search_misses[source] = now
  return nil
end

-- Get all 4-char sensor names (for tool enumeration)
function Sensors.getAllNames()
  local names = {}
  for name, _ in pairs(Sensors.map) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return Sensors
