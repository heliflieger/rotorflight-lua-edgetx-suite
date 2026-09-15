return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_power_alerts.help_message")
    or "Configure timer and voltage alerts used for battery warning behavior."

  return {
    message = message
  }
end