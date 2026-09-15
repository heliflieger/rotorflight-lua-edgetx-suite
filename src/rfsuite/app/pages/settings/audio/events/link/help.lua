return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_audio_events_link.help_message") or "No help message available."

  return {
    message = message
  }
end
