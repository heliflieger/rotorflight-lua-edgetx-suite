-- Manifest for onconnect tasks (ordered)
return {
  "apiversion",
  "uid",
  "rtc",
  { name = "status", context = "both" },
  { name = "telemetry", context = "both" },
  { name = "flight_stats", context = "widget" },
  { name = "dataflash_summary", context = "widget" },
  { name = "battery_config", context = "both" },
  { name = "governor_config", context = "both" },
  { name = "esc_sensor_config", context = "tool" },
  { name = "smartfuel_config", context = "both" },
  { name = "name", context = "both" },
  -- The pilot config is read BEFORE the name is synchronised, because from MSP API 12.09 the
  -- flight controller's own MODEL_SET_NAME bit is what decides whether it is synchronised at
  -- all. One read serves both tasks; the order is what makes the flag available in time.
  --
  -- Both are `widget` rather than `both`, and that is about WHO MAY WRITE TO THE PILOT'S MODEL.
  -- These two are the only tasks here that reach outside the suite: they rename the radio's model
  -- and they write its timers and global variables. That is background work -- it belongs to
  -- whatever is running while the pilot flies, which is the dashboard and the service widget. The
  -- tool is a configurator, opened deliberately and closed again, and a model that changes because
  -- somebody looked at a settings page is a surprise nobody asked for.
  --
  -- It also removes a duplicate. Run in both contexts, the same rename is attempted twice per
  -- connect from two Lua states that cannot see each other's module state.
  { name = "model_params_sync", context = "widget" },
  -- After `name`, which fills session.modelName, and after the read above.
  { name = "model_name_sync", context = "widget" },
  -- Last, and `widget` for the same reason as the two above: it writes to the pilot's model.
  -- It waits on no reply at all and reads nothing off the session -- what it decides, the radio
  -- answers on its own -- so putting it behind everything that does wait costs the connect
  -- nothing, and it is the only ordering claim this entry makes.
  { name = "function_script", context = "widget" },
}
