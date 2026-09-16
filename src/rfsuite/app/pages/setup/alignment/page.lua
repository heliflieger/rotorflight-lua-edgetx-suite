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
local SavePipeline = nil
local Common = nil
local MspRuntime = nil
local BoardAlignmentApi = nil
local SensorAlignmentApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local sin = math.sin
local cos = math.cos
local rad = math.rad
local floor = math.floor
local sqrt = math.sqrt
local max = math.max
local min = math.min
local t_sort = table.sort

local MSP_ATTITUDE = 108
local BASE_VIEW_PITCH_R = rad(-90)
local BASE_VIEW_YAW_R = rad(90)
local CAMERA_DIST = 7.0
local CAMERA_NEAR_EPS = 0.25

local magAlignChoices = {
  {"mag_default", 1},
  {"mag_cw_0", 2},
  {"mag_cw_90", 3},
  {"mag_cw_180", 4},
  {"mag_cw_270", 5},
  {"mag_cw_0_flip", 6},
  {"mag_cw_90_flip", 7},
  {"mag_cw_180_flip", 8},
  {"mag_cw_270_flip", 9},
  {"mag_custom", 10}
}

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  runtime = newRuntime(),
  loading = false,
  progress = 0,
  baseTitle = nil,
  liveViewEnabled = false,
  liveViewStartedAt = 0,
  pollingEnabled = false,
  lastAttitudeAt = 0,
  attitudeSamplePeriod = 0.25, -- ~4Hz refresh to prevent link overload
  pendingAttitude = false,
  pendingAt = 0,
  pendingTimeout = 1.0,
  autoRecenterPending = false,
  simStartAt = 0,
  viewYawOffset = 0,
  display = {
    roll_degrees = 0,
    pitch_degrees = 0,
    yaw_degrees = 0,
    gyro_1_alignment = 0,
    gyro_2_alignment = 0,
    mag_alignment = 0
  },
  live = {
    roll = 0,
    pitch = 0,
    yaw = 0
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
  if not BoardAlignmentApi then BoardAlignmentApi = loadModule("tasks/msp/api/board_alignment_config.lua") end
  if not SensorAlignmentApi then SensorAlignmentApi = loadModule("tasks/msp/api/sensor_alignment.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_alignment") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
  end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then
      return ticks / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
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

local function toSigned16(v)
  v = tonumber(v) or 0
  if v > 32767 then return v - 65536 end
  return v
end

local function toU16(v)
  v = floor(tonumber(v) or 0)
  if v < -32768 then v = -32768 end
  if v > 32767 then v = 32767 end
  if v < 0 then return v + 65536 end
  return v
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_alignment) ~= "table" then return end
  local saved = session.setup_alignment
  ui.display.roll_degrees = saved.roll_degrees or 0
  ui.display.pitch_degrees = saved.pitch_degrees or 0
  ui.display.yaw_degrees = saved.yaw_degrees or 0
  ui.loaded_roll_degrees = saved.loaded_roll_degrees or saved.roll_degrees or 0
  ui.loaded_pitch_degrees = saved.loaded_pitch_degrees or saved.pitch_degrees or 0
  ui.loaded_yaw_degrees = saved.loaded_yaw_degrees or saved.yaw_degrees or 0
  ui.display.gyro_1_alignment = saved.gyro_1_alignment or 0
  ui.display.gyro_2_alignment = saved.gyro_2_alignment or 0
  ui.display.mag_alignment = saved.mag_alignment or 0
end

local function saveToSession()
  local session = getSession()
  if not session then return end
  session.setup_alignment = {
    roll_degrees = ui.display.roll_degrees,
    pitch_degrees = ui.display.pitch_degrees,
    yaw_degrees = ui.display.yaw_degrees,
    loaded_roll_degrees = ui.loaded_roll_degrees,
    loaded_pitch_degrees = ui.loaded_pitch_degrees,
    loaded_yaw_degrees = ui.loaded_yaw_degrees,
    gyro_1_alignment = ui.display.gyro_1_alignment,
    gyro_2_alignment = ui.display.gyro_2_alignment,
    mag_alignment = ui.display.mag_alignment
  }
end

local function recenterYawView()
  local loadedYaw = ui.loaded_yaw_degrees or 0
  ui.viewYawOffset = (tonumber(ui.live.yaw) or 0) - loadedYaw + (tonumber(ui.display.yaw_degrees) or 0)
end

local function parseAttitude(buf)
  if type(buf) ~= "table" or #buf < 6 then return false end
  local function readS16(lo, hi)
    local v = (tonumber(hi) or 0) << 8 | (tonumber(lo) or 0)
    if v > 32767 then return v - 65536 end
    return v
  end

  local rollRaw = readS16(buf[1], buf[2])
  local pitchRaw = readS16(buf[3], buf[4])
  local yawRaw = readS16(buf[5], buf[6])

  ui.live.roll = rollRaw / 10.0
  ui.live.pitch = pitchRaw / 10.0
  ui.live.yaw = yawRaw
  if ui.autoRecenterPending then
    recenterYawView()
    ui.autoRecenterPending = false
  end
  return true
end

local function buildSimulatedAttitudeResponse(now)
  local t0 = ui.simStartAt or 0
  local clockT = max(0, now - t0)

  local rollDeg = 25.0 * sin(clockT * 1.25)
  local pitchDeg = 18.0 * sin((clockT * 0.90) + 0.9)
  local yawDeg = 90.0 * sin((clockT * 0.42) + 0.2)

  local rollRaw = floor((rollDeg * 10.0) + 0.5)
  local pitchRaw = floor((pitchDeg * 10.0) + 0.5)
  local yawRaw = floor(yawDeg + 0.5)

  local function packS16(v)
    if v < 0 then v = v + 65536 end
    return v & 0xFF, (v >> 8) & 0xFF
  end

  local rLo, rHi = packS16(rollRaw)
  local pLo, pHi = packS16(pitchRaw)
  local yLo, yHi = packS16(yawRaw)

  return { rLo, rHi, pLo, pHi, yLo, yHi }
end

local function requestAttitude(queue, now)
  if ui.pendingAttitude then return false end
  ui.pendingAttitude = true
  ui.pendingAt = now

  local sim = false
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, ver = pcall(system.getVersion)
    if ok and ver and ver.simulation then
      sim = true
    end
  end
  local simResponse = sim and buildSimulatedAttitudeResponse(now) or {}

  return queue:add({
    command = MSP_ATTITUDE,
    uuid = "alignment.attitude",
    processReply = function(self, buf)
      parseAttitude(buf)
      ui.pendingAttitude = false
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      ui.pendingAttitude = false
    end,
    simulatorResponse = simResponse
  })
end

local function queueAlignmentRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not BoardAlignmentApi or not SensorAlignmentApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = true
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: Read BOARD_ALIGNMENT_CONFIG
  queue:add({
    command = BoardAlignmentApi.command,
    simulatorResponse = BoardAlignmentApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = BoardAlignmentApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        local roll = toSigned16(parsed.roll_degrees)
        local pitch = toSigned16(parsed.pitch_degrees)
        local yaw = toSigned16(parsed.yaw_degrees)
        ui.display.roll_degrees = roll
        ui.display.pitch_degrees = pitch
        ui.display.yaw_degrees = yaw
        ui.loaded_roll_degrees = roll
        ui.loaded_pitch_degrees = pitch
        ui.loaded_yaw_degrees = yaw
        saveToSession()
      end

      -- Step 2: Read SENSOR_ALIGNMENT
      ui.progress = 50
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      queue:add({
        command = SensorAlignmentApi.command,
        simulatorResponse = SensorAlignmentApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsed2 = SensorAlignmentApi.parse(buf2)
          if type(parsed2) ~= "table" then return Common.failPageRead(ui) end
          if parsed2 then
            ui.display.gyro_1_alignment = math.max(0, math.min(255, tonumber(parsed2.gyro_1_alignment) or 0))
            ui.display.gyro_2_alignment = math.max(0, math.min(255, tonumber(parsed2.gyro_2_alignment) or 0))
            ui.display.mag_alignment = math.max(0, math.min(9, tonumber(parsed2.mag_alignment) or 0))
            saveToSession()
          end

          if ui.runtime then ui.runtime.readPending = false end
          ui.loading = false
          ui.dirty = false
          ui.progress = 100
          ui.runtime.readComplete = readValid
          if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          readValid = false
          if ui.runtime then ui.runtime.readPending = false end
          ui.loading = false
          if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      readValid = false
      if ui.runtime then ui.runtime.readPending = false end
      ui.loading = false
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueAlignmentWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not BoardAlignmentApi or not SensorAlignmentApi then
    return false, "msp_runtime_unavailable"
  end

  -- The four nested queue:add calls that stood here ended with an empty processReply on the
  -- reboot and an empty errorHandler on every step, so a failed alignment write was silent and
  -- nothing waited for the board. The pipeline owns the process and reports its outcome.
  return SavePipeline.start({
    pageId = "setup_alignment",
    steps = {
      {
        label = "MSP_SET_BOARD_ALIGNMENT_CONFIG",
        command = BoardAlignmentApi.writeCommand,
        payload = BoardAlignmentApi.buildWritePayload({
          roll_degrees = toU16(ui.display.roll_degrees),
          pitch_degrees = toU16(ui.display.pitch_degrees),
          yaw_degrees = toU16(ui.display.yaw_degrees)
        })
      },
      {
        label = "MSP_SET_SENSOR_ALIGNMENT",
        command = SensorAlignmentApi.writeCommand,
        payload = SensorAlignmentApi.buildWritePayload({
          gyro_1_alignment = ui.display.gyro_1_alignment,
          gyro_2_alignment = ui.display.gyro_2_alignment,
          mag_alignment = ui.display.mag_alignment
        })
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_alignment" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function rotatePoint(x, y, z, cx, sx, cy, sy, cz, sz)
  local bx = -y
  local by = z
  local bz = -x

  local x1 = bx * cz - by * sz
  local y1 = bx * sz + by * cz
  local z1 = bz

  local x2 = x1
  local y2 = y1 * cx - z1 * sx
  local z2 = y1 * sx + z1 * cx

  local x3 = x2 * cy + z2 * sy
  local y3 = y2
  local z3 = -x2 * sy + z2 * cy

  return x3, y3, z3
end

local function projectPoint(px, py, pz, mx, my, scale)
  local denom = CAMERA_DIST - pz
  if denom <= CAMERA_NEAR_EPS then return nil, nil end
  local f = CAMERA_DIST / denom
  local sx = mx + (px * f * scale)
  local sy = my - (py * f * scale)
  return sx, sy
end

local function drawLine3D(children, a, b, mx, my, scale, cx, sx, cy, sy, cz, sz, color)
  local ax, ay, az = rotatePoint(a[1], a[2], a[3], cx, sx, cy, sy, cz, sz)
  local bx, by, bz = rotatePoint(b[1], b[2], b[3], cx, sx, cy, sy, cz, sz)
  if (CAMERA_DIST - az) <= CAMERA_NEAR_EPS or (CAMERA_DIST - bz) <= CAMERA_NEAR_EPS then
    return
  end
  local x1, y1 = projectPoint(ax, ay, az, mx, my, scale)
  local x2, y2 = projectPoint(bx, by, bz, mx, my, scale)
  if x1 == nil or x2 == nil then return end

  children[#children + 1] = {
    type = "line",
    x = 0, y = 0, w = 0, h = 0,
    pts = {{floor(x1), floor(y1)}, {floor(x2), floor(y2)}},
    color = color,
    thickness = 1
  }
end

local function drawFilledTriangle3D(children, a, b, c, mx, my, scale, cx, sx, cy, sy, cz, sz, color)
  local ax, ay, az = rotatePoint(a[1], a[2], a[3], cx, sx, cy, sy, cz, sz)
  local bx, by, bz = rotatePoint(b[1], b[2], b[3], cx, sx, cy, sy, cz, sz)
  local cx3, cy3, cz3 = rotatePoint(c[1], c[2], c[3], cx, sx, cy, sy, cz, sz)
  if (CAMERA_DIST - az) <= CAMERA_NEAR_EPS or (CAMERA_DIST - bz) <= CAMERA_NEAR_EPS or (CAMERA_DIST - cz3) <= CAMERA_NEAR_EPS then
    return
  end

  local x1, y1 = projectPoint(ax, ay, az, mx, my, scale)
  local x2, y2 = projectPoint(bx, by, bz, mx, my, scale)
  local x3, y3 = projectPoint(cx3, cy3, cz3, mx, my, scale)
  if x1 == nil or x2 == nil or x3 == nil then return end

  children[#children + 1] = {
    type = "triangle",
    x = 0, y = 0, w = 0, h = 0,
    pts = {{floor(x1), floor(y1)}, {floor(x2), floor(y2)}, {floor(x3), floor(y3)}},
    color = color
  }
end

local function collectTriangle3D(list, a, b, c, mx, my, scale, cx, sx, cy, sy, cz, sz, color)
  local ax, ay, az = rotatePoint(a[1], a[2], a[3], cx, sx, cy, sy, cz, sz)
  local bx, by, bz = rotatePoint(b[1], b[2], b[3], cx, sx, cy, sy, cz, sz)
  local cx3, cy3, cz3 = rotatePoint(c[1], c[2], c[3], cx, sx, cy, sy, cz, sz)
  if (CAMERA_DIST - az) <= CAMERA_NEAR_EPS or (CAMERA_DIST - bz) <= CAMERA_NEAR_EPS or (CAMERA_DIST - cz3) <= CAMERA_NEAR_EPS then
    return
  end

  local x1, y1 = projectPoint(ax, ay, az, mx, my, scale)
  local x2, y2 = projectPoint(bx, by, bz, mx, my, scale)
  local x3, y3 = projectPoint(cx3, cy3, cz3, mx, my, scale)
  if x1 == nil or x2 == nil or x3 == nil then return end

  list[#list + 1] = {
    x1 = floor(x1), y1 = floor(y1),
    x2 = floor(x2), y2 = floor(y2),
    x3 = floor(x3), y3 = floor(y3),
    z = (az + bz + cz3) / 3,
    color = color
  }
end

local function drawTriangleList(children, list)
  if #list == 0 then return end
  t_sort(list, function(a, b) return a.z < b.z end)
  for i = 1, #list do
    local t = list[i]
    children[#children + 1] = {
      type = "triangle",
      x = 0, y = 0, w = 0, h = 0,
      pts = {{t.x1, t.y1}, {t.x2, t.y2}, {t.x3, t.y3}},
      color = t.color
    }
  end
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "title", "Alignment")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.liveViewEnabled = false
  ui.liveViewStartedAt = 0
  ui.pollingEnabled = false
  ui.autoRecenterPending = true
  ui.simStartAt = nowSeconds()
  ui.viewYawOffset = 0
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueAlignmentRead(false)
end

function M.onLoad()
  ensureDeps()
  ensureLoaded()
end

function M.onActivate()
  ensureDeps()
  ensureLoaded()
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held
  -- back rather than raised over whatever page the user went to; claim it now.
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_alignment")
  end
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueAlignmentRead(false)
  end

  if ui.liveViewEnabled then
    local now = nowSeconds()
    if (now - ui.liveViewStartedAt) >= 60.0 then
      ui.liveViewEnabled = false
      ui.pollingEnabled = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
      return
    end

    if ui.pendingAttitude and (now - ui.pendingAt) > ui.pendingTimeout then
      ui.pendingAttitude = false
    end

    if (now - ui.lastAttitudeAt) >= ui.attitudeSamplePeriod then
      ui.lastAttitudeAt = now
      local mspState = MspRuntime and MspRuntime.getState()
      local queue = mspState and mspState.queue
      if queue and type(queue.add) == "function" and queue:isProcessed() then
        requestAttitude(queue, now)
      end
    end
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    star = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading", "Reading sensor configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local leftPad = 4
  local rightPad = 8
  local gap = 6
  local fieldW = w - leftPad - rightPad
  local rowH = (Controls and Controls.ROW_H) or 64
  local labelY1 = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop1 = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  -- Row 1: Roll, Nick, Yaw
  local editW = 68 -- 68px wide text fields so -180° never wraps
  local labelW = 40 -- 40px wide labels for Roll, Nick, Gier so they never wrap

  local slotX1 = x + leftPad
  local controlW = labelW + editW

  local slotX2 = slotX1 + controlW + gap
  local slotX3 = slotX2 + controlW + gap

  -- Slot 1: Roll
  children[#children + 1] = {
    type = "label",
    x = slotX1, y = labelY1,
    w = labelW,
    text = pageText(i18n, "roll", "Roll"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = slotX1 + labelW, y = cellTop1,
    w = editW,
    min = -180, max = 360,
    active = function() return not ui.liveViewEnabled end,
    get = function() return ui.display.roll_degrees end,
    set = function(v)
      ui.display.roll_degrees = floor(v or 0)
      ui.dirty = true
      saveToSession()
    end,
    display = function(v) return tostring(v or 0) .. "°" end
  }

  -- Slot 2: Pitch (Nick)
  children[#children + 1] = {
    type = "label",
    x = slotX2, y = labelY1,
    w = labelW,
    text = pageText(i18n, "pitch", "Pitch"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = slotX2 + labelW, y = cellTop1,
    w = editW,
    min = -180, max = 360,
    active = function() return not ui.liveViewEnabled end,
    get = function() return ui.display.pitch_degrees end,
    set = function(v)
      ui.display.pitch_degrees = floor(v or 0)
      ui.dirty = true
      saveToSession()
    end,
    display = function(v) return tostring(v or 0) .. "°" end
  }

  -- Slot 3: Yaw (Gier)
  children[#children + 1] = {
    type = "label",
    x = slotX3, y = labelY1,
    w = labelW,
    text = pageText(i18n, "yaw", "Yaw"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = slotX3 + labelW, y = cellTop1,
    w = editW,
    min = -180, max = 360,
    active = function() return not ui.liveViewEnabled end,
    get = function() return ui.display.yaw_degrees end,
    set = function(v)
      ui.display.yaw_degrees = floor(v or 0)
      ui.dirty = true
      saveToSession()
    end,
    display = function(v) return tostring(v or 0) .. "°" end
  }

  -- Divider line below first row of fields
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2,
    filled = true
  }

  -- Row 2: Mag and Buttons (aligned on controlY)
  local controlY = (Controls and Controls.controlY and Controls.controlY(y + rowH, rowH)) or (y + rowH + math.floor((rowH - 32) / 2))
  local labelY2 = (Controls and Controls.labelY and Controls.labelY(y + rowH, rowH)) or (y + rowH + math.floor((rowH - 21) / 2))

  -- Slot 4: Mag
  local magLabelW = 38
  local magEditW = 160

  children[#children + 1] = {
    type = "label",
    x = x + leftPad, y = labelY2,
    w = magLabelW,
    text = pageText(i18n, "mag", "Mag"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  local magAlignChoicesValues = {}
  for i, val in ipairs(magAlignChoices) do
    magAlignChoicesValues[i] = pageText(i18n, val[1], val[1])
  end

  children[#children + 1] = {
    type = "choice",
    x = x + leftPad + magLabelW, y = controlY,
    w = magEditW,
    title = pageText(i18n, "mag", "Mag"),
    values = magAlignChoicesValues,
    active = function() return not ui.liveViewEnabled end,
    get = function()
      return ui.display.mag_alignment + 1
    end,
    set = function(v)
      ui.display.mag_alignment = max(0, min(9, (tonumber(v) or 1) - 1))
      ui.dirty = true
      saveToSession()
    end
  }

  -- Buttons
  local btnStart = x + leftPad + magLabelW + magEditW + gap * 2
  local remainingW = w - btnStart - rightPad
  local btnW = floor((remainingW - gap) / 2)

  local liveBtnText = pageText(i18n, "live_view", "Live View")
  if ui.liveViewEnabled then
    local remaining = math.ceil(60.0 - (nowSeconds() - ui.liveViewStartedAt))
    if remaining < 0 then remaining = 0 end
    liveBtnText = string.format(pageText(i18n, "live_remaining_fmt", "Live (%ds)"), remaining)
  end

  children[#children + 1] = {
    type = "button",
    x = btnStart, y = controlY,
    w = btnW,
    text = liveBtnText,
    press = function()
      if ui.liveViewEnabled then
        ui.liveViewEnabled = false
        ui.pollingEnabled = false
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      else
        ui.liveViewEnabled = true
        ui.liveViewStartedAt = nowSeconds()
        ui.pollingEnabled = true
        ui.lastAttitudeAt = 0
        ui.pendingAttitude = false
        ui.autoRecenterPending = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  }

  children[#children + 1] = {
    type = "button",
    x = btnStart + btnW + gap, y = controlY,
    w = btnW,
    text = pageText(i18n, "refresh_visual", "Refresh"),
    active = function() return not ui.liveViewEnabled end,
    press = function()
      local mspState = MspRuntime and MspRuntime.getState()
      local queue = mspState and mspState.queue
      if queue and type(queue.add) == "function" then
        requestAttitude(queue, nowSeconds())
      end
    end
  }

  -- Divider line below second row of fields
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + 2 * rowH,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2,
    filled = true
  }

  -- Split layout start
  local splitY = y + 2 * rowH + 4
  -- Use actual screen height remaining to strictly prevent scrollbars
  local pageBodyH = (lvgl and lvgl.PAGE_BODY_HEIGHT)
  local headerH = 48
  if LCD_H and LCD_H > 300 then
    headerH = 64
  end
  local availH = (h and h > 0) and h or (pageBodyH and (pageBodyH - y)) or ((LCD_H - headerH) - y)
  local splitH = max(50, availH - (2 * rowH) - 8)
  local leftW = floor(w * 0.40)
  local rightW = w - leftW - 4
  local rightX = x + leftW + 4

  -- Vertical divider
  children[#children + 1] = {
    type = "rectangle",
    x = x + leftW, y = splitY,
    w = 1, h = splitH,
    color = COLOR_THEME_SECONDARY2,
    filled = true
  }

  -- Left Panel: Readouts
  local liveText
  if ui.liveViewEnabled then
    liveText = string.format(pageText(i18n, "live_fmt", "Live  R:%0.1f  P:%0.1f  Y:%0.1f"), ui.live.roll, ui.live.pitch, ui.live.yaw)
  else
    liveText = "Live: --"
  end
  
  children[#children + 1] = {
    type = "label",
    x = x + 6, y = splitY + 2,
    w = leftW - 10,
    text = liveText,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  local offsetText = string.format(pageText(i18n, "offset_fmt", "Offset R:%d  P:%d  Y:%d  Mag:%d"), ui.display.roll_degrees, ui.display.pitch_degrees, ui.display.yaw_degrees, ui.display.mag_alignment)
  children[#children + 1] = {
    type = "label",
    x = x + 6, y = splitY + 18,
    w = leftW - 10,
    text = offsetText,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  local viewYawText = string.format(pageText(i18n, "view_yaw_fmt", "View Yaw:%0.1f"), ui.viewYawOffset)
  children[#children + 1] = {
    type = "label",
    x = x + 6, y = splitY + 34,
    w = leftW - 10,
    text = viewYawText,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  -- Nose Direction Box
  local boxY = splitY + 50
  local boxH = splitH - 52
  if boxH > 28 then
    children[#children + 1] = {
      type = "rectangle",
      x = x + 6, y = boxY,
      w = leftW - 12, h = boxH,
      color = COLOR_THEME_SECONDARY2,
      filled = false
    }
    
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = boxY + 2,
      w = leftW - 20,
      text = pageText(i18n, "nose_direction", "Nose Direction"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    local loadedRoll = ui.loaded_roll_degrees or 0
    local loadedPitch = ui.loaded_pitch_degrees or 0
    local pitchVal = ui.live.pitch - loadedPitch + ui.display.pitch_degrees
    local rollVal = ui.live.roll - loadedRoll + ui.display.roll_degrees

    local primary = pageText(i18n, "nose_level", "Nose Level")
    if pitchVal > 3.5 then
      primary = pageText(i18n, "nose_down", "Nose Down")
    elseif pitchVal < -3.5 then
      primary = pageText(i18n, "nose_up", "Nose Up")
    end

    local secondary = ""
    if rollVal > 3.5 then
      secondary = pageText(i18n, "leaning_right", "Leaning Right")
    elseif rollVal < -3.5 then
      secondary = pageText(i18n, "leaning_left", "Leaning Left")
    end

    if boxH >= 52 and secondary ~= "" then
      children[#children + 1] = {
        type = "label",
        x = x + 10, y = boxY + 18,
        w = leftW - 20,
        text = primary,
        color = COLOR_THEME_SECONDARY1 or YELLOW,
        font = SMLSIZE
      }
      children[#children + 1] = {
        type = "label",
        x = x + 10, y = boxY + 34,
        w = leftW - 20,
        text = secondary,
        color = COLOR_THEME_PRIMARY1,
        font = SMLSIZE
      }
    else
      local combinedText = primary
      if secondary ~= "" then
        combinedText = primary .. ", " .. secondary
      end
      children[#children + 1] = {
        type = "label",
        x = x + 10, y = boxY + 16,
        w = leftW - 20,
        text = combinedText,
        color = COLOR_THEME_SECONDARY1 or YELLOW,
        font = SMLSIZE
      }
    end
  end

  -- Right Panel: 3D Visualization Area
  children[#children + 1] = {
    type = "rectangle",
    x = rightX, y = splitY,
    w = rightW, h = splitH,
    color = COLOR_THEME_PRIMARY3 or BLACK,
    filled = true
  }

  local mx = rightX + floor(rightW * 0.5)
  local my = splitY + floor(splitH * 0.5)
  local scale = max(6, min(rightW, splitH) * 0.22)
  
  local loadedRoll = ui.loaded_roll_degrees or 0
  local loadedPitch = ui.loaded_pitch_degrees or 0
  local loadedYaw = ui.loaded_yaw_degrees or 0

  local pitchVal = ui.live.pitch - loadedPitch + ui.display.pitch_degrees
  local rollVal = ui.live.roll - loadedRoll + ui.display.roll_degrees
  local yawVal = ui.live.yaw - loadedYaw + ui.display.yaw_degrees

  local pitchR = rad(-pitchVal)
  local yawR = rad(-(yawVal - ui.viewYawOffset))
  local rollR = rad(-rollVal)

  local cx = cos(pitchR)
  local sx = sin(pitchR)
  local cy = cos(yawR)
  local sy = sin(yawR)
  local cz = cos(rollR)
  local sz = sin(rollR)

  local mainColor = WHITE
  local accent = COLOR_THEME_SECONDARY1 or YELLOW
  local disc = COLOR_THEME_SECONDARY2
  local bodyLight = COLOR_THEME_PRIMARY2
  local bodyMid = COLOR_THEME_SECONDARY2
  local bodyDark = COLOR_THEME_PRIMARY3 or BLACK

  local nose = {2.35, 0.0, -0.02}
  local tail = {-2.65, 0.0, 0.03}
  local lf = {1.10, -0.62, 0.02}
  local rf = {1.10, 0.62, 0.02}
  local lb = {-0.55, -0.46, 0.05}
  local rb = {-0.55, 0.46, 0.05}
  local top = {0.05, 0.0, 0.84}
  local podAftTop = {-0.66, 0.0, 0.56}
  local podAftBot = {-0.66, 0.0, -0.12}
  local podAftL = {-0.66, -0.30, 0.14}
  local podAftR = {-0.66, 0.30, 0.14}
  local mast = {0.0, 0.0, 1.02}
  local finU = {-2.25, 0.0, 0.45}
  local finD = {-2.25, 0.0, -0.18}
  local boomSL = {-0.88, -0.10, 0.11}
  local boomSR = {-0.88, 0.10, 0.11}
  local boomSU = {-0.88, 0.0, 0.18}
  local boomSD = {-0.88, 0.0, 0.06}
  local boomEL = {-2.35, -0.06, 0.08}
  local boomER = {-2.35, 0.06, 0.08}
  local boomEU = {-2.35, 0.0, 0.12}
  local boomED = {-2.35, 0.0, 0.05}

  local skidL1 = {1.12, -0.66, -0.69}
  local skidL2 = {0.76, -0.66, -0.64}
  local skidL3 = {0.00, -0.66, -0.62}
  local skidL4 = {-0.96, -0.66, -0.63}
  local skidL5 = {-1.24, -0.66, -0.67}
  local skidR1 = {1.12, 0.66, -0.69}
  local skidR2 = {0.76, 0.66, -0.64}
  local skidR3 = {0.00, 0.66, -0.62}
  local skidR4 = {-0.96, 0.66, -0.63}
  local skidR5 = {-1.24, 0.66, -0.67}

  local strutLFTop = {0.52, -0.50, -0.12}
  local strutLFBot = {0.48, -0.66, -0.63}
  local strutLBTop = {-0.52, -0.44, -0.10}
  local strutLBBot = {-0.58, -0.66, -0.63}
  local strutRFTop = {0.52, 0.50, -0.12}
  local strutRFBot = {0.48, 0.66, -0.63}
  local strutRBTop = {-0.52, 0.44, -0.10}
  local strutRBBot = {-0.58, 0.66, -0.63}

  local rotorA = {0.0, -1.9, 1.02}
  local rotorB = {0.0, 1.9, 1.02}
  local rotorC = {-1.9, 0.0, 1.02}
  local rotorD = {1.9, 0.0, 1.02}

  -- Collect triangles for fuselage shading
  local fuselage = {}
  collectTriangle3D(fuselage, nose, lf, top, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyLight)
  collectTriangle3D(fuselage, nose, top, rf, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyLight)
  collectTriangle3D(fuselage, lf, lb, top, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyMid)
  collectTriangle3D(fuselage, rf, top, rb, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyMid)
  collectTriangle3D(fuselage, lb, podAftTop, top, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, rb, top, podAftTop, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, lf, lb, rb, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, lf, rb, rf, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, lb, podAftL, podAftTop, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, rb, podAftTop, podAftR, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, lb, podAftBot, podAftL, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, rb, podAftR, podAftBot, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  
  -- Boom triangles
  collectTriangle3D(fuselage, boomSU, boomSL, boomEU, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyMid)
  collectTriangle3D(fuselage, boomSL, boomEL, boomEU, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyMid)
  collectTriangle3D(fuselage, boomSU, boomEU, boomSR, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyMid)
  collectTriangle3D(fuselage, boomSR, boomEU, boomER, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyMid)
  collectTriangle3D(fuselage, boomSL, boomSD, boomEL, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, boomSD, boomED, boomEL, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, boomSD, boomSR, boomED, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  collectTriangle3D(fuselage, boomSR, boomER, boomED, mx, my, scale, cx, sx, cy, sy, cz, sz, bodyDark)
  
  drawTriangleList(children, fuselage)

  -- Draw main outline wires / rotors
  drawLine3D(children, rotorA, rotorB, mx, my, scale, cx, sx, cy, sy, cz, sz, disc)
  drawLine3D(children, rotorC, rotorD, mx, my, scale, cx, sx, cy, sy, cz, sz, disc)
  drawLine3D(children, top, mast, mx, my, scale, cx, sx, cy, sy, cz, sz, disc)

  drawFilledTriangle3D(children, nose, lf, rf, mx, my, scale, cx, sx, cy, sy, cz, sz, accent)
  drawLine3D(children, lb, lf, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, rb, rf, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, lf, nose, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, rf, nose, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, top, nose, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, boomSU, boomEU, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, boomSL, boomEL, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, boomSR, boomER, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, boomSD, boomED, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, boomSU, boomSL, mx, my, scale, cx, sx, cy, sy, cz, sz, accent)
  drawLine3D(children, boomSL, boomSD, mx, my, scale, cx, sx, cy, sy, cz, sz, accent)
  drawLine3D(children, boomSD, boomSR, mx, my, scale, cx, sx, cy, sy, cz, sz, accent)
  drawLine3D(children, boomSR, boomSU, mx, my, scale, cx, sx, cy, sy, cz, sz, accent)

  drawLine3D(children, finU, finD, mx, my, scale, cx, sx, cy, sy, cz, sz, accent)
  
  -- Landing skids
  drawLine3D(children, skidL1, skidL2, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidL2, skidL3, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidL3, skidL4, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidL4, skidL5, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidR1, skidR2, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidR2, skidR3, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidR3, skidR4, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, skidR4, skidR5, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutLFTop, strutLFBot, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutLBTop, strutLBBot, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutRFTop, strutRFBot, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutRBTop, strutRBBot, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutLFBot, strutRFBot, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutLBBot, strutRBBot, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutLFTop, strutRFTop, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
  drawLine3D(children, strutLBTop, strutRBTop, mx, my, scale, cx, sx, cy, sy, cz, sz, mainColor)
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueAlignmentWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  ui.loaded_roll_degrees = ui.display.roll_degrees
  ui.loaded_pitch_degrees = ui.display.pitch_degrees
  ui.loaded_yaw_degrees = ui.display.yaw_degrees
  saveToSession()
  -- Nothing is announced here. This function has only QUEUED the save: the writes, the commit
  -- and -- on this page -- the restart are all still ahead of it, and a dialog saying the
  -- settings are saved would be a claim it cannot make. It was also drawn on TOP of the
  -- overlay that reports the save, from a place where that overlay could not be repainted away
  -- first, and while a native dialog stands the tool's run() does not run at all. The pipeline
  -- reports the outcome in the overlay, once, when it knows it.
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    ui.liveViewEnabled = false
    ui.liveViewStartedAt = 0
    ui.pollingEnabled = false
    queueAlignmentRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/alignment/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end

function M.onStar(ctx)
  if not ConfirmDialog then return false end
  local i18n = ctx and ctx.i18n
  local title = pageText(i18n, "title", "Alignment")
  local message = pageText(i18n, "msg_reset_tail_view", "Reset view yaw so the tail faces you?")
  
  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      recenterYawView()
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  return true
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  ui.liveViewEnabled = false
  ui.liveViewStartedAt = 0
  ui.pollingEnabled = false
  Controls = nil
  Common = nil
  MspRuntime = nil
  BoardAlignmentApi = nil
  SensorAlignmentApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
