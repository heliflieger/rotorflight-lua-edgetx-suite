return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.help_message")
    or "The battery settings are used to configure the flight controller to monitor the battery voltage and provide warnings when the voltage drops below a certain level."

  return {
    message = message
  }
end
