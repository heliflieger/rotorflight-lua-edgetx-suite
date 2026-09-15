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
  local t = Common and Common.pageT("setup_ports") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Configure the function and baud rate for each serial port on the flight controller.")
  local help_p2 = t(i18n, "help_p2", "Save writes changes to EEPROM and reboots the flight controller.")

  local help_p3 = t(i18n, "help_p3",
    "Where the board layout is known, a port is named as the board prints it, with its UART name in brackets.")

  local parts = { help_p1, help_p2, help_p3 }

  return {
    title = t(i18n, "help_title", "Ports Help"),
    message = table.concat(parts, "\n\n")
  }
end
