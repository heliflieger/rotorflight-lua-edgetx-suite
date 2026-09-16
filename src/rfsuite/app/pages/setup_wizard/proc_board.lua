-- The board section of the setup assistant, as PROCEDURES: the name, the mounting orientation and
-- the accelerometer calibration.
--
-- The order is a dependency and not a convenience. The firmware applies the sensor rotation BEFORE
-- it runs the calibration, so calibrating against an orientation that is not yet active produces
-- trims for the wrong one. Anything else in this section could be reordered freely; these two
-- could not.
--
-- The physical precondition belongs to the PROCEDURE and never to a section screen, because a
-- procedure can be reached on its own and the pilot who jumps straight to it never saw the
-- section. So each one states its own, on its own first screen.
--
-- None of the three has a completion criterion the machine can answer -- any craft name is a valid
-- craft name, any orientation is a valid orientation, and a calibration that has run leaves no
-- mark. All three are therefore offered every time and closed only by the pilot saying so, which
-- is exactly what the stored *deliberately skipped* is for.

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = loadModule("app/pages/settings/common.lua")
local Controls = loadModule("ui/controls.lua")
local t = Common and Common.pageT("setup_wizard") or function(_, _, fb) return fb end

local procs = {}

-- The mounting orientations the firmware knows, in its own numbering. Zero is what a board ships
-- with and is offered as such rather than being silently turned into a rotation.
local function alignmentOptions(i18n)
  return {
    { value = 0, label = t(i18n, "align_default", "Default") },
    { value = 1, label = t(i18n, "align_cw_0", "CW 0 deg") },
    { value = 2, label = t(i18n, "align_cw_90", "CW 90 deg") },
    { value = 3, label = t(i18n, "align_cw_180", "CW 180 deg") },
    { value = 4, label = t(i18n, "align_cw_270", "CW 270 deg") },
    { value = 5, label = t(i18n, "align_cw_0_flip", "CW 0 deg flip") },
    { value = 6, label = t(i18n, "align_cw_90_flip", "CW 90 deg flip") },
    { value = 7, label = t(i18n, "align_cw_180_flip", "CW 180 deg flip") },
    { value = 8, label = t(i18n, "align_cw_270_flip", "CW 270 deg flip") }
  }
end

-- 1 -- the craft name. Written at once rather than collected, and that is not an inconsistency
-- with the radio section: collecting exists there because arming without a throttle hold is a
-- hazardous pair. The name has no partner and its intermediate state is the old name.
procs[#procs + 1] = {
  id = "name",
  section = "board",
  skippable = true,
  title = function(i18n) return t(i18n, "step_name", "Name") end,
  enter = function(w)
    w.data.name = w.data.name or { loaded = false }
    w.msp.read("name", function(parsed)
      local state = w.data.name
      state.value = parsed and parsed.name or ""
      state.original = state.value
      state.loaded = true
      w.rebuild()
    end)
  end,
  screens = {
    {
      id = "name",
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y
        local state = w.data.name or {}

        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "name_intro", "The name the flight controller reports. The suite can name the transmitter model after it.")) + 8

        if not state.loaded then
          w.row(children, area.x, y, area.w, t(i18n, "field_name", "Craft name"), t(i18n, "state_reading", "reading..."), nil)
          return
        end

        Controls.appendTextField(children, area.x, y, area.w, t(i18n, "field_name", "Craft name"), {
          get = function() return w.data.name.value or "" end,
          set = function(value) w.data.name.value = tostring(value or "") end,
          length = 16
        })
      end,
      advance = function(w, done)
        local state = w.data.name or {}
        local api = w.msp.api("name")
        if not state.loaded or state.value == state.original or not api then
          done(true)
          return
        end
        w.setBusy(t(w.i18n, "writing_title", "Writing"), t(w.i18n, "field_name", "Craft name"))
        w.msp.sequence({
          function(nextStep)
            w.msp.write(api.writeCommand, api.buildWritePayload({ name = state.value }),
              function(ok) nextStep(ok) end)
          end,
          function(nextStep) w.msp.commit(function(ok) nextStep(ok) end) end
        }, function(ok) done(ok) end)
      end
    }
  }
}

-- 2 -- the mounting orientation. Only the discrete rotation is offered here, because that is the
-- one the calibration in the next procedure depends on; the fine board-alignment trim in degrees
-- is a different question and stays on its own page.
--
-- A change takes effect at the next start of the flight controller, so this procedure says so
-- rather than pretending otherwise. Where nothing changes -- the normal case -- the assistant
-- carries straight on.
procs[#procs + 1] = {
  id = "alignment",
  section = "board",
  skippable = true,
  title = function(i18n) return t(i18n, "step_alignment", "Orientation") end,
  enter = function(w)
    w.data.alignment = w.data.alignment or { loaded = false }
    w.msp.read("sensor_alignment", function(parsed)
      local values = parsed and parsed.parsed or nil
      local state = w.data.alignment
      state.value = values and tonumber(values.gyro_1_alignment) or 0
      state.original = state.value
      state.gyro2 = values and tonumber(values.gyro_2_alignment) or 0
      state.mag = values and tonumber(values.mag_alignment) or 0
      state.loaded = true
      w.rebuild()
    end)
  end,
  screens = {
    {
      id = "orientation",
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y
        local state = w.data.alignment or {}

        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "alignment_intro", "Needed before the calibration: the flight controller mounted in the machine, and the machine level.")) + 8

        if not state.loaded then
          w.row(children, area.x, y, area.w, t(i18n, "field_orientation", "Orientation"), t(i18n, "state_reading", "reading..."), nil)
          return
        end

        y = y + Controls.appendComboSelect(children, area.x, y, area.w,
          t(i18n, "field_orientation", "Orientation"), alignmentOptions(i18n), state.value,
          function(value) w.data.alignment.value = tonumber(value) or 0 end)

        if state.value ~= state.original then
          w.paragraph(children, area.x, y + 6, area.w, t(i18n, "alignment_reboot", "A change takes effect after the flight controller restarts. Start the assistant again to continue."))
        end
      end,
      advance = function(w, done)
        local state = w.data.alignment or {}
        local api = w.msp.api("sensor_alignment")
        local rebootApi = w.msp.api("reboot")
        if not state.loaded or state.value == state.original or not api then
          done(true)
          return
        end
        w.data.rebooted = true
        w.setBusy(t(w.i18n, "writing_title", "Writing"), t(w.i18n, "field_orientation", "Orientation"))
        w.msp.sequence({
          function(nextStep)
            w.msp.write(api.writeCommand, api.buildWritePayload({
              gyro_1_alignment = state.value,
              gyro_2_alignment = state.gyro2 or 0,
              mag_alignment = state.mag or 0
            }), function(ok) nextStep(ok) end)
          end,
          function(nextStep) w.msp.commit(function(ok) nextStep(ok) end) end,
          function(nextStep)
            if not rebootApi then nextStep(true) return end
            w.msp.write(rebootApi.writeCommand, rebootApi.buildWritePayload({ rebootMode = 0 }),
              function() nextStep(true) end)
          end
        }, function(ok) done(ok) end)
      end
    }
  }
}

-- 3 -- the accelerometer. Calibrate, and no reading of symptoms: a flight controller reporting an
-- angle is not evidence of an uncalibrated accelerometer, because some frames stand crooked by
-- construction.
procs[#procs + 1] = {
  id = "accelerometer",
  section = "board",
  skippable = true,
  title = function(i18n) return t(i18n, "step_accelerometer", "Accelerometer") end,
  enter = function(w)
    w.data.accel = w.data.accel or { done = false, failed = false }
    if w.data.rebooted then w.data.accel.blocked = true end
  end,
  screens = {
    {
      id = "calibrate",
      nextLabel = function(i18n) return t(i18n, "calibrate", "Calibrate") end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y
        local state = w.data.accel or {}

        if state.blocked then
          w.paragraph(children, area.x, y, area.w, t(i18n, "accel_blocked", "The orientation was changed and the flight controller is restarting. Calibrate after the restart."))
          return
        end

        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "accel_intro", "Flight controller mounted in the machine, machine level. Calibrating on a workbench calibrates the workbench.")) + 8

        local marker = t(i18n, "marker_open", "not run")
        if state.done then marker = t(i18n, "marker_done", "done") end
        if state.failed then marker = t(i18n, "marker_failed", "failed") end
        w.row(children, area.x, y, area.w, t(i18n, "field_calibration", "Calibration"), "", marker)
      end,
      advance = function(w, done)
        local state = w.data.accel or {}
        if state.blocked or state.done then
          done(true)
          return
        end
        w.setBusy(t(w.i18n, "calibrating_title", "Calibrating"), t(w.i18n, "calibrating_message", "Keep the model level and still"))
        w.msp.sequence({
          -- MSP_ACC_CALIBRATION. The command has no API module of its own in the tree; the
          -- accelerometer page issues the same bare command.
          function(nextStep) w.msp.write(205, {}, function(ok) nextStep(ok) end) end,
          function(nextStep) w.msp.commit(function(ok) nextStep(ok) end) end
        }, function(ok)
          w.data.accel.done = ok == true
          w.data.accel.failed = ok ~= true
          -- A failed calibration does not block the path: what it costs is the tick, and the
          -- review says so rather than the run stopping on it.
          done(true)
        end)
      end
    }
  }
}

-- There is deliberately no review here. The path's review belongs to SIGN-OFF -- the section that
-- collects the checks which only mean anything on an assembled machine -- and this part covers the
-- radio and the board basics, which are two sections of seven. A closing screen at the end of
-- section two would present a third of the path as the whole of it.

return procs
