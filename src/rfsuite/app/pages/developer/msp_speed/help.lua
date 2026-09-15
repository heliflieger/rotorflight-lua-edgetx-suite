return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.developer_msp_speed.help_message")
    or "Measure MSP link performance and inspect timing, retries, and timeout statistics."

  return { message = message }
end
