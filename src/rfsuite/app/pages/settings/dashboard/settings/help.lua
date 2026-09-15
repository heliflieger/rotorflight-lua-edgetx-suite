return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.help_message")
    or "Configure settings exposed by the selected dashboard theme."

  return { message = message }
end
