return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_model.help_message")
    or "Settings the flight controller stores for this model: three parameters it applies to the radio's timers or global variables on connect, and the radio-side features it asks for."

  return { message = message }
end
