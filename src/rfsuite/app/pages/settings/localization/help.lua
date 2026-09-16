return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_localization.help_message")
    or "Configure language and unit formats used by RFSuite."

  return {
    message = message
  }
end
