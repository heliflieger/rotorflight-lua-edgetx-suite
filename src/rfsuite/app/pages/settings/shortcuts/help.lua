return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_shortcuts.help_message")
    or "Review shortcut mappings and quick access behavior for faster navigation."

  return { message = message }
end
