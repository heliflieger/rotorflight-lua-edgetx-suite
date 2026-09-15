return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_developer_settings.help_message")
    or "Configure logging and debugging options for development diagnostics."

  return { message = message }
end
