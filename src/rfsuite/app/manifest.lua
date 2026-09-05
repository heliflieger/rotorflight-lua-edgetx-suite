local SYSTEM_THEMES_PATH = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/"
local USER_THEMES_PATH = "/SCRIPTS/TOOLS/rfsuite.user/dashboard/"

local function hexEncode(input)
  if type(input) ~= "string" then return "" end
  local result = ""
  for i = 1, string.len(input) do
    local byte = string.byte(input, i)
    result = result .. string.format("%02x", byte)
  end
  return result
end

-- Static manifest definition - themes are loaded dynamically at runtime
local manifest = {
  sections = {
    {
      id = "configuration",
      title = "@i18n(app.header_configuration)@",
      pages = {
        { id = "flight_tuning", title = "@i18n(app.modules.flight_tuning.name)@", menuId = "flight_tuning_menu", icon = "@pages/flight_tuning/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "setup", title = "@i18n(app.modules.setup.name)@", menuId = "setup_menu", icon = "@pages/setup/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "wizards", title = "@i18n(app.modules.wizards.name)@", menuId = "wizards_menu", icon = "@pages/setup/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true }
      }
    },
    {
      id = "system",
      title = "@i18n(app.header_system)@",
      pages = {
        { id = "tools", title = "@i18n(app.modules.tools.name)@", menuId = "tools_menu", icon = "@pages/tools/icon.png" },
        { id = "logs", title = "@i18n(app.modules.logs.name)@", menuId = "logs_page", icon = "@pages/logs/icon.png" },
        { id = "settings", title = "@i18n(app.modules.settings.name)@", menuId = "settings_admin", icon = "@pages/settings/icon.png" },
        { id = "developer", title = "@i18n(app.modules.developer.name)@", menuId = "developer_menu", icon = "@pages/developer/icon.png", enabledWhen = "developerTools", hideWhenDisabled = true }
      }
    }
  },
  menus = {
    tools_menu = {
      title = "@i18n(app.modules.tools.name)@",
      pages = {
        { id = "copy_profiles", title = "@i18n(app.modules.copyprofiles.name)@", menuId = "tools_copy_profiles_page", icon = "@pages/tools/copy.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "select_profile", title = "@i18n(app.modules.profile_select.name)@", menuId = "tools_select_profile_page", icon = "@pages/tools/select_profile.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "diagnostics", title = "@i18n(app.modules.diagnostics.name)@", menuId = "diagnostics_menu", icon = "@pages/tools/diagnostics.png" }
      }
    },
    diagnostics_menu = {
      title = "@i18n(app.modules.diagnostics.name)@",
      pages = {
        -- Disabled, did not know if we need this realy and the page is not fully implemented yet. Can be re-enabled later if needed.
        -- { id = "fblsensors", title = "@i18n(app.modules.fblsensors.name)@", menuId = "diagnostics_fblsensors_page", enabledWhen = "fblConnected" },
        { id = "fblstatus", title = "@i18n(app.modules.fblstatus.name)@", menuId = "diagnostics_fblstatus_page", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "rfstatus", title = "@i18n(app.modules.rfstatus.name)@", menuId = "diagnostics_rfstatus_page", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "elrs_link", title = "@i18n(app.modules.elrs_link.name)@", menuId = "diagnostics_elrs_link_page", lockedWhileArmed = true },
        { id = "validate_sensors", title = "@i18n(app.modules.validate_sensors.name)@", menuId = "diagnostics_validate_sensors_page", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "smartfuel", title = "@i18n(app.modules.smartfuel.name)@", menuId = "diagnostics_smartfuel_page", enabledWhen = "fblConnected", minApiVersion = { 12, 0, 9 }, lockedWhileArmed = true },
        { id = "session_logs", title = "@i18n(app.modules.session_logs.name)@", menuId = "diagnostics_session_logs_page" },
        { id = "info", title = "@i18n(app.modules.info.name)@", menuId = "diagnostics_info_page", lockedWhileArmed = true }
      }
    },
    flight_tuning_menu = {
      title = "@i18n(app.modules.flight_tuning.name)@",
      pages = {
        { id = "pids", title = "@i18n(app.modules.pids.name)@", menuId = "flight_tuning_pids_page", icon = "@pages/flight_tuning/pids/icon.png", lockedWhileArmed = true },
        { id = "rates", title = "@i18n(app.modules.rates.name)@", menuId = "flight_tuning_rates_page", icon = "@pages/flight_tuning/rates/icon.png", lockedWhileArmed = true },
        { id = "governor", title = "@i18n(app.modules.governor.name)@", menuId = "flight_tuning_governor_page", icon = "@pages/flight_tuning/governor/icon.png", minApiVersion = { 12, 0, 9 }, lockedWhileArmed = true },
        { id = "advanced", title = "@i18n(app.modules.advanced.name)@", menuId = "flight_tuning_advanced_menu", icon = "@pages/flight_tuning/advanced/icon.png", enabled = true }
      }
    },
    flight_tuning_advanced_menu = {
      title = "@i18n(app.modules.advanced.name)@",
      pages = {
        { id = "filters", title = "@i18n(app.modules.filters.name)@", menuId = "flight_tuning_advanced_filters_page", icon = "@pages/flight_tuning/advanced/filters/icon.png", lockedWhileArmed = true },
        { id = "pid_controller", title = "@i18n(app.modules.pid_controller.name)@", menuId = "flight_tuning_advanced_pid_controller_page", icon = "@pages/flight_tuning/advanced/pid_controller/icon.png", lockedWhileArmed = true },
        { id = "pid_bandwidth", title = "@i18n(app.modules.pid_bandwidth.name)@", menuId = "flight_tuning_advanced_pid_bandwidth_page", icon = "@pages/flight_tuning/advanced/pid_bandwidth/icon.png", lockedWhileArmed = true },
        { id = "autolevel", title = "@i18n(app.modules.autolevel.name)@", menuId = "flight_tuning_advanced_autolevel_page", icon = "@pages/flight_tuning/advanced/autolevel/icon.png", lockedWhileArmed = true },
        { id = "main_rotor", title = "@i18n(app.modules.main_rotor.name)@", menuId = "flight_tuning_advanced_main_rotor_page", icon = "@pages/flight_tuning/advanced/main_rotor/icon.png", lockedWhileArmed = true },
        { id = "tail_rotor", title = "@i18n(app.modules.tail_rotor.name)@", menuId = "flight_tuning_advanced_tail_rotor_page", icon = "@pages/flight_tuning/advanced/tail_rotor/icon.png", lockedWhileArmed = true },
        { id = "rescue", title = "@i18n(app.modules.rescue.name)@", menuId = "flight_tuning_advanced_rescue_page", icon = "@pages/flight_tuning/advanced/rescue/icon.png", lockedWhileArmed = true },
        { id = "rates_advanced", title = "@i18n(app.modules.rates_advanced.name)@", menuId = "flight_tuning_advanced_rates_advanced_menu", icon = "@pages/flight_tuning/advanced/rates_advanced/icon.png" }
      }
    },
    flight_tuning_advanced_rates_advanced_menu = {
      title = "@i18n(app.modules.rates_advanced.name)@",
      pages = {
        { id = "advanced", title = "@i18n(app.modules.rates_advanced.advanced)@", menuId = "flight_tuning_advanced_rates_advanced_advanced_page", icon = "@pages/flight_tuning/advanced/rates_advanced/advanced/icon.png", lockedWhileArmed = true },
        { id = "cyclic_behaviour", title = "@i18n(app.modules.rates_advanced.cyclic_behaviour)@", menuId = "flight_tuning_advanced_rates_advanced_cyclic_behaviour_page", icon = "@pages/flight_tuning/advanced/rates_advanced/cyclic_behaviour/icon.png", lockedWhileArmed = true },
        { id = "table", title = "@i18n(app.modules.rates_advanced.table)@", menuId = "flight_tuning_advanced_rates_advanced_table_page", icon = "@pages/flight_tuning/advanced/rates_advanced/table/icon.png", lockedWhileArmed = true }
      }
    },
    flight_tuning_advanced_rates_advanced_advanced_page = {
      title = "@i18n(app.modules.rates_advanced.advanced)@",
      pages = {}
    },
    flight_tuning_advanced_rates_advanced_cyclic_behaviour_page = {
      title = "@i18n(app.modules.rates_advanced.cyclic_behaviour)@",
      pages = {}
    },
    flight_tuning_advanced_rates_advanced_table_page = {
      title = "@i18n(app.modules.rates_advanced.table)@",
      pages = {}
    },
    flight_tuning_advanced_filters_page = {
      title = "@i18n(app.modules.filters.name)@",
      pages = {}
    },
    flight_tuning_advanced_pid_controller_page = {
      title = "@i18n(app.modules.pid_controller.name)@",
      pages = {}
    },
    flight_tuning_advanced_pid_bandwidth_page = {
      title = "@i18n(app.modules.pid_bandwidth.name)@",
      pages = {}
    },
    flight_tuning_advanced_autolevel_page = {
      title = "@i18n(app.modules.autolevel.name)@",
      pages = {}
    },
    flight_tuning_advanced_main_rotor_page = {
      title = "@i18n(app.modules.main_rotor.name)@",
      pages = {}
    },
    flight_tuning_advanced_tail_rotor_page = {
      title = "@i18n(app.modules.tail_rotor.name)@",
      pages = {}
    },
    flight_tuning_advanced_rescue_page = {
      title = "@i18n(app.modules.rescue.name)@",
      pages = {}
    },
    flight_tuning_advanced_rates_advanced_page = {
      title = "@i18n(app.modules.rates_advanced.name)@",
      pages = {}
    },
    setup_menu = {
      title = "@i18n(app.modules.setup.name)@",
      pages = {
        { id = "configuration", title = "@i18n(app.modules.configuration.name)@", menuId = "setup_configuration_page", icon = "@pages/setup/configuration/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "radio_config", title = "@i18n(app.modules.radio_config.name)@", menuId = "setup_radio_config_page", icon = "@pages/setup/radio_config/icon.png", row = 1, col = 2, lockedWhileArmed = true },
        { id = "telemetry", title = "@i18n(app.modules.telemetry.name)@", menuId = "setup_telemetry_page", icon = "@pages/setup/telemetry/icon.png", row = 1, col = 3, lockedWhileArmed = true },
        { id = "accelerometer", title = "@i18n(app.modules.accelerometer.name)@", menuId = "setup_accelerometer_page", icon = "@pages/setup/accelerometer/icon.png", row = 1, col = 4, lockedWhileArmed = true },
        { id = "alignment", title = "@i18n(app.modules.alignment.name)@", menuId = "setup_alignment_page", icon = "@pages/setup/alignment/icon.png", row = 1, col = 5, lockedWhileArmed = true },
        { id = "ports", title = "@i18n(app.modules.ports.name)@", menuId = "setup_ports_page", icon = "@pages/setup/ports/icon.png", row = 1, col = 6, lockedWhileArmed = true },
        { id = "mixer", title = "@i18n(app.modules.mixer.name)@", menuId = "mixer_menu", icon = "@pages/setup/mixer/icon.png", row = 2, col = 1 },
        { id = "servos", title = "@i18n(app.modules.servos.name)@", menuId = "servos_menu", icon = "@pages/setup/servos/icon.png", row = 2, col = 2 },
        { id = "controls", title = "@i18n(app.modules.controls.name)@", menuId = "controls_menu", icon = "@pages/setup/controls/icon.png", row = 2, col = 3 },
        { id = "power", title = "@i18n(app.modules.power.name)@", menuId = "power_menu", icon = "@pages/setup/power/icon.png", row = 2, col = 4 },
        { id = "esc_motors", title = "@i18n(app.modules.esc_motors.name)@", menuId = "esc_motors_menu", icon = "@pages/setup/esc_motors/icon.png", row = 2, col = 5 },
        { id = "governor", title = "@i18n(app.modules.governor.name)@", menuId = "governor_menu", icon = "@pages/setup/governor/icon.png", row = 2, col = 6 },
        { id = "model", title = "@i18n(app.modules.model.name)@", menuId = "setup_model_page", icon = "@pages/setup/model/icon.png", row = 3, col = 1, enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "gps", title = "@i18n(app.modules.gps.name)@", menuId = "setup_gps_page", icon = "@pages/setup/gps/icon.png", row = 3, col = 2, lockedWhileArmed = true }
      }
    },
    mixer_menu = {
      title = "@i18n(app.modules.mixer.name)@",
      pages = {
        { id = "swash", title = "@i18n(app.modules.mixer.swash)@", menuId = "setup_mixer_swash_page", icon = "@pages/setup/mixer/swash/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "swashgeometry", title = "@i18n(app.modules.mixer.geometry)@", menuId = "setup_mixer_swashgeometry_page", icon = "@pages/setup/mixer/swashgeometry/icon.png", row = 1, col = 2, lockedWhileArmed = true },
        { id = "tail", title = "@i18n(app.modules.mixer.tail)@", menuId = "setup_mixer_tail_page", icon = "@pages/setup/mixer/tail/icon.png", row = 1, col = 3, lockedWhileArmed = true },
        { id = "trims", title = "@i18n(app.modules.mixer.trims)@", menuId = "setup_mixer_trims_page", icon = "@pages/setup/mixer/trims/icon.png", row = 1, col = 4, lockedWhileArmed = true }
      }
    },
    power_menu = {
      title = "@i18n(app.modules.power.name)@",
      pages = {
        { id = "battery", title = "@i18n(app.modules.battery.name)@", menuId = "setup_power_battery_page", icon = "@pages/setup/power/battery/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "alerts", title = "@i18n(app.modules.alerts.name)@", menuId = "setup_power_alerts_page", icon = "@pages/setup/power/alerts/icon.png", row = 1, col = 2 },
        { id = "sources", title = "@i18n(app.modules.sources.name)@", menuId = "setup_power_sources_page", icon = "@pages/setup/power/sources/icon.png", row = 1, col = 3, lockedWhileArmed = true },
        { id = "smartfuel", title = "@i18n(app.modules.smartfuel.name)@", menuId = "setup_power_smartfuel_page", icon = "@pages/setup/power/smartfuel/icon.png", row = 1, col = 4, minApiVersion = { 12, 0, 9 }, lockedWhileArmed = true },
        { id = "preferences", title = "@i18n(app.modules.preferences.name)@", menuId = "setup_power_preferences_page", icon = "@pages/setup/power/preferences/icon.png", row = 1, col = 5 }
      }
    },
    servos_menu = {
      title = "@i18n(app.modules.servos.name)@",
      pages = {
        { id = "pwm", title = "@i18n(app.modules.servos.pwm)@", menuId = "setup_servos_pwm_page", icon = "@pages/setup/servos/pwm/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "bus", title = "@i18n(app.modules.servos.bus)@", menuId = "setup_servos_bus_page", icon = "@pages/setup/servos/bus/icon.png", row = 1, col = 2, lockedWhileArmed = true }
      }
    },
    controls_menu = {
      title = "@i18n(app.modules.controls.name)@",
      pages = {
        { id = "modes", title = "@i18n(app.modules.controls.modes)@", menuId = "setup_controls_modes_page", icon = "@pages/setup/controls/modes/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "adjustments", title = "@i18n(app.modules.controls.adjustments)@", menuId = "setup_controls_adjustments_page", icon = "@pages/setup/controls/adjustments/icon.png", row = 1, col = 2, lockedWhileArmed = true },
        { id = "failsafe", title = "@i18n(app.modules.controls.failsafe)@", menuId = "setup_controls_failsafe_page", icon = "@pages/setup/controls/failsafe/icon.png", row = 1, col = 3, lockedWhileArmed = true },
        { id = "beepers", title = "@i18n(app.modules.controls.beepers)@", menuId = "beepers_menu", icon = "@pages/setup/controls/beepers/icon.png", row = 1, col = 4 },
        { id = "blackbox", title = "@i18n(app.modules.controls.blackbox)@", menuId = "blackbox_menu", icon = "@pages/setup/controls/blackbox/icon.png", row = 1, col = 5 },
        { id = "stats", title = "@i18n(app.modules.controls.stats)@", menuId = "setup_controls_stats_page", icon = "@pages/setup/controls/stats/icon.png", row = 1, col = 6, lockedWhileArmed = true }
      }
    },
    beepers_menu = {
      title = "@i18n(app.modules.controls.beepers)@",
      pages = {
        { id = "configuration", title = "@i18n(app.modules.beepers.configuration)@", menuId = "setup_controls_beepers_configuration_page", icon = "@pages/setup/controls/beepers/configuration/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "dshot", title = "@i18n(app.modules.beepers.dshot)@", menuId = "setup_controls_beepers_dshot_page", icon = "@pages/setup/controls/beepers/dshot/icon.png", row = 1, col = 2, lockedWhileArmed = true }
      }
    },
    blackbox_menu = {
      title = "@i18n(app.modules.controls.blackbox)@",
      pages = {
        { id = "configuration", title = "@i18n(app.modules.blackbox.configuration)@", menuId = "setup_controls_blackbox_configuration_page", icon = "@pages/setup/controls/blackbox/configuration/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "logging", title = "@i18n(app.modules.blackbox.logging)@", menuId = "setup_controls_blackbox_logging_page", icon = "@pages/setup/controls/blackbox/logging/icon.png", row = 1, col = 2, lockedWhileArmed = true },
        { id = "status", title = "@i18n(app.modules.blackbox.status)@", menuId = "setup_controls_blackbox_status_page", icon = "@pages/setup/controls/blackbox/status/icon.png", row = 1, col = 3, lockedWhileArmed = true }
      }
    },
    esc_motors_menu = {
      title = "@i18n(app.modules.esc_motors.name)@",
      pages = {
        { id = "throttle", title = "@i18n(app.modules.esc_motors.throttle)@", menuId = "setup_esc_motors_throttle_page", icon = "@pages/setup/esc_motors/throttle/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "telemetry", title = "@i18n(app.modules.esc_motors.telemetry)@", menuId = "setup_esc_motors_telemetry_page", icon = "@pages/setup/esc_motors/telemetry/icon.png", row = 1, col = 2, lockedWhileArmed = true },
        { id = "rpm", title = "@i18n(app.modules.esc_motors.rpm)@", menuId = "setup_esc_motors_rpm_page", icon = "@pages/setup/esc_motors/rpm/icon.png", row = 1, col = 3, lockedWhileArmed = true },
        { id = "esc_tools", title = "@i18n(app.modules.esc_motors.esc_tools)@", menuId = "esc_tools_menu", icon = "@pages/setup/esc_motors/esc_tools/icon.png", row = 1, col = 4, lockedWhileArmed = true },
        { id = "motor_override", title = "@i18n(app.modules.esc_motors.motor_override)@", menuId = "setup_esc_motors_motor_override_page", icon = "@pages/setup/esc_motors/motor_override/icon.png", row = 1, col = 5, minApiVersion = { 12, 0, 9 }, lockedWhileArmed = true }
      }
    },
    esc_tools_menu = {
      title = "@i18n(app.modules.esc_motors.esc_tools)@",
      pages = {
        { id = "am32", title = "AM32", menuId = "setup_esc_motors_esc_tools_am32_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/am32/icon.png", row = 1, col = 1, enabledWhen = "escProto1", lockedWhileArmed = true },
        { id = "blheli_s", title = "BLHeli_S", menuId = "setup_esc_motors_esc_tools_blheli_s_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/blheli_s/icon.png", row = 1, col = 2, enabledWhen = "escProto1", lockedWhileArmed = true },
        { id = "bluejay", title = "Bluejay", menuId = "setup_esc_motors_esc_tools_bluejay_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/bluejay/icon.png", row = 1, col = 3, enabledWhen = "escProto1", lockedWhileArmed = true },
        { id = "flrtr", title = "Flyrotor", menuId = "setup_esc_motors_esc_tools_flrtr_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/flrtr/icon.png", row = 1, col = 4, enabledWhen = "escProto10", lockedWhileArmed = true },
        { id = "hw5", title = "Hobbywing V5", menuId = "setup_esc_motors_esc_tools_hw5_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/hw5/icon.png", row = 1, col = 5, enabledWhen = "escProto3", lockedWhileArmed = true },
        { id = "omp", title = "OMP", menuId = "setup_esc_motors_esc_tools_omp_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/omp/icon.png", row = 2, col = 1, enabledWhen = "escProto6", lockedWhileArmed = true },
        { id = "scorp", title = "Scorpion", menuId = "setup_esc_motors_esc_tools_scorp_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/scorp/icon.png", row = 2, col = 2, enabledWhen = "escProto4", lockedWhileArmed = true },
        { id = "xdfly", title = "XDFly", menuId = "setup_esc_motors_esc_tools_xdfly_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/xdfly/icon.png", row = 2, col = 3, enabledWhen = "escProto12", lockedWhileArmed = true },
        { id = "yge", title = "YGE", menuId = "setup_esc_motors_esc_tools_yge_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/yge/icon.png", row = 2, col = 4, enabledWhen = "escProto9", lockedWhileArmed = true },
        { id = "ztw", title = "ZTW", menuId = "setup_esc_motors_esc_tools_ztw_page", icon = "@pages/setup/esc_motors/esc_tools/escmfg/ztw/icon.png", row = 2, col = 5, enabledWhen = "escProto7", lockedWhileArmed = true }
      }
    },
    governor_menu = {
      title = "@i18n(app.modules.governor.name)@",
      pages = {
        { id = "general", title = "@i18n(app.modules.governor.general)@", menuId = "setup_governor_general_page", icon = "@pages/setup/governor/general/icon.png", row = 1, col = 1, lockedWhileArmed = true },
        { id = "time", title = "@i18n(app.modules.governor.time)@", menuId = "setup_governor_time_page", icon = "@pages/setup/governor/time/icon.png", row = 1, col = 2, lockedWhileArmed = true },
        { id = "filters", title = "@i18n(app.modules.governor.filters)@", menuId = "setup_governor_filters_page", icon = "@pages/setup/governor/filters/icon.png", row = 1, col = 3, lockedWhileArmed = true },
        { id = "curves", title = "@i18n(app.modules.governor.curves)@", menuId = "setup_governor_curves_page", icon = "@pages/setup/governor/curves/icon.png", row = 1, col = 4, lockedWhileArmed = true }
      }
    },
    setup_mixer_swash_page = {
      title = "@i18n(app.modules.mixer.swash)@",
      pages = {}
    },
    setup_mixer_swashgeometry_page = {
      title = "@i18n(app.modules.mixer.geometry)@",
      pages = {}
    },
    setup_mixer_tail_page = {
      title = "@i18n(app.modules.mixer.tail)@",
      pages = {}
    },
    setup_mixer_trims_page = {
      title = "@i18n(app.modules.mixer.trims)@",
      pages = {}
    },
    setup_power_battery_page = {
      title = "@i18n(app.modules.battery.name)@",
      pages = {}
    },
    setup_power_alerts_page = {
      title = "@i18n(app.modules.alerts.name)@",
      pages = {}
    },
    setup_power_sources_page = {
      title = "@i18n(app.modules.sources.name)@",
      pages = {}
    },
    setup_power_smartfuel_page = {
      title = "@i18n(app.modules.smartfuel.name)@",
      pages = {}
    },
    setup_power_preferences_page = {
      title = "@i18n(app.modules.preferences.name)@",
      pages = {}
    },
    flight_tuning_pids_page = {
      title = "@i18n(app.modules.pids.name)@",
      pages = {}
    },
    flight_tuning_rates_page = {
      title = "@i18n(app.modules.rates.name)@",
      pages = {}
    },
    flight_tuning_governor_page = {
      title = "@i18n(app.modules.governor.name)@",
      pages = {}
    },
    -- The assistants, as a group. A guided run is a different kind of thing from a settings page
    -- and there will be more than one of them -- the switches, the tail, the swashplate are each
    -- a procedure a pilot comes back to on its own -- so they get a place of their own rather
    -- than a row beside the pages they drive.
    wizards_menu = {
      title = "@i18n(app.modules.wizards.name)@",
      pages = {
        { id = "setup_wizard", title = "@i18n(app.modules.setup_wizard.name)@", menuId = "setup_wizard_menu", icon = "@pages/setup/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true }
      }
    },
    -- The whole run and its parts, side by side. The parts are not shortcuts into a walk: each
    -- opens the same assistant bounded to one section, with the same criteria and the same list.
    setup_wizard_menu = {
      title = "@i18n(app.modules.setup_wizard.name)@",
      pages = {
        { id = "all", title = "@i18n(app.modules.setup_wizard.all)@", menuId = "setup_wizard_page", icon = "@pages/setup/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "radio", title = "@i18n(app.modules.setup_wizard.radio)@", menuId = "setup_wizard_radio_page", icon = "@pages/setup/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "board", title = "@i18n(app.modules.setup_wizard.board)@", menuId = "setup_wizard_board_page", icon = "@pages/setup/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true }
      }
    },
    setup_wizard_page = {
      title = "@i18n(app.modules.setup_wizard.all)@",
      pages = {}
    },
    setup_wizard_radio_page = {
      title = "@i18n(app.modules.setup_wizard.radio)@",
      pages = {}
    },
    setup_wizard_board_page = {
      title = "@i18n(app.modules.setup_wizard.board)@",
      pages = {}
    },
    setup_configuration_page = {
      title = "@i18n(app.modules.configuration.name)@",
      pages = {}
    },
    setup_radio_config_page = {
      title = "@i18n(app.modules.radio_config.name)@",
      pages = {}
    },
    setup_model_page = {
      title = "@i18n(app.modules.model.name)@",
      pages = {}
    },
    setup_telemetry_page = {
      title = "@i18n(app.modules.telemetry.name)@",
      pages = {}
    },
    setup_gps_page = {
      title = "@i18n(app.modules.gps.name)@",
      pages = {}
    },
    setup_accelerometer_page = {
      title = "@i18n(app.modules.accelerometer.name)@",
      pages = {}
    },
    setup_alignment_page = {
      title = "@i18n(app.modules.alignment.name)@",
      pages = {}
    },
    setup_ports_page = {
      title = "@i18n(app.modules.ports.name)@",
      pages = {}
    },
    settings_admin = {
      title = "@i18n(app.modules.settings.name)@",
      pages = {
        { id = "general", title = "@i18n(app.modules.general.name)@", menuId = "settings_general_page" },
        { id = "dashboard", title = "@i18n(app.modules.dashboard.name)@", menuId = "settings_dashboard_menu", icon = "@pages/settings/dashboard/icon.png" },
        { id = "localization", title = "@i18n(app.modules.localization.name)@", menuId = "settings_localization_page" },
        { id = "audio", title = "@i18n(app.modules.audio.name)@", menuId = "settings_audio_page" },
        { id = "shortcuts", title = "@i18n(app.modules.shortcuts.name)@", menuId = "settings_shortcuts_page", enabled = false, hideWhenDisabled = true }
        --{ id = "activelook", title = "@i18n(app.modules.activelook.name)@", menuId = "settings_activelook_page", enabled = false, hideWhenDisabled = true }      
      }
    },
    settings_dashboard_menu = {
      title = "@i18n(app.modules.dashboard.name)@",
      pages = {
        { id = "dashboard_theme", title = "@i18n(app.modules.dashboard_theme.name)@", menuId = "settings_dashboard_theme_page" },
        { id = "dashboard_settings", title = "@i18n(app.modules.dashboard_settings.name)@", menuId = "settings_dashboard_settings_menu", icon = "@pages/settings/dashboard/settings/icon.png" }
      }
    },
    settings_dashboard_settings_menu = {
      title = "@i18n(app.modules.dashboard_settings.name)@",
      pages = {},  -- Populated dynamically at runtime by dashboard_builder
      _dynamicThemes = true  -- Flag to indicate this menu should be populated dynamically
    },
    settings_general_page = {
      title = "@i18n(app.modules.general.name)@",
      pages = {}
    },
    settings_dashboard_theme_page = {
      title = "@i18n(app.modules.dashboard_theme.name)@",
      pages = {}
    },
    settings_dashboard_settings_page = {
      title = "@i18n(app.modules.dashboard_settings.name)@",
      pages = {}
    },
    settings_shortcuts_page = {
      title = "@i18n(app.modules.shortcuts.name)@",
      pages = {}
    },
    settings_activelook_page = {
      title = "@i18n(app.modules.activelook.name)@",
      pages = {}
    },
    settings_localization_page = {
      title = "@i18n(app.modules.localization.name)@",
      pages = {}
    },
    settings_audio_page = {
      title = "@i18n(app.modules.audio.name)@",
      pages = {
        { id = "audio_events", title = "@i18n(app.modules.audio_events.name)@", menuId = "settings_audio_events_page" }
      }
    },
    developer_menu = {
      title = "@i18n(app.modules.developer.name)@",
      pages = {
        { id = "msp_speed", title = "@i18n(app.modules.msp_speed.name)@", menuId = "developer_msp_speed_page", icon = "@pages/developer/msp_speed/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "api_tester", title = "@i18n(app.modules.api_tester.name)@", menuId = "developer_api_tester_page", icon = "@pages/developer/api_tester/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "msp_experiments", title = "@i18n(app.modules.msp_experiments.name)@", menuId = "developer_msp_experiments_page", icon = "@pages/developer/msp_experiments/icon.png", enabledWhen = "fblConnected", lockedWhileArmed = true },
        { id = "developer_settings", title = "@i18n(app.modules.developer_settings.name)@", menuId = "developer_settings_page", icon = "@pages/developer/developer_settings/icon.png" },
      }
    },
    developer_msp_speed_page = {
      title = "@i18n(app.modules.msp_speed.name)@",
      pages = {}
    },
    developer_api_tester_page = {
      title = "@i18n(app.modules.api_tester.name)@",
      pages = {}
    },
    developer_msp_experiments_page = {
      title = "@i18n(app.modules.msp_experiments.name)@",
      pages = {}
    },
    developer_settings_page = {
      title = "@i18n(app.modules.developer_settings.name)@",
      pages = {}
    },
    settings_audio_events_page = {
      title = "@i18n(app.modules.audio_events.name)@",
      -- One page per category. The icons are the ones the matching setup pages already carry.
      pages = {
        { id = "audio_events_arming", title = "@i18n(app.modules.audio_events_arming.name)@", menuId = "settings_audio_events_arming_page", icon = "@pages/setup/controls/modes/icon.png" },
        { id = "audio_events_governor", title = "@i18n(app.modules.audio_events_governor.name)@", menuId = "settings_audio_events_governor_page", icon = "@pages/setup/governor/icon.png" },
        { id = "audio_events_voltage", title = "@i18n(app.modules.audio_events_voltage.name)@", menuId = "settings_audio_events_voltage_page", icon = "@pages/setup/power/alerts/icon.png" },
        { id = "audio_events_profiles", title = "@i18n(app.modules.audio_events_profiles.name)@", menuId = "settings_audio_events_profiles_page", icon = "@pages/tools/select_profile/icon.png" },
        { id = "audio_events_esc", title = "@i18n(app.modules.audio_events_esc.name)@", menuId = "settings_audio_events_esc_page", icon = "@pages/setup/esc_motors/telemetry/icon.png" },
        { id = "audio_events_adjustment", title = "@i18n(app.modules.audio_events_adjustment.name)@", menuId = "settings_audio_events_adjustment_page", icon = "@pages/setup/controls/adjustments/icon.png" },
        { id = "audio_events_fuel", title = "@i18n(app.modules.audio_events_fuel.name)@", menuId = "settings_audio_events_fuel_page", icon = "@pages/setup/power/smartfuel/icon.png" },
        { id = "audio_events_battery", title = "@i18n(app.modules.audio_events_battery.name)@", menuId = "settings_audio_events_battery_page", icon = "@pages/setup/power/battery/icon.png" },
        { id = "audio_events_other", title = "@i18n(app.modules.audio_events_other.name)@", menuId = "settings_audio_events_other_page", icon = "@pages/setup/model/icon.png" }
      }
    },
    settings_audio_events_arming_page = {
      title = "@i18n(app.modules.audio_events_arming.name)@",
      pages = {}
    },
    settings_audio_events_governor_page = {
      title = "@i18n(app.modules.audio_events_governor.name)@",
      pages = {}
    },
    settings_audio_events_voltage_page = {
      title = "@i18n(app.modules.audio_events_voltage.name)@",
      pages = {}
    },
    settings_audio_events_profiles_page = {
      title = "@i18n(app.modules.audio_events_profiles.name)@",
      pages = {}
    },
    settings_audio_events_esc_page = {
      title = "@i18n(app.modules.audio_events_esc.name)@",
      pages = {}
    },
    settings_audio_events_adjustment_page = {
      title = "@i18n(app.modules.audio_events_adjustment.name)@",
      pages = {}
    },
    settings_audio_events_fuel_page = {
      title = "@i18n(app.modules.audio_events_fuel.name)@",
      pages = {}
    },
    settings_audio_events_battery_page = {
      title = "@i18n(app.modules.audio_events_battery.name)@",
      pages = {}
    },
    settings_audio_events_other_page = {
      title = "@i18n(app.modules.audio_events_other.name)@",
      pages = {}
    },
    diagnostics_fblsensors_page = {
      title = "@i18n(app.modules.fblsensors.name)@",
      pages = {}
    },
    diagnostics_fblstatus_page = {
      title = "@i18n(app.modules.fblstatus.name)@",
      pages = {}
    },
    diagnostics_rfstatus_page = {
      title = "@i18n(app.modules.rfstatus.name)@",
      pages = {}
    },
    diagnostics_elrs_link_page = {
      title = "@i18n(app.modules.elrs_link.name)@",
      pages = {}
    },
    diagnostics_validate_sensors_page = {
      title = "@i18n(app.modules.validate_sensors.name)@",
      pages = {}
    },
    diagnostics_smartfuel_page = {
      title = "@i18n(app.modules.smartfuel.name)@",
      pages = {}
    },
    diagnostics_session_logs_page = {
      title = "@i18n(app.modules.session_logs.name)@",
      pages = {}
    },
    diagnostics_info_page = {
      title = "@i18n(app.modules.info.name)@",
      pages = {}
    },
    setup_servos_pwm_page = {
      title = "@i18n(app.modules.servos.pwm)@",
      pages = {}
    },
    setup_servos_bus_page = {
      title = "@i18n(app.modules.servos.bus)@",
      pages = {}
    },
    setup_controls_modes_page = {
      title = "@i18n(app.modules.controls.modes)@",
      pages = {}
    },
    setup_controls_adjustments_page = {
      title = "@i18n(app.modules.controls.adjustments)@",
      pages = {}
    },
    setup_controls_failsafe_page = {
      title = "@i18n(app.modules.controls.failsafe)@",
      pages = {}
    },
    setup_controls_beepers_configuration_page = {
      title = "@i18n(app.modules.beepers.configuration)@",
      pages = {}
    },
    setup_controls_beepers_dshot_page = {
      title = "@i18n(app.modules.beepers.dshot)@",
      pages = {}
    },
    setup_controls_blackbox_configuration_page = {
      title = "@i18n(app.modules.blackbox.configuration)@",
      pages = {}
    },
    setup_controls_blackbox_logging_page = {
      title = "@i18n(app.modules.blackbox.logging)@",
      pages = {}
    },
    setup_controls_blackbox_status_page = {
      title = "@i18n(app.modules.blackbox.status)@",
      pages = {}
    },
    setup_controls_stats_page = {
      title = "@i18n(app.modules.controls.stats)@",
      pages = {}
    },
    setup_esc_motors_throttle_page = {
      title = "@i18n(app.modules.esc_motors.throttle)@",
      pages = {}
    },
    setup_esc_motors_telemetry_page = {
      title = "@i18n(app.modules.esc_motors.telemetry)@",
      pages = {}
    },
    setup_esc_motors_rpm_page = {
      title = "@i18n(app.modules.esc_motors.rpm)@",
      pages = {}
    },
    setup_esc_motors_motor_override_page = {
      title = "@i18n(app.modules.esc_motors.motor_override)@",
      pages = {}
    },
    setup_esc_motors_esc_tools_page = {
      title = "@i18n(app.modules.esc_motors.esc_tools)@",
      pages = {}
    },
    setup_esc_motors_esc_tools_am32_page = {
      title = "AM32 Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_blheli_s_page = {
      title = "BLHeli_S Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_bluejay_page = {
      title = "Bluejay Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_flrtr_page = {
      title = "Flyrotor Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_hw5_page = {
      title = "Hobbywing V5 Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_omp_page = {
      title = "OMP Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_scorp_page = {
      title = "Scorpion Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_xdfly_page = {
      title = "XDFly Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_yge_page = {
      title = "YGE Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tools_ztw_page = {
      title = "ZTW Configurator",
      pages = {}
    },
    setup_esc_motors_esc_tool_run_page = {
      title = "ESC Configurator",
      pages = {}
    },
    setup_governor_general_page = {
      title = "@i18n(app.modules.governor.general)@",
      pages = {}
    },
    setup_governor_time_page = {
      title = "@i18n(app.modules.governor.time)@",
      pages = {}
    },
    setup_governor_filters_page = {
      title = "@i18n(app.modules.governor.filters)@",
      pages = {}
    },
    setup_governor_curves_page = {
      title = "@i18n(app.modules.governor.curves)@",
      pages = {}
    },
    tools_select_profile_page = {
      title = "@i18n(app.modules.profile_select.name)@",
      pages = {}
    },
    tools_copy_profiles_page = {
      title = "@i18n(app.modules.copyprofiles.name)@",
      pages = {}
    },
    logs_page = {
      title = "@i18n(app.modules.logs.name)@",
      pages = {}
    }
  }
}

return manifest
