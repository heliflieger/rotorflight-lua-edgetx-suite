-- The close of the part of the path this assistant covers.
--
-- It is NOT the review. The review belongs to sign-off, where the machine is assembled and the
-- checks it collects can mean something; one here would have to tick procedures whose subject
-- does not exist yet, and a tick the assistant cannot have earned is worse than no tick at all.
-- So there is no derived mark on this screen.
--
-- What it does carry is the other half, and it is the half a pilot is normally not told: what
-- this run did NOT cover. An assistant that ends in silence has told the pilot they are finished,
-- and the machine at this point cannot be spooled up safely -- the drivetrain, the servos and the
-- mechanics are all still at their defaults.

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = loadModule("app/pages/settings/common.lua")
local t = Common and Common.pageT("setup_wizard") or function(_, _, fb) return fb end

local procs = {}

procs[#procs + 1] = {
  id = "close",
  -- Its own section, so the heading does not claim it belongs to the flight controller, and
  -- uncounted, so it never appears on the overview as a piece of work with a state.
  section = "close",
  counted = false,
  title = function(i18n) return t(i18n, "step_close", "Done for now") end,
  screens = {
    {
      id = "done",
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        y = y + w.paragraph(children, area.x, y, area.w,
          t(i18n, "close_p1",
            "The transmitter and the basics on the flight controller are set. Anything you change later can be run again on its own from the list.")) + 8

        y = y + w.paragraph(children, area.x, y, area.w,
          t(i18n, "close_p2",
            "This machine is not ready to spool up. These parts are not covered here and are still at their defaults:")) + 6

        -- Name over list, not name beside list.
        --
        -- These four were rows, and a row's value column is a fifth of the page wide with no room
        -- to wrap: every one of the lists ran past its own column, on three of the four
        -- geometries. Found by measuring across the elements rather than only down them, which is
        -- a check this bench did not have until the section beside this one was walked on a
        -- radio. Written as a heading and a sentence, the list wraps and nothing is dropped from
        -- it -- and what is listed here is exactly what the pilot must not assume is configured.
        -- Written out, one call per line, and the repetition is the point.
        --
        -- These were briefly a table walked by a loop, which reads better and does not work: the
        -- build resolves `t(i18n, "key", "fallback")` where the key and the fallback are LITERAL
        -- and leaves anything else alone. Passed as `part[1]`, `part[2]` there is nothing at the
        -- call site to resolve, so the packaged German build showed every one of these in English
        -- -- and shipped that way. The rule is in the header of the file next to this one; a loop
        -- over the strings breaks it however tidy it looks.
        local function block(title, detail)
          y = y + w.row(children, area.x, y, area.w, title, nil, nil)
          y = y + 2 + w.paragraph(children, area.x, y + 2, area.w, detail)
        end

        block(t(i18n, "close_drivetrain", "Drivetrain"),
              t(i18n, "close_drivetrain_what", "ESC, motor, battery, throttle range, governor"))
        block(t(i18n, "close_servos", "Servos"),
              t(i18n, "close_servos_what", "output parameters, direction, centre"))
        block(t(i18n, "close_mechanics", "Mechanics"),
              t(i18n, "close_mechanics_what", "swashplate, pitch limits, tail"))
        block(t(i18n, "close_signoff", "Sign-off"),
              t(i18n, "close_signoff_what", "arming test, throttle hold, failsafe, telemetry"))

        -- Three settings this assistant cannot make, named rather than skipped.
        --
        -- They are not oversights and not "not yet": EdgeTX exposes no Lua interface for any of
        -- them in the firmware this suite runs on, and two of the three have none in the next one
        -- either. Read out of the bindings rather than assumed. A script CAN write the model file
        -- on the card, and that is not a way round it -- the radio holds the open model in memory
        -- and writes it back over the file when it closes.
        --
        -- So what is left is to say exactly what to set and where, which is what this assistant
        -- already does for everything else it cannot reach.
        y = y + 10 + w.paragraph(children, area.x, y + 10, area.w,
          t(i18n, "close_byhand", "These three are set by hand. The radio offers a script no way to set them."))

        block(t(i18n, "close_hand_screen", "Home screen"),
              t(i18n, "close_hand_screen_what",
                "Screen 1, layout 1x1, the suite's own widget in it"))
        block(t(i18n, "close_hand_throttle", "Throttle warning"),
              t(i18n, "close_hand_throttle_what",
                "Model setup: switch the throttle warning off"))
        block(t(i18n, "close_hand_armsw", "Arming switch"),
              t(i18n, "close_hand_armsw_what",
                "A function switch named ARM, two positions, starting off, red while armed"))
      end
    }
  }
}

return procs
