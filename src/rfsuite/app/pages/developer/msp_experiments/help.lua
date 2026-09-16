return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.developer_msp_experiments.help_message")
    or "Use this page to inspect and edit experimental MSP bytes for testing."

  return { message = message }
end
