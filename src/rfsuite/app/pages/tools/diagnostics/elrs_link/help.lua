return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_elrs_link.help_message")
    or "Compares the packet rate and telemetry ratio of the ExpressLRS transmitter module with the link rate and ratio the flight controller was configured for. Probe only reads. RF -> ELRS writes the module to match the flight controller; ELRS -> RF writes the flight controller and saves it. Both ask before they write."

  return { message = message }
end
