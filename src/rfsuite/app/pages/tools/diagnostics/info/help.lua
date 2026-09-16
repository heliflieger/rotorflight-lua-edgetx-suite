return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_info.help_message")
    or "Shows firmware, board, transport, and link information read from the flight controller and runtime."

  return { message = message }
end
