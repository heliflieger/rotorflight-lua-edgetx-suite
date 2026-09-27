-- The translator reaches this sheet through the house form: a `pageT` call the i18n precompiler
-- can derive a prefix from, and a wrapper named `t`, which is one of the two call names the
-- precompiler's pattern knows. A hand-rolled wrapper spelled anything else is a runtime lookup
-- only, and a packaged card carries no locale bundle, so the sheet would ship its English
-- fallbacks into a German install (#284).
local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("setup_controls_inflight") or function(_, _, fb) return fb end
  local i18n = ctx and ctx.i18n or nil

  local intro = t(i18n, "help_message",
    "The flight controller's half: which parameters it offers, how far one press moves them, and where the undo lives.")

  -- Two switches, and the one on this page is the smaller of them. A pilot who turns this on and
  -- finds nothing happening is looking at the master, which is on the radio.
  local enabled = t(i18n, "help_enabled",
    "The switch at the top is this machine's own. The radio carries the master, and both have to be on.")

  -- The one button here that changes anything on the board, and the one thing about it that is
  -- not obvious: it overwrites a slot whichever switch that slot belongs to.
  local setupFc = t(i18n, "help_setup_fc",
    "Writes the standard set into the adjustment slots, after showing what it overwrites. Standard layout only.")

  -- The steps are written INTO the slots, so changing one on the radio and not on the board leaves
  -- the two disagreeing -- which the compare then reports, correctly and unhelpfully, unless the
  -- pilot has been told which button puts it right.
  local step = t(i18n, "help_step",
    "The steps are part of every slot, so a change needs the flight controller set up again. The head speed has its own.")

  -- The undo. It exists BEFORE the flight or not at all: the board writes an in-flight change to
  -- its own storage half a second after disarm, and there is nothing left to copy afterwards.
  local undo = t(i18n, "help_undo",
    "The backup is taken by itself when the interlock is switched on, once per PID profile, and only while disarmed.")

  local pointer = t(i18n, "help_pointer",
    "The switch, the channels, the variables and the trims are in Settings > Dashboard > In-Flight Tuning.")

  return {
    message = intro .. "\n\n" .. enabled .. "\n\n" .. step .. "\n\n" .. undo .. "\n\n"
      .. setupFc .. "\n\n" .. pointer
  }
end
