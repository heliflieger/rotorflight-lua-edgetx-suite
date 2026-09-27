return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_localization.help_message")
    or "Leave the language on automatic to follow the card or the radio, or choose one. Also sets the unit formats."

  return {
    message = message
  }
end
