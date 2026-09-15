return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.developer_api_tester.help_message")
    or "Select an MSP API and run live read tests to inspect parsed responses and errors."

  return { message = message }
end
