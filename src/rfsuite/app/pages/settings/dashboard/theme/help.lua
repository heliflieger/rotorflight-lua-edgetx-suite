return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_theme.help_message")
    or "Choose one dashboard theme for the connected model and one for everything else. The model's theme is used whenever it is set; Disabled falls back to the general one. A theme covers all three flight phases itself. Per-Phase Themes adds an inflight and a postflight override to each of the two. Left at 'Use theme above', the phase keeps the theme above it, so an override changes only the phase it names."
  
  return {
    message = message
  }
end
