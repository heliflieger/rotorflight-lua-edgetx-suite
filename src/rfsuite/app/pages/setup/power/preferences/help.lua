return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_power_preferences.help_message")
    or "Configure model type and local SmartFuel source preferences."

  return {
    message = message
  }
end