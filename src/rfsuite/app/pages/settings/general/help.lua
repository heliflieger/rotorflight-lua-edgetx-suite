return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_general.help_message")
    or "Configure safety prompts, preview features and developer visibility in general settings. A preview feature is already "
    .. "in the suite but not finished: it stays hidden until it is switched on here."

  return { message = message }
end
