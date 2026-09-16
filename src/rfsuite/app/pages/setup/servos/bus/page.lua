local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local Common = nil
local MspRuntime = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

local lastChangeTime = 0
local liveUpdateInterval = 0.20 -- 200 ms

local function writeU8(payload, val)
  payload[#payload + 1] = val % 256
end

local function writeU16(payload, val)
  payload[#payload + 1] = val % 256
  payload[#payload + 1] = math.floor(val / 256) % 256
end

local function writeS16(payload, val)
  local unsigned = val
  if val < 0 then unsigned = val + 65536 end
  writeU16(payload, unsigned)
end

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if os and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  inOverride = false,
  selectedServoIndex = 0, -- 0-indexed for editing (0 to 15), defaults to 0
  config = {
    servos = {}
  },
  mixerConfig = {
    swash_type = 0,
    tail_rotor_mode = 0
  },
  servoBusEnabled = false,
  servoCount = 0,
  servoLoaded = {},
  apiData = {},
  runtime = {
    readPending = false,
    requestRebuild = nil
  }
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_servos") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil
    }
  end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_servos_bus) ~= "table" then
    session.setup_servos_bus = {}
  end
  return session.setup_servos_bus
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end

  ui.servoCount = rcConfig.servoCount or 0
  ui.servoLoaded = ui.servoLoaded or {}
  ui.servoBusEnabled = rcConfig.servoBusEnabled or false
  ui.mixerConfig.swash_type = rcConfig.swash_type or 0
  ui.mixerConfig.tail_rotor_mode = rcConfig.tail_rotor_mode or 0

  if type(rcConfig.servos) == "table" then
    ui.config.servos = rcConfig.servos
  end
  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end

  rcConfig.servoCount = ui.servoCount
  rcConfig.servoBusEnabled = ui.servoBusEnabled
  rcConfig.swash_type = ui.mixerConfig.swash_type
  rcConfig.tail_rotor_mode = ui.mixerConfig.tail_rotor_mode
  rcConfig.servos = ui.config.servos
  rcConfig.apiData = ui.apiData
end

local function getServoTitle(i18n, idx)
  local swashType = ui.mixerConfig.swash_type or 0
  local tailMode = ui.mixerConfig.tail_rotor_mode or 0

  if swashType == 1 then -- DIRECT
    if tailMode == 0 and idx == 4 then
      return pageText(i18n, "tail", "TAIL")
    end
  elseif swashType >= 2 and swashType <= 4 then -- CPPM
    if idx == 1 then return pageText(i18n, "cyc_pitch", "CYC.PITCH") end
    if idx == 2 then return pageText(i18n, "cyc_left", "CYC.LEFT") end
    if idx == 3 then return pageText(i18n, "cyc_right", "CYC.RIGHT") end
    if tailMode == 0 and idx == 4 then
      return pageText(i18n, "tail", "TAIL")
    end
  elseif swashType == 5 or swashType == 6 then -- FPPM
    if tailMode == 0 and idx == 4 then
      return pageText(i18n, "tail", "TAIL")
    end
  end

  return pageText(i18n, "servo", "Servo") .. " " .. idx
end

local function setOverride(enabled)
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return end

  local session = getSession()
  local apiVersion = session and session.apiVersion
  local isAtLeast1209 = ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, {12, 0, 9})

  local val = enabled and 0 or 2001
  local lo = val % 256
  local hi = math.floor(val / 256) % 256

  if isAtLeast1209 then
    queue:add({
      command = 196,
      payload = { lo, hi },
      isWrite = true,
      processReply = function() end
    })
  else
    for i = 8, 23 do
      queue:add({
        command = 193,
        payload = { i, lo, hi },
        isWrite = true,
        processReply = function() end
      })
    end
  end
end

--- The firmware speaks about servos in TWO index spaces, and this page addresses both.
---
--- `servoParams()` is indexed 0 .. MAX_SUPPORTED_SERVOS-1, with the bus servos starting at
--- BUS_SERVO_OFFSET. MSP_SET_SERVO_CENTER and MSP_GET_SERVO_CONFIG take that index.
---
--- MSP_SERVO_CONFIGURATIONS and MSP_SET_SERVO_CONFIGURATION take a PACKED index instead: the
--- configured PWM servos first, then all BUS_SERVO_CHANNELS bus servos, with the unconfigured
--- PWM slots between them skipped. So bus servo n is packed index (pwm count + n), not
--- (BUS_SERVO_OFFSET + n) -- the two agree only on a board that configures all eight PWM
--- outputs as servos.
---
--- Everything this page holds in `ui.config.servos` is keyed by the RAW index, and the packed
--- index is derived at the one place that needs it.
local BUS_SERVO_CHANNELS = 18
local BUS_SERVO_OFFSET = 8

--- How many PWM servos the flight controller has. MSP_STATUS reports the PACKED total, i.e.
--- getServoCount() + BUS_SERVO_CHANNELS whenever bus servos are configured, so the PWM count is
--- the difference.
local function pwmServoCount()
  local total = tonumber(ui.servoCount) or 0
  if ui.servoBusEnabled == true and total > BUS_SERVO_CHANNELS then
    return total - BUS_SERVO_CHANNELS
  end
  return total
end

--- The raw servoParams index of this page's servo n.
local function rawServoIndex(busIdx)
  return BUS_SERVO_OFFSET + busIdx
end

--- The packed index of this page's servo n, for the two commands that speak that space.
local function packedServoIndex(busIdx)
  return pwmServoCount() + busIdx
end

local function triggerLiveWrite()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return end

  local servoIdx = ui.selectedServoIndex
  if not servoIdx then return end

  local config = ui.config.servos and ui.config.servos[rawServoIndex(servoIdx)]
  if not config then return end

  local mid = math.floor(config.mid or 1500)

  local session = getSession()
  local apiVersion = session and session.apiVersion
  local isIndexed = ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, {12, 0, 9})

  -- MSP_SET_SERVO_CENTER takes the RAW servoParams index, unlike the configuration write below.
  local writeIndex = rawServoIndex(servoIdx)

  if isIndexed then
    local lo = mid % 256
    local hi = math.floor(mid / 256) % 256
    queue:add({
      command = 213,
      payload = { writeIndex, lo, hi },
      isWrite = true,
      processReply = function() end
    })
  else
    local reverse = tonumber(config.reverse) or 0
    local geometry = tonumber(config.geometry) or 0
    local flags = 0
    if reverse == 0 and geometry == 0 then
      flags = 0
    elseif reverse == 1 and geometry == 0 then
      flags = 1
    elseif reverse == 0 and geometry == 1 then
      flags = 2
    elseif reverse == 1 and geometry == 1 then
      flags = 3
    end

    local payload = {}
    writeU8(payload, writeIndex)
    writeU16(payload, mid)
    writeS16(payload, config.min or 0)
    writeS16(payload, config.max or 0)
    writeU16(payload, config.scaleNeg or 500)
    writeU16(payload, config.scalePos or 500)
    writeU16(payload, 333) -- Rate is mapped to 333
    writeU16(payload, config.speed or 0)
    writeU16(payload, flags)

    queue:add({
      command = 212,
      payload = payload,
      isWrite = true,
      processReply = function() end
    })
  end
end

--- Whether this firmware has the per-servo read.
---
--- MSP_GET_SERVO_CONFIG (125) arrived in API 12.09. Below it the whole-table
--- MSP_SERVO_CONFIGURATIONS is the only read there is.
local PAGED_READ_API = {12, 0, 9}

local function hasPagedServoReads()
  local session = getSession()
  local apiVersion = session and session.apiVersion
  if not apiVersion or apiVersion == "" or tostring(apiVersion) == "0" then
    return false
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, PAGED_READ_API)
end

--- Reads one servo's record with MSP_GET_SERVO_CONFIG (125), which takes the RAW index.
---
--- The whole-table MSP_SERVO_CONFIGURATIONS is not used from API 12.09. With bus servos
--- configured its reply is 1 + (getServoCount() + BUS_SERVO_CHANNELS) * 16 bytes -- 353 with four
--- PWM servos, 417 with eight -- while the shared telemetry response buffer the CRSF path
--- serialises into is MSP_TLM_OUTBUF_SIZE = 320 bytes and sbufWriteU8 has no bound check, so the
--- reply is written past the end of a static buffer. Over USB that buffer is much larger and the
--- command is safe there, which is why this is not visible from the configurator.
local function queueServoRead(busIdx, onDone)
  local function done(ok)
    if type(onDone) == "function" then onDone(ok) end
  end

  if not hasPagedServoReads() then
    done(false)
    return false
  end

  busIdx = tonumber(busIdx)
  if not busIdx or busIdx < 0 then
    done(false)
    return false
  end

  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    done(false)
    return false
  end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    done(false)
    return false
  end

  local GetServoConfigApi = loadModule("tasks/msp/api/get_servo_config.lua")
  if not GetServoConfigApi then
    done(false)
    return false
  end

  local raw = rawServoIndex(busIdx)

  queue:add({
    command = GetServoConfigApi.command,
    payload = { raw },
    isWrite = false,
    simulatorResponse = GetServoConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = GetServoConfigApi.parse(buf)
      local rec = parsed and parsed.servo_config
      if rec then
        local cfg = {
          mid = rec.mid,
          min = rec.min,
          max = rec.max,
          scaleNeg = rec.rneg,
          scalePos = rec.rpos,
          rate = rec.rate,
          speed = rec.speed,
          flags = rec.flags
        }
        cfg.reverse = (cfg.flags == 1 or cfg.flags == 3) and 1 or 0
        cfg.geometry = (cfg.flags == 2 or cfg.flags == 3) and 1 or 0
        ui.config.servos = ui.config.servos or {}
        ui.config.servos[raw] = cfg
        ui.servoLoaded[busIdx] = true
      end
      done(rec ~= nil)
    end,
    errorHandler = function()
      done(false)
    end
  })

  return true
end

--- What the whole-table read used to do at the end of a load, for one servo instead of all.
local function finishServoLoad(ok)
  ui.runtime.readPending = false
  ui.loading = false
  ui.dirty = false
  ui.progress = 100
  ui.loaded = true
  saveToSession()
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function queueServosRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  local MixerConfigApi = loadModule("tasks/msp/api/mixer_config.lua")
  local StatusApi = loadModule("tasks/msp/api/status.lua")
  local SerialConfigApi = loadModule("tasks/msp/api/serial_config.lua")
  local ServoConfigsApi = loadModule("tasks/msp/api/servo_configurations.lua")

  -- Step 1: Read MIXER_CONFIG
  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if parsed then
        ui.mixerConfig.swash_type = parsed.swash_type or 0
        ui.mixerConfig.tail_rotor_mode = parsed.tail_rotor_mode or 0
      end

      ui.progress = 25
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      -- Step 2: Read STATUS
      queue:add({
        command = StatusApi.command,
        simulatorResponse = StatusApi.simulatorResponse,
        processReply = function(self, buf)
          local parsed = StatusApi.parse(buf)
          if parsed then
            ui.servoCount = parsed.servo_count or 0
          end

          ui.progress = 50
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end

          -- Step 3: Read SERIAL_CONFIG
          queue:add({
            command = SerialConfigApi.command,
            simulatorResponse = SerialConfigApi.simulatorResponse,
            processReply = function(self, buf)
              local parsed = SerialConfigApi.parse(buf)
              if parsed then
                local fbus_mask = 524288
                local sbus_mask = 262144
                local found = false
                for i = 1, 12 do
                  local mask = parsed["port_" .. i .. "_function_mask"]
                  if mask == fbus_mask or mask == sbus_mask then
                    found = true
                    break
                  end
                end
                ui.servoBusEnabled = found
              end

              ui.progress = 75
              if type(ui.runtime.requestRebuild) == "function" then
                ui.runtime.requestRebuild()
              end

              -- Step 4: the selected servo's own record, where the firmware has that read
              if hasPagedServoReads() then
                ui.servoLoaded = {}
                if not queueServoRead(ui.selectedServoIndex, finishServoLoad) then
                  finishServoLoad(false)
                end
                return
              end

              -- Step 4: Read SERVO_CONFIGURATIONS
              queue:add({
                command = ServoConfigsApi.command,
                simulatorResponse = ServoConfigsApi.simulatorResponse,
                processReply = function(self, buf)
                  local parsed = ServoConfigsApi.parse(buf)
                  if parsed then
                    ui.config.servos = {}
                    local count = parsed.servo_count or 0
                    for i = 0, count - 1 do
                      local s = {}
                      s.mid = parsed["servo_" .. (i + 1) .. "_mid"] or 1500
                      s.min = parsed["servo_" .. (i + 1) .. "_min"] or 0
                      s.max = parsed["servo_" .. (i + 1) .. "_max"] or 0
                      s.scaleNeg = parsed["servo_" .. (i + 1) .. "_rneg"] or 500
                      s.scalePos = parsed["servo_" .. (i + 1) .. "_rpos"] or 500
                      s.rate = parsed["servo_" .. (i + 1) .. "_rate"] or 333
                      s.speed = parsed["servo_" .. (i + 1) .. "_speed"] or 0
                      s.flags = parsed["servo_" .. (i + 1) .. "_flags"] or 0

                      if s.flags == 1 or s.flags == 3 then
                        s.reverse = 1
                      else
                        s.reverse = 0
                      end

                      if s.flags == 2 or s.flags == 3 then
                        s.geometry = 1
                      else
                        s.geometry = 0
                      end

                      -- The reply is PACKED; this table is keyed by the raw index.
                      local pwm = pwmServoCount()
                      if i < pwm then
                        ui.config.servos[i] = s
                      else
                        ui.config.servos[BUS_SERVO_OFFSET + (i - pwm)] = s
                        ui.servoLoaded[i - pwm] = true
                      end
                    end
                  end

                  saveToSession()

                  ui.runtime.readPending = false
                  ui.loading = false
                  ui.dirty = false
                  ui.progress = 100
                  ui.loaded = true
                  if type(ui.runtime.requestRebuild) == "function" then
                    ui.runtime.requestRebuild()
                  end
                end,
                errorHandler = function()
                  ui.runtime.readPending = false
                  ui.loading = false
                  if type(ui.runtime.requestRebuild) == "function" then
                    ui.runtime.requestRebuild()
                  end
                end
              })
            end,
            errorHandler = function()
              ui.runtime.readPending = false
              ui.loading = false
              if type(ui.runtime.requestRebuild) == "function" then
                ui.runtime.requestRebuild()
              end
            end
          })
        end,
        errorHandler = function()
          ui.runtime.readPending = false
          ui.loading = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueServoWrite(servoIdx)
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local config = ui.config.servos and ui.config.servos[rawServoIndex(servoIdx)]
  if not config then return false, "config_unavailable" end

  local mid = math.floor(config.mid or 1500)
  local min = math.floor(config.min or 0)
  local max = math.floor(config.max or 0)
  local scaleNeg = math.floor(config.scaleNeg or 500)
  local scalePos = math.floor(config.scalePos or 500)
  local speed = math.floor(config.speed or 0)

  local reverse = tonumber(config.reverse) or 0
  local geometry = tonumber(config.geometry) or 0
  local flags = 0
  if reverse == 0 and geometry == 0 then
    flags = 0
  elseif reverse == 1 and geometry == 0 then
    flags = 1
  elseif reverse == 0 and geometry == 1 then
    flags = 2
  elseif reverse == 1 and geometry == 1 then
    flags = 3
  end

  -- MSP_SET_SERVO_CONFIGURATION takes the PACKED index, unlike the centre write above.
  local writeIndex = packedServoIndex(servoIdx)

  local payload = {}
  writeU8(payload, writeIndex)
  writeU16(payload, mid)
  writeS16(payload, min)
  writeS16(payload, max)
  writeU16(payload, scaleNeg)
  writeU16(payload, scalePos)
  writeU16(payload, 333) -- Rate is mapped to 333
  writeU16(payload, speed)
  writeU16(payload, flags)

  ui.loading = true
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end

  queue:add({
    command = 212,
    payload = payload,
    isWrite = true,
    processReply = function(self, buf)
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      if eepromApi then
        queue:add({
          command = eepromApi.command,
          payload = {},
          isWrite = true,
          processReply = function()
            ui.loading = false
            ui.dirty = false
            saveToSession()
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end,
          errorHandler = function()
            ui.loading = false
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        })
      else
        ui.loading = false
        ui.dirty = false
        saveToSession()
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end,
    errorHandler = function()
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function ensureLoaded()
  if not ui.loaded and not ui.loading and not ui.runtime.readPending then
    local session = getSession()
    if session then
      loadFromSession()
      queueServosRead(false)
    end
  end
end

function M.onLoad()
  ensureDeps()
end

function M.onActivate()
  ensureDeps()
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local session = getSession()
  local signature = session and session.signature or nil
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    queueServosRead(false)
  end

  if ui.inOverride and ui.dirty then
    local now = nowSeconds()
    if (now - lastChangeTime) >= liveUpdateInterval then
      lastChangeTime = now
      triggerLiveWrite()
    end
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    star = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = "@i18n(app.loading)@",
      message = pageText(i18n, "loading", "Reading servos configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  -- Determine display title
  local title = pageText(i18n, "bus", "BUS Output")
  if ui.inOverride then
    title = title .. " *"
  end

  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- Sixteen, not BUS_SERVO_CHANNELS: the firmware's 18 is an SBUS frame's 16 proportional
  -- channels plus its 2 digital ones, and whether a servo belongs on those two is not a
  -- question this change answers. Left as it was.
  local busServoCount = 16
  local servoOptions = {}
  for i = 1, busServoCount do
    servoOptions[#servoOptions + 1] = {
      label = getServoTitle(i18n, i),
      value = i - 1
    }
  end

  if ui.selectedServoIndex == nil or ui.selectedServoIndex >= busServoCount then
    ui.selectedServoIndex = 0
  end

  -- 1) Active Servo Dropdown
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "servo", "Servo"),
    servoOptions,
    ui.selectedServoIndex,
    function(val)
      if ui.selectedServoIndex ~= val then
        ui.selectedServoIndex = val
        -- Only the paged route leaves a servo unread; the whole-table route brought them all.
        if hasPagedServoReads() and not ui.servoLoaded[val] then
          ui.loading = true
          queueServoRead(val, function()
            ui.loading = false
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end)
        end
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end,
    {
      active = function() return not ui.inOverride end
    }
  )

  -- Everything below is the selected servo's own record, so it is drawn only once that
  -- record has been read. Editing what an unfinished read left behind would write it back.
  if not ui.servoLoaded[ui.selectedServoIndex] then return end

  local idx = ui.selectedServoIndex
  -- BUS configs are mapped to absolute indices 8 to 23
  local s = ui.config.servos[rawServoIndex(idx)] or { mid = 1500, min = -500, max = 500, scaleNeg = 500, scalePos = 500, speed = 0, reverse = 0, geometry = 0 }

  -- 2) Center
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "center", "Center"),
    {
      min = 1000,
      max = 2000,
      step = 1,
      get = function() return s.mid or 1500 end,
      set = function(val)
        if s.mid ~= val then
          s.mid = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v) .. "us" end,
      suffix = "us"
    }
  )

  -- 3) Minimum
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "minimum", "Minimum"),
    {
      min = -500,
      max = -1,
      step = 1,
      get = function() return s.min or -500 end,
      set = function(val)
        if s.min ~= val then
          s.min = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v) .. "us" end,
      suffix = "us",
      active = function() return not ui.inOverride end
    }
  )

  -- 4) Maximum
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "maximum", "Maximum"),
    {
      min = 1,
      max = 500,
      step = 1,
      get = function() return s.max or 500 end,
      set = function(val)
        if s.max ~= val then
          s.max = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v) .. "us" end,
      suffix = "us",
      active = function() return not ui.inOverride end
    }
  )

  -- 5) Scale Negative
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "scale_negative", "Scale Negative"),
    {
      min = 100,
      max = 1000,
      step = 1,
      get = function() return s.scaleNeg or 500 end,
      set = function(val)
        if s.scaleNeg ~= val then
          s.scaleNeg = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v) end,
      suffix = "",
      active = function() return not ui.inOverride end
    }
  )

  -- 6) Scale Positive
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "scale_positive", "Scale Positive"),
    {
      min = 100,
      max = 1000,
      step = 1,
      get = function() return s.scalePos or 500 end,
      set = function(val)
        if s.scalePos ~= val then
          s.scalePos = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v) end,
      suffix = "",
      active = function() return not ui.inOverride end
    }
  )

  -- 7) Speed
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "speed", "Speed"),
    {
      min = 0,
      max = 60000,
      step = 1,
      get = function() return s.speed or 0 end,
      set = function(val)
        if s.speed ~= val then
          s.speed = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v) .. "ms" end,
      suffix = "ms",
      active = function() return not ui.inOverride end
    }
  )

  -- 8) Reverse
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "reverse", "Reverse"),
    {
      { label = pageText(i18n, "tbl_no", "NO"), value = 0 },
      { label = pageText(i18n, "tbl_yes", "YES"), value = 1 }
    },
    s.reverse or 0,
    function(val)
      if s.reverse ~= val then
        s.reverse = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end,
    {
      active = function() return not ui.inOverride end
    }
  )

  -- 9) Geometry (only shown for first 8 outputs)
  if idx <= 7 then
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "geometry", "Geometry"),
      {
        { label = pageText(i18n, "tbl_no", "NO"), value = 0 },
        { label = pageText(i18n, "tbl_yes", "YES"), value = 1 }
      },
      s.geometry or 0,
      function(val)
        if s.geometry ~= val then
          s.geometry = val
          ui.dirty = true
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      end,
      {
        active = function() return not ui.inOverride end
      }
    )
  end
end

function M.onSave(ctx)
  local ok, err = queueServoWrite(ui.selectedServoIndex)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  ui.dirty = false
  if ctx and type(ctx.reportSave) == "function" then
    ctx.reportSave({
      title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
      message = pageText(ctx and ctx.i18n, "saved_message", "Servo settings saved")
    })
  end
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    queueServosRead(false)
  end
  return true
end

function M.onStar(ctx)
  if not ConfirmDialog then return false end

  local i18n = ctx and ctx.i18n
  local title
  local message

  if not ui.inOverride then
    title = pageText(i18n, "enable_servo_override", "Enable servo override")
    message = pageText(i18n, "enable_servo_override_msg", "Servo override allows you to 'trim' your servo center point in real time.")
  else
    title = pageText(i18n, "disable_servo_override", "Disable servo override")
    message = pageText(i18n, "disable_servo_override_msg", "Return control of the servos to the flight controller.")
  end

  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      if not ui.inOverride then
        setOverride(true)
        ui.inOverride = true
      else
        setOverride(false)
        ui.inOverride = false
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true
end


function M.onClose()
  if ui.inOverride then
    setOverride(false)
    ui.inOverride = false
  end
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true,
      resetConfig = true,
      resetApiData = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
