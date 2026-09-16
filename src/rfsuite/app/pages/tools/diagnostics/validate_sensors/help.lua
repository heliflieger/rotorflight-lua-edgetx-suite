return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_validate_sensors.help_message")
    or "Validates configured telemetry sensors by checking if they exist in radio telemetry and provide numeric values."

  return { message = message }
end
