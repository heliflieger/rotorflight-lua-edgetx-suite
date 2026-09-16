return function(ctx)
  local i18n = ctx and ctx.i18n or nil

  local title = i18n and i18n.t and i18n.t("app.pages.tools_copy_profiles.help_title")
    or "Copy Profile"
  local p1 = i18n and i18n.t and i18n.t("app.pages.tools_copy_profiles.help_p1")
    or "Copy settings between profiles."
  local p2 = i18n and i18n.t and i18n.t("app.pages.tools_copy_profiles.help_p2")
    or "Select the type (PID or Rate) and the source/destination profiles."

  return {
    title = title,
    message = p1 .. "\n\n" .. p2
  }
end
