return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_rfstatus.help_message")
    or "Shows runtime health, link state, and telemetry sensor validation status."

  return { message = message }
end
