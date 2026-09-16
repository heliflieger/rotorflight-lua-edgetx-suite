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
local MotorOverrideApi = nil
local t = nil

--- How often the override is written again while the page holds a motor.
---
--- The flight controller drops every override MOTOR_OVERRIDE_TIMEOUT after the last write
--- (src/main/flight/motors.c, one second), so the value has to be repeated or the motor stops
--- by itself. Four times inside that window, which is what the Configurator sends.
local REFRESH_INTERVAL = 0.25

--- How long a write that has neither answered nor failed blocks the next one.
---
--- The same second, and for the same reason: past it the override has lapsed at the far end
--- anyway, so there is nothing left to protect by waiting. Below it the page sends one write
--- at a time, which is what keeps the queue from growing on a link slower than the refresh.
local WRITE_GIVE_UP = 1.0

--- Only the forward half of the range is offered. MOTOR_OVERRIDE_MIN is -1000 and drives the
--- motor backwards, which is not part of any setup procedure and not something to put one turn
--- of a wheel away from zero.
local MAX_PERCENT = 100

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
  loading = false,
  progress = 0,
  inOverride = false,
  motorCount = 0,
  selected = 0, -- 0-based, as the wire numbers motors
  percent = {}, -- [motorIndex] = 0..MAX_PERCENT
  writeInFlight = false,
  lastWriteAt = 0,
  runtime = {
    readPending = false,
    requestRebuild = nil,
    syncHeaderTitle = nil,
    lastSessionSignature = nil
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
  if not MotorOverrideApi then MotorOverrideApi = loadModule("tasks/msp/api/motor_override.lua") end
  if not t then t = Common and Common.pageT("setup_esc_motors") or nil end
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

local function getMspState()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  return MspRuntime.getState()
end

local function getQueue()
  local mspState = getMspState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

--- How many motors to offer. A board that answers 0 has no motor outputs configured; the page
--- still shows the first one rather than a dead end, and the flight controller ignores an
--- override for a motor it does not have.
local function effectiveMotorCount()
  local count = tonumber(ui.motorCount) or 0
  if count < 1 then count = 1 end
  if count > 4 then count = 4 end
  return count
end

local function percentToValue(percent)
  local p = tonumber(percent) or 0
  if p < 0 then p = 0 end
  if p > MAX_PERCENT then p = MAX_PERCENT end
  local full = MotorOverrideApi and MotorOverrideApi.OVERRIDE_MAX or 1000
  return math.floor(p * full / 100)
end

local function writeOverride(index, percent)
  local queue = getQueue()
  if not queue or not MotorOverrideApi then return false end

  queue:add({
    command = MotorOverrideApi.writeCommand,
    payload = MotorOverrideApi.buildWritePayload({
      index = index,
      value = percentToValue(percent)
    }),
    isWrite = true,
    processReply = function()
      ui.writeInFlight = false
    end,
    errorHandler = function()
      ui.writeInFlight = false
    end
  })

  ui.writeInFlight = true
  ui.lastWriteAt = nowSeconds()
  return true
end

--- Put every motor back to zero, whatever the page currently shows.
---
--- Every motor and not only the selected one, because the pilot may have moved between them,
--- and unconditionally, because this is the path that has to work when something has already
--- gone wrong. If the queue is gone the write cannot be made -- and then nothing can reach the
--- board either, so the override lapses on its own within the second.
local function releaseAllMotors()
  local count = effectiveMotorCount()
  for i = 0, count - 1 do
    ui.percent[i] = 0
    writeOverride(i, 0)
  end
  ui.writeInFlight = false
end

local function stopOverride()
  if not ui.inOverride then return end
  ui.inOverride = false
  releaseAllMotors()
end

local function queueOverrideRead()
  if ui.runtime.readPending then return false end
  local queue = getQueue()
  if not queue or not MotorOverrideApi then return false end

  local StatusApi = loadModule("tasks/msp/api/status.lua")
  if not StatusApi then return false end

  ui.runtime.readPending = true
  ui.loading = true
  ui.progress = 0
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end

  local function finish()
    ui.runtime.readPending = false
    ui.loading = false
    ui.loaded = true
    ui.progress = 100
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: how many motors this board has.
  queue:add({
    command = StatusApi.command,
    simulatorResponse = StatusApi.simulatorResponse,
    processReply = function(_, statusBuf)
      local status = StatusApi.parse(statusBuf)
      if status then
        ui.motorCount = status.motor_count or 0
      end
      if ui.selected >= effectiveMotorCount() then
        ui.selected = 0
      end

      ui.progress = 50
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      -- Step 2: what the board is overriding right now. Normally nothing, and a value that is
      -- not nothing is worth showing rather than replacing silently.
      queue:add({
        command = MotorOverrideApi.command,
        simulatorResponse = MotorOverrideApi.simulatorResponse,
        processReply = function(_, overrideBuf)
          local values = MotorOverrideApi.parse(overrideBuf)
          if values then
            for i = 0, effectiveMotorCount() - 1 do
              local value = tonumber(values["motor_" .. (i + 1)]) or 0
              if value < 0 then value = 0 end
              ui.percent[i] = math.floor(value * 100 / MotorOverrideApi.OVERRIDE_MAX)
            end
          end
          finish()
        end,
        errorHandler = function()
          finish()
        end
      })
    end,
    errorHandler = function()
      finish()
    end
  })

  return true
end

local function ensureLoaded()
  if ui.loaded or ui.runtime.readPending then return end
  queueOverrideRead()
end

--- The dialog in front of a motor that is about to turn, and the one that hands it back.
local function requestOverride(i18n, enabled)
  if not ConfirmDialog then return end

  local title, message
  if enabled then
    title = pageText(i18n, "motor_override_enable", "Enable motor override")
    message = pageText(i18n, "motor_override_enable_msg",
      "The flight controller drives the motor directly. Remove the blades, secure the craft "
      .. "and stand clear.")
  else
    title = pageText(i18n, "motor_override_disable", "Disable motor override")
    message = pageText(i18n, "motor_override_disable_msg",
      "Return control of the motor to the flight controller.")
  end

  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      if enabled then
        for i = 0, effectiveMotorCount() - 1 do
          ui.percent[i] = 0
        end
        ui.writeInFlight = false
        ui.lastWriteAt = 0
        ui.inOverride = true
      else
        stopOverride()
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    onCancel = function()
      -- The switch draws itself in the new position the moment it is touched, so a cancel has
      -- to put the page back rather than only leaving the state alone.
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

function M.onLoad()
  ensureDeps()
end

function M.onActivate()
  ensureDeps()
end

function M.wakeup(ctx)
  ensureDeps()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local session = getSession()
  local signature = session and session.signature or nil
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    ui.inOverride = false
    ui.percent = {}
  end

  ensureLoaded()

  if not ui.inOverride then return end

  -- A link that has gone takes the override with it: nothing can be written any more, so the
  -- deadline on the board ends it, and the switch on screen must not go on claiming otherwise.
  local mspState = getMspState()
  if mspState and mspState.lastConnected == false then
    ui.inOverride = false
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
    return
  end

  local now = nowSeconds()
  if ui.writeInFlight and (now - ui.lastWriteAt) < WRITE_GIVE_UP then return end
  if (now - ui.lastWriteAt) < REFRESH_INTERVAL then return end

  writeOverride(ui.selected, ui.percent[ui.selected] or 0)
end

function M.getHeaderActions()
  return {
    help = true,
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

  local title = pageText(i18n, "title_motor_override", "Motor Override")

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = "@i18n(app.loading)@",
      message = pageText(i18n, "loading_motor_override", "Reading motor override..."),
      progress = ui.progress / 100
    })
    return
  end

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

  children[#children + 1] = {
    type = "label",
    x = x, y = cursorY,
    w = w,
    text = pageText(i18n, "motor_override_note",
      "Blades off and the craft secured. The motor turns as soon as the throttle leaves zero."),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  cursorY = cursorY + (Controls.LABEL_H or 20) + 8

  local motorCount = effectiveMotorCount()

  -- The motor is chosen before the override is enabled. Changing it under an active override
  -- would leave the motor that is turning with nothing to refresh it: it would stop, but a
  -- second later and without the page ever having said so.
  if motorCount > 1 then
    local options = {}
    for i = 1, motorCount do
      options[#options + 1] = {
        label = pageText(i18n, "motor", "Motor") .. " " .. i,
        value = i - 1
      }
    end

    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "motor", "Motor"),
      options,
      ui.selected,
      function(value)
        if ui.selected ~= value then
          ui.selected = value
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

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "motor_override_enable", "Enable motor override"),
    function() return ui.inOverride end,
    function(enabled)
      requestOverride(i18n, enabled)
    end
  )

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "motor_override_throttle", "Throttle"),
    {
      min = 0,
      max = MAX_PERCENT,
      step = 1,
      suffix = "%",
      active = function() return ui.inOverride end,
      get = function() return ui.percent[ui.selected] or 0 end,
      set = function(value)
        -- Recorded here and sent by the refresh that is running anyway. A write per wheel
        -- click would queue faster than the wire drains.
        ui.percent[ui.selected] = value
      end
    }
  )
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/esc_motors/motor_override/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end

function M.allowMemAutoRefresh()
  return true
end

--- Every route off this page ends here: back, a page switch, the tool closing, and the module
--- being evicted from the page cache. What it cannot cover -- the script being killed, the
--- link dropping, a crash -- is covered by the flight controller instead, which forgets an
--- override one second after the last write.
function M.onClose()
  stopOverride()

  ui.loaded = false
  ui.loading = false
  ui.percent = {}
  ui.motorCount = 0
  ui.selected = 0
  ui.writeInFlight = false
  ui.runtime.readPending = false
  ui.runtime.requestRebuild = nil
  ui.runtime.syncHeaderTitle = nil
  ui.runtime.lastSessionSignature = nil

  Controls = nil
  Common = nil
  MspRuntime = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  MotorOverrideApi = nil
  t = nil
end

return M
