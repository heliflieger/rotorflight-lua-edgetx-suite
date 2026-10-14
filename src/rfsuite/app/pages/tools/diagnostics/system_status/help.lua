return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "The flight controller's packed status sensors, decoded; read from the radio twice a second.\n"
    .. "System Status, System Config: Receiving, Not current, Not received or No sensor in this model.\n"
    .. "Sensor: the radio sensor read. Raw value: the word as it arrived.\n"
    .. "Shared fields: each value packed and from its own sensor (ARM, Gov, PID#, RTE#, BAT#); a mismatch shows (differs)."
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_system_status.help_message")
    or fallback

  return { message = message }
end
