return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_session_logs.help_message")
    or "Shows the last log lines this script kept in memory, newest at the bottom, coloured by level. The page updates itself as lines arrive, and RELOAD only draws it again. The list lives in memory and is gone when the script stops, so switch on Log Session To Card under Developer > Settings to keep a copy for a report."

  return { message = message }
end
