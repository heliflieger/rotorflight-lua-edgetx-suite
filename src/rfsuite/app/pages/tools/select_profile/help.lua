return function(ctx)
  local i18n = ctx and ctx.i18n or nil

  local title = i18n and i18n.t and i18n.t("app.pages.diagnostics_profile_select.help_title")
    or "Select Profile"
  local p1 = i18n and i18n.t and i18n.t("app.pages.diagnostics_profile_select.help_p1")
    or "Switch active PID and Rate profiles."
  local p2 = i18n and i18n.t and i18n.t("app.pages.diagnostics_profile_select.help_p2")
    or "The display updates automatically on external changes."

  return {
    title = title,
    message = p1 .. "\n\n" .. p2
  }
end
