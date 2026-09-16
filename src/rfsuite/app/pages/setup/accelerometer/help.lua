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
  local t = Common and Common.pageT("setup_accelerometer") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "The accelerometer is used to measure the angle of the flight controller in relation to the horizon. This data is used to stabilize the aircraft and provide self-leveling functionality.")
  local help_p2 = t(i18n, "help_p2", "Saving writes these values to EEPROM.")

  local help_p3 = t(i18n, "help_p3",
    "Disarm and hold the model level and still before confirming. Keep it still until completion; saving is automatic.")

  local help_p4 = t(i18n, "help_p4",
    "Checking precedes start. Missing samples keep monitoring active; the completion window starts at the start acknowledgement.")

  local help_p5 = t(i18n, "help_p5",
    "Without a completion notice, success is unconfirmed. The notice explains what was observed.")

  local parts = { help_p1, help_p2, help_p3, help_p4, help_p5 }

  return {
    title = t(i18n, "help_title", "Accelerometer Help"),
    message = table.concat(parts, "\n\n")
  }
end
