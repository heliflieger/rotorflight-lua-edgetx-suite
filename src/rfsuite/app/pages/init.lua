local function definePage(path)
  return {
    pagePath = path .. "/page.lua",
    iconPath = path .. "/icon.png"
  }
end

local entries = {
  settings_general_page = definePage("settings/general"),
  developer_msp_speed_page = definePage("developer/msp_speed"),
  developer_api_tester_page = definePage("developer/api_tester"),
  developer_settings_page = definePage("developer/developer_settings"),
  developer_msp_experiments_page = definePage("developer/msp_experiments"),
  --settings_shortcuts_page = definePage("settings/shortcuts"),
  settings_dashboard_theme_page = definePage("settings/dashboard/theme"),
  settings_dashboard_settings_page = definePage("settings/dashboard/settings"),
  --settings_activelook_page = definePage("settings/activelook"),
  settings_localization_page = definePage("settings/localization"),
  settings_audio_page = definePage("settings/audio"),
  settings_audio_events_page = definePage("settings/audio/events"),
  settings_audio_events_arming_page = definePage("settings/audio/events/arming"),
  settings_audio_events_governor_page = definePage("settings/audio/events/governor"),
  settings_audio_events_voltage_page = definePage("settings/audio/events/voltage"),
  settings_audio_events_profiles_page = definePage("settings/audio/events/profiles"),
  settings_audio_events_esc_page = definePage("settings/audio/events/esc"),
  settings_audio_events_adjustment_page = definePage("settings/audio/events/adjustment"),
  settings_audio_events_fuel_page = definePage("settings/audio/events/fuel"),
  settings_audio_events_battery_page = definePage("settings/audio/events/battery"),
  settings_audio_events_other_page = definePage("settings/audio/events/other"),
  setup_wizard_page = definePage("setup_wizard"),
  -- The same page, entered under three names. Which name it was opened under is what bounds the
  -- run to one section, and the page reads that off the menu rather than being told.
  setup_wizard_radio_page = definePage("setup_wizard"),
  setup_wizard_board_page = definePage("setup_wizard"),
  setup_configuration_page = definePage("setup/configuration"),
  setup_radio_config_page = definePage("setup/radio_config"),
  setup_model_page = definePage("setup/model"),
  setup_power_battery_page = definePage("setup/power/battery"),
  setup_power_alerts_page = definePage("setup/power/alerts"),
  setup_power_sources_page = definePage("setup/power/sources"),
  setup_power_smartfuel_page = definePage("setup/power/smartfuel"),
  setup_power_preferences_page = definePage("setup/power/preferences"),
  flight_tuning_pids_page = definePage("flight_tuning/pids"),
  flight_tuning_rates_page = definePage("flight_tuning/rates"),
  flight_tuning_advanced_rescue_page = definePage("flight_tuning/advanced/rescue"),
  flight_tuning_advanced_tail_rotor_page = definePage("flight_tuning/advanced/tail_rotor"),
  flight_tuning_advanced_main_rotor_page = definePage("flight_tuning/advanced/main_rotor"),
  flight_tuning_advanced_filters_page = definePage("flight_tuning/advanced/filters"),
  flight_tuning_advanced_pid_controller_page = definePage("flight_tuning/advanced/pid_controller"),
  flight_tuning_advanced_pid_bandwidth_page = definePage("flight_tuning/advanced/pid_bandwidth"),
  flight_tuning_advanced_autolevel_page = definePage("flight_tuning/advanced/autolevel"),
  flight_tuning_advanced_rates_advanced_advanced_page = definePage("flight_tuning/advanced/rates_advanced/advanced"),
  flight_tuning_advanced_rates_advanced_cyclic_behaviour_page = definePage("flight_tuning/advanced/rates_advanced/cyclic_behaviour"),
  flight_tuning_advanced_rates_advanced_table_page = definePage("flight_tuning/advanced/rates_advanced/table"),
  flight_tuning_governor_page = definePage("flight_tuning/governor"),
  setup_telemetry_page = definePage("setup/telemetry"),
  setup_accelerometer_page = definePage("setup/accelerometer"),
  setup_alignment_page = definePage("setup/alignment"),
  setup_ports_page = definePage("setup/ports"),
  setup_gps_page = definePage("setup/gps"),
  setup_mixer_swash_page = definePage("setup/mixer/swash"),
  setup_mixer_swashgeometry_page = definePage("setup/mixer/swashgeometry"),
  setup_mixer_tail_page = definePage("setup/mixer/tail"),
  setup_mixer_trims_page = definePage("setup/mixer/trims"),
  setup_servos_pwm_page = definePage("setup/servos/pwm"),
  setup_servos_bus_page = definePage("setup/servos/bus"),
  setup_controls_modes_page = definePage("setup/controls/modes"),
  setup_controls_adjustments_page = definePage("setup/controls/adjustments"),
  setup_controls_failsafe_page = definePage("setup/controls/failsafe"),
  setup_controls_beepers_page = definePage("setup/controls/beepers"),
  setup_controls_beepers_configuration_page = definePage("setup/controls/beepers/configuration"),
  setup_controls_beepers_dshot_page = definePage("setup/controls/beepers/dshot"),
  setup_controls_blackbox_page = definePage("setup/controls/blackbox"),
  setup_controls_blackbox_configuration_page = definePage("setup/controls/blackbox/configuration"),
  setup_controls_blackbox_logging_page = definePage("setup/controls/blackbox/logging"),
  setup_controls_blackbox_status_page = definePage("setup/controls/blackbox/status"),
  setup_controls_stats_page = definePage("setup/controls/stats"),
  setup_esc_motors_throttle_page = definePage("setup/esc_motors/throttle"),
  setup_esc_motors_telemetry_page = definePage("setup/esc_motors/telemetry"),
  setup_esc_motors_rpm_page = definePage("setup/esc_motors/rpm"),
  setup_esc_motors_motor_override_page = definePage("setup/esc_motors/motor_override"),
  setup_esc_motors_esc_tools_page = definePage("setup/esc_motors/esc_tools"),
  setup_esc_motors_esc_tools_am32_page = definePage("setup/esc_motors/esc_tools/escmfg/am32"),
  setup_esc_motors_esc_tools_blheli_s_page = definePage("setup/esc_motors/esc_tools/escmfg/blheli_s"),
  setup_esc_motors_esc_tools_bluejay_page = definePage("setup/esc_motors/esc_tools/escmfg/bluejay"),
  setup_esc_motors_esc_tools_flrtr_page = definePage("setup/esc_motors/esc_tools/escmfg/flrtr"),
  setup_esc_motors_esc_tools_hw5_page = definePage("setup/esc_motors/esc_tools/escmfg/hw5"),
  setup_esc_motors_esc_tools_omp_page = definePage("setup/esc_motors/esc_tools/escmfg/omp"),
  setup_esc_motors_esc_tools_scorp_page = definePage("setup/esc_motors/esc_tools/escmfg/scorp"),
  setup_esc_motors_esc_tools_xdfly_page = definePage("setup/esc_motors/esc_tools/escmfg/xdfly"),
  setup_esc_motors_esc_tools_yge_page = definePage("setup/esc_motors/esc_tools/escmfg/yge"),
  setup_esc_motors_esc_tools_ztw_page = definePage("setup/esc_motors/esc_tools/escmfg/ztw"),
  setup_esc_motors_esc_tool_run_page = definePage("setup/esc_motors/esc_tools/run"),
  setup_governor_general_page = definePage("setup/governor/general"),
  setup_governor_time_page = definePage("setup/governor/time"),
  setup_governor_filters_page = definePage("setup/governor/filters"),
  setup_governor_curves_page = definePage("setup/governor/curves"),
  tools_select_profile_page = definePage("tools/select_profile"),
  tools_copy_profiles_page = definePage("tools/copy_profiles"),
  -- Disabled for now since the FBL Sensor page is not fully implemented and we don't want users to get confused by a page that doesn't work yet. Will re-enable once the page is ready to be used.
  -- diagnostics_fblsensors_page = definePage("tools/diagnostics/fblsensors"),
  diagnostics_fblstatus_page = definePage("tools/diagnostics/fblstatus"),
  diagnostics_rfstatus_page = definePage("tools/diagnostics/rfstatus"),
  diagnostics_elrs_link_page = definePage("tools/diagnostics/elrs_link"),
  diagnostics_validate_sensors_page = definePage("tools/diagnostics/validate_sensors"),
  diagnostics_smartfuel_page = definePage("tools/diagnostics/smartfuel"),
  diagnostics_session_logs_page = definePage("tools/diagnostics/session_logs"),
  diagnostics_info_page = definePage("tools/diagnostics/info"),
  logs_page = definePage("logs")
}

local registry = {}
local loadedByMenuId = {}
local loadedByPagePath = {}
local iconByMenuId = {}
local pagePathByMenuId = {}
local cacheOrder = {}
local MAX_CACHED_PAGE_MODULES = 2
local closePageModule

local function isDynamicDashboardSettingsPage(menuId)
  if type(menuId) ~= "string" then return false end
  return string.match(menuId, "^settings_dashboard_settings_[0-9a-f]+_page$") ~= nil
end

local function isCacheableMenuId(menuId)
  -- Dynamic dashboard settings IDs can grow over time; do not retain them.
  return not isDynamicDashboardSettingsPage(menuId)
end

local function touchCache(menuId)
  for i = #cacheOrder, 1, -1 do
    if cacheOrder[i] == menuId then
      table.remove(cacheOrder, i)
      break
    end
  end
  cacheOrder[#cacheOrder + 1] = menuId
end

local function removeFromCacheOrder(menuId)
  for i = #cacheOrder, 1, -1 do
    if cacheOrder[i] == menuId then
      table.remove(cacheOrder, i)
    end
  end
end

local function evictIfNeeded(keepMenuId, ctx)
  while #cacheOrder > MAX_CACHED_PAGE_MODULES do
    local victim = table.remove(cacheOrder, 1)
    if victim and victim ~= keepMenuId then
      closePageModule(victim, ctx)
    end
  end
end

local function loadPageModule(menuId)
  local entry = entries[menuId]
  if not entry and isDynamicDashboardSettingsPage(menuId) then
    entry = entries.settings_dashboard_settings_page
    iconByMenuId[menuId] = entry.iconPath
    pagePathByMenuId[menuId] = entry.pagePath
  end
  if not entry then
    return nil
  end

  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. entry.pagePath

  -- Special cache for dashboard settings page: always cache by file path
  if entry.pagePath == "settings/dashboard/settings/page.lua" then
    if loadedByPagePath[fullPath] then
      return loadedByPagePath[fullPath]
    end
    local chunk = assert(loadScript(fullPath, "t"))
    local module = chunk()
    loadedByPagePath[fullPath] = module
    return module
  end

  local chunk = assert(loadScript(fullPath, "t"))
  local module = chunk()
  if isCacheableMenuId(menuId) then
    loadedByMenuId[menuId] = module
    touchCache(menuId)
  end
  return module
end

closePageModule = function(menuId, ctx)
  -- Special handling: dashboard settings page module is cached by file path
  local entry = entries[menuId]
  if not entry and isDynamicDashboardSettingsPage(menuId) then
    entry = entries.settings_dashboard_settings_page
  end
  if entry and entry.pagePath == "settings/dashboard/settings/page.lua" then
    local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. entry.pagePath
    local module = loadedByPagePath[fullPath]
    if type(module) == "table" then
      local hook = module.onClose or module.close or module.closePage or module.destroy
      if type(hook) == "function" then
        pcall(hook, ctx or {})
      end
      loadedByPagePath[fullPath] = nil
      return true
    end
    return false
  end
  -- Default: cache by menuId
  local module = loadedByMenuId[menuId]
  if type(module) ~= "table" then
    loadedByMenuId[menuId] = nil
    removeFromCacheOrder(menuId)
    return false
  end
  local hook = module.onClose or module.close or module.closePage or module.destroy
  if type(hook) == "function" then
    pcall(hook, ctx or {})
  end
  loadedByMenuId[menuId] = nil
  removeFromCacheOrder(menuId)
  return true
end

for menuId, entry in pairs(entries) do
  iconByMenuId[menuId] = entry.iconPath
  pagePathByMenuId[menuId] = entry.pagePath
end

function registry.get(menuId)
  if type(menuId) ~= "string" or menuId == "" then
    return nil
  end

  local module = loadedByMenuId[menuId]
  if module ~= nil then
    touchCache(menuId)
    return module
  end

  local loaded = loadPageModule(menuId)
  if loaded and isCacheableMenuId(menuId) then
    evictIfNeeded(menuId)
  end
  return loaded
end

function registry.release(menuId, ctx)
  local released = false
  if not isCacheableMenuId(menuId) then
    released = closePageModule(menuId, ctx)
  else
    local module = loadedByMenuId[menuId]
    if type(module) == "table" then
      local hook = module.onClose or module.close or module.closePage or module.destroy
      if type(hook) == "function" then
        pcall(hook, ctx or {})
      end
      released = true
    end
  end
  -- Do NOT force collectgarbage() here.
  -- Forcing GC before lvgl.build() replaces the scene can collect Lua closures
  -- that LVGL still holds raw references to, causing a crash in lvgl.build().
  return released
end

function registry.releaseAll(ctx)
  local released = false
  for menuId in pairs(loadedByMenuId) do
    if closePageModule(menuId, ctx) then
      released = true
    end
  end

  return released
end

registry.byMenuId = setmetatable({}, {
  __index = function(_, menuId)
    return registry.get(menuId)
  end
})

registry.iconByMenuId = iconByMenuId
registry.pagePathByMenuId = pagePathByMenuId

return registry