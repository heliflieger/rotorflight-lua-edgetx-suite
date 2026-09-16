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
  local t = Common and Common.pageT("setup_gps") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "GPS is used for telemetry only. Return to home and other autopilot features are not available.")
  local help_p2 = t(i18n, "help_p2", "Turn the GPS feature on under Configuration and give the receiver a serial port under Ports, including its baud rate.")
  local help_p3 = t(i18n, "help_p3", "Auto-config lets the flight controller set the receiver up over the serial link. SBAS mode and Galileo are part of that sequence and only apply to a u-blox receiver.")
  local help_p4 = t(i18n, "help_p4", "Saving writes these values to EEPROM and reboots the flight controller.")

  local parts = { help_p1, help_p2, help_p3, help_p4 }

  return {
    title = t(i18n, "help_title", "GPS Help"),
    message = table.concat(parts, "\n\n")
  }
end
