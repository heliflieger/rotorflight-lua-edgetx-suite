return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_power_sources.help_message")
    or "Select which sources the flight controller uses for battery voltage and current measurements."

  return {
    message = message
  }
end
