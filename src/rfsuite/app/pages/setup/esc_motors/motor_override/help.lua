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
  local t = Common and Common.pageT("setup_esc_motors") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1_motor_override",
    "Drive one motor directly, blades off, to check its direction or to teach an ESC its "
    .. "throttle range. The flight controller refuses the override while armed and stops the "
    .. "motor a second after the last command, so leaving this page stops it.")

  return {
    title = t(i18n, "help_title_motor_override", "Motor Override Help"),
    message = help_p1
  }
end
