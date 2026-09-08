# 0.1.7

### Performance, Memory & Build System
- **Release Version (`lib/version.lua`)**:
  - Bumped the Rotorflight Lua EdgeTX Suite version to `0.1.7`.
# 0.1.6

### Features & Enhancements
- **Dynamic ESC Model Identification & Interface Unification (`setup/esc_motors/esc_tools`)**:
  - Added dynamic ESC model name detection and header display queried directly from hardware via telemetry / MSP.
  - Unified device information and capability reporting across all supported ESC manufacturers (AM32, BLHeli_S, Bluejay, Flyrotor, Hobbywing V5, OMP, Scorpion, XDFly, YGE, ZTW).
  - Isolated Hobbywing V5 parameter tables to prevent cross-talk and corrected YGE firmware version mapping.
- **ESC Firmware Version & Serial Number / Revision Subheader Display (`setup/esc_motors/esc_tools`)**:
  - Implemented a compact subheader info line directly beneath the section header across all 10 ESC manufacturer configuration pages (AM32, BLHeli_S, Bluejay, Flyrotor, Hobbywing V5, OMP, Scorpion, XDFly, YGE, ZTW).
  - Provides persistent, at-a-glance visibility into firmware versions (`FW`), device serial numbers (`S/N`), and layout revisions (`Rev`) across all parameter tabs with minimal screen footprint (~18px).
  - Corrected YGE serial number extraction (`getEscVersion`) to parse the 32-bit uint serial number from protocol buffers.
- **Active Profile & Rate Profile Live Resolution (`flight_tuning`)**:
  - Centralized live profile resolution (`getLiveProfile()`) to read active PID and rate profiles directly from telemetry sensors and session state.
  - Profile adjustments made via transmitter switches or telemetry are instantly reflected across all flight tuning pages without desync.
- **Motor Override & ESC Motor Test Tool (`setup/esc_motors/motor_override`)**:
  - Added dedicated Motor Override tool allowing direct spool-up and functional testing of main and tail motors from the radio.
  - Multi-tier safety architecture: requires explicit disarm confirmation, hardware arming switch check, deadman timeout watchdog, manual throttle override sliders, and automatic shutoff upon page navigation or telemetry link loss.
- **SD Card Session Logging & Trace Layer (`rfsuite.log`)**:
  - Implemented structured multi-level logging (`trace`, `debug`, `info`, `warn`, `error`) with ring buffer sink writing session logs directly to SD card.
  - Added single-writer arbitration between configuration tool and background widgets to avoid file contention.
  - Emits timestamps, MSP transport traces, UI lifecycle events, and save refusal explanations.
- **MSP Live Telemetry & Accessors (`tasks/msp/api`)**:
  - Added modular MSP API endpoints for live analog sensor readings (`MSP_ANALOG`) and receiver channel inputs (`MSP_RC`).
  - Added self-identification tags for simulator responses in debug traces.
- **Startup Progress & Visual Preparation (`ui/home.lua`)**:
  - Added smooth animated preparation progress bar on the home start screen.
- **Flight Controller Reboot Policy Documentation (`tasks/msp/save_pipeline.lua`)**:
  - Embedded explicit Rotorflight 2 flight controller reboot policy guidelines directly into save pipeline headers and architecture documentation.
  - Formulated clear boundaries for mandatory reboots (hardware drivers, DMA, UART ports, radio config, ESC protocols, sensor alignment), conditional reboots (swash/tail geometry changes), and non-reboot live tuning (PIDs, rates, governor, filters).
- **Reactive LVGL Telemetry Bindings & Zero-Rebuild Dashboard Engine (`widgets/dashboard`)**:
  - Migrated telemetry labels, gauges, arcs, duration timers, governor indicators, and stats to reactive getter closures evaluated directly by EdgeTX's native `callRefs` loop in C++.
  - Pruned dynamic sensor data (`voltage`, `rpm`, `flightSeconds`, `fuel`, `lq`, etc.) from `Engine.renderKey`, eliminating continuous 2-Hz full-scene teardown and rebuild churn (`lvgl.clear()` + `lvgl.build()`).
  - Scene rebuilds are now strictly confined to layout mutations (flight mode changes `preflight` $\rightarrow$ `inflight` $\rightarrow$ `postflight`, theme switches, and zone resizing), resulting in zero memory allocations and minimal CPU overhead during steady-state flights.
- **MSP API Return Format Normalization (`tasks/msp/api`)**:
  - Standardized all 102 MSP API modules (`Api.parse`) to return a clean, flat table (`return { ... }`) rather than mixed wrapped tables (`{ parsed = ... }`), eliminating duplicate unnesting logic across servo, esc, and setup pages and improving API tester introspection.

### Bug Fixes & Improvements
- **Dashboard Model Preferences Cache Invalidation & Reload Decoupling (`widgets/dashboard`, `lib/model_preferences.lua`, `tasks/msp/runtime.lua`)** (fixes #186):
  - Fixed an issue where changing theme selection or model preference overrides in the suite did not update the active dashboard widget until a transmitter power cycle due to stale in-memory preferences and RAM cache lookups.
  - Decoupled disk I/O from theme module loading during preference reloads (`reloadPreferencesIfNeeded`) so reading INI files and building the theme occur on separate passes, eliminating EdgeTX CPU limit instruction budget faults.
  - Hardened reload lifecycle against mid-load faults: pre-cleared theme and memo state before disk reads, deferred baseline stamp/sequence adoption and pending flag clearance until after successful I/O, and protected active session preferences against stale MSP runtime republishes.
- **Initial Fuel Announcement Preference Authority & Redundant Flag Cleanup (`lib/audio.lua`, `app/pages/setup/model/page.lua`) — ref #191, ref #187**:
  - Established the radio preference (`Audio / Events -> Battery -> Initial Fuel Announcement`, default: enabled) as the single source of truth for the initial fuel announcement upon connection.
  - Fixed `initialFuelWanted()` in `lib/audio.lua`, which previously consulted `FLAG_TELL_CAPACITY` from `model_flags` and silenced announcements for all pilots on default flight controller configurations (`model_flags = 0`).
  - Removed the redundant and conflicting `FLAG_TELL_CAPACITY` switch from `app/pages/setup/model/page.lua`, preventing dual-switch ambiguity where neither control could reliably silence the callout independently.
- **Dashboard Postflight Stats: Missing Handlers and Live-Value Fallthrough (`widgets/dashboard`) — fixes [#133](https://github.com/rotorflight/rotorflight-lua-edgetx-suite/issues/133)**:
  - Added per-flight tracking for `currentFlightMaxVoltage`/`lastFlightMaxVoltage`, `currentFlightMaxLq`/`lastFlightMaxLq`, `currentFlightMinBecVoltage`/`lastFlightMinBecVoltage`, and `lastFlightEndingVoltage` in `runtime.lua` (`updateDerivedFlightState`).
  - Added stat handlers in `objects/text/stats.lua` for `max`+`voltage` (MAX VOLTAGE tile in `rfstatus` theme), `max`+`link` (LINK MAX in `@rt-rc-n`), `min`+`link` (LINK MIN in `@srb-rc`), and `last`+`voltage` (ENDING VOLTAGE in `@srb-rc`).
  - Fixed `min`+`bec_voltage` handler to use the dedicated BEC minimum accumulator (`lastFlightMinBecVoltage`) instead of incorrectly returning the main pack minimum voltage.
  - Removed the `/2` transform workaround from `@aerc-n/postflight.lua`'s MIN BEC VOLTAGE tile; the accumulator now tracks the actual BEC minimum directly.
  - Fixed stats handlers to prioritize current in-flight values over previous flights (`currentFlight… or last…`), and removed live sensor fallbacks so tiles render `--` before the first flight instead of leaking live readings.
  - Made any unresolvable `(stattype, source)` pair render `--` instead of silently falling through to the live telemetry value, turning future theme typos into immediately visible blank values.
- **Dashboard Fullscreen Menu EEPROM Commit Write Flag (`widgets/dashboard/fullscreen_menu.lua`)** (fixes #135):
  - Added explicit `isWrite = true` flag to the queued EEPROM commit after a battery profile change, ensuring the message with an empty payload is recognized as a write rather than defaulting to a read request. Dispatches as an MSP write frame (`CRSF_FRAMETYPE_MSP_WRITE`) on CRSF and properly triggers MSP response cache invalidation.
- **Dashboard ESC Temperature Gauge Arc Coloring (`widgets/dashboard/objects/gauge.lua`)** (fixes #132):
  - Fixed `getArcValueColor` falling through to the LiPo cell-voltage branch for temperature sources (`esc_temp`, `mcu_temp`), which divided the temperature value by the estimated battery cell count and applied ascending (low = bad) threshold logic — causing cold ESC temperatures to display as critical (red) and hot temperatures as OK (green).
  - Added explicit temperature source detection (`isTempSource`) or temperature unit fallback (`°C`/`°F`) with inverted threshold coloring: low/cool = green, high/hot = orange/red.
  - Temperature thresholds resolve from box properties (`warntemp`/`alerttemp`), theme configuration (`esctemp_warn`/`esctemp_alert`), or sensible defaults (90 °C warn, `max(warn + 15, 105)` °C alert; when alert threshold defaults, it is clamped to gauge maximum to remain reachable on custom scales).
  - Preserved valid cold / freezing temperatures (<= 0 °C) in OK green and properly distinguish missing telemetry (`curHasValue == false`) for arc background coloring.
  - Passed temperature, unit, and scale flags directly from `renderArc` to avoid redundant lookups and eliminated unit/source mismatches under Fahrenheit mode.
  - Eliminated dependency on battery cell count for temperature arc coloring.
- **Dashboard Stats Precedence, BEC Voltage Correction & Governor Optimization (`widgets/dashboard`)**:
  - **Stats Box Flight Precedence & BEC Voltage Correction**: Corrected stat value precedence in `widgets/dashboard/objects/text/stats.lua` so current flight extremes (`currentFlight...`) take precedence over previous flight aggregates (`lastFlight...`) while in flight, cleanly falling back to previous flight values once disarmed. Resolved a copy-paste error in the `bec_voltage` branch where main battery pack voltage (`lastMinVoltage`) was displayed instead of BEC voltage, and implemented in-flight minimum BEC voltage tracking (`currentFlightMinBecVoltage` / `lastMinBecVoltage`) in `runtime.lua`. Note: On setups without a dedicated BEC voltage sensor, this box now correctly reports `0` instead of falling back to the main flight battery pack voltage.
  - **Governor Disable-Flag Translation Deferral**: Deferred `translate()` resolution in `widgets/dashboard/objects/text/governor.lua` until after verifying the respective bit is actually set in `armDisableFlags`, eliminating up to 26 string lookups per rebuild.
- **Dashboard Memory & Loader Cleanup (`widgets/dashboard`, `lib/sensors`, `setup/esc_motors/esc_tools/escmfg/am32`)**:
  - Removed uncalled legacy builder and card functions (~330 lines) from `widgets/dashboard/themes/default/common.lua`, significantly reducing RAM footprint on radios.
  - Implemented missing negative caches (`missingRenders`) in `objects/dial.lua`, `objects/time.lua`, and `objects/image.lua` to eliminate redundant disk I/O / `loadScript` lookups on every scene rebuild for absent subrenderers.
  - Removed duplicate and shadowed `SIM_SENSOR_PATHS` definition in `lib/sensors.lua`.
  - Removed obsolete and unreachable `am32/pages.lua` file containing non-functional require statements.
- **Dashboard Widget i18n Status Line & Fullscreen Menu Fallback (`widgets/dashboard`)**:
  - Localized the soft timeout connection splash status line (`"Connected with partial telemetry"`) via `widgets.dashboard.connected_partial_telemetry`.
  - Corrected the degenerate fallback translator function signature in `fullscreen_menu.lua` from `function(_, k, f)` to `function(k, f)` so fallback label strings are properly returned instead of `nil` when i18n context is unavailable.
- **Telemetry Sensor Status Initialization (`tasks/events/onconnect`, `app/pages/tools/diagnostics`)**:
  - Load telemetry configuration during the connection chain and distinguish an unloaded configuration from a validation failure, preventing a false `ERROR` before the first sensor read.
- **Housekeeping Queue Starvation & Dependency Loading Order (`tasks/msp/runtime.lua`, `queue.lua`)**:
  - Eliminated the staggered module-loading race condition where `UID` dependencies finished loading before `API_VERSION` dependencies, inadvertently seizing the transmit slot and starving the connect chain.
  - Held `UID` read back until `API_VERSION` is successfully received and verified, ensuring primary flight controller compatibility is established before secondary model preference lookups.
  - Bounded housekeeping reads with tighter timeouts (1.5s) and retry budgets (max 2–3 retries) with backoff re-arming upon failures.
  - Enhanced `Queue:clear()` to supply distinct `"cleared"` error reason to callbacks, allowing callers to differentiate queue drops from transport timeouts.
- **Adjustments & Modes AUX Channel Bounds (`setup/controls/adjustments`, `setup/controls/modes`)**:
  - Capped AUX channel selection pickers and auto-detection loops at the firmware limit `AUX 1` .. `AUX 13` (`MAX_AUX_CHANNEL_COUNT = 13` = `MAX_SUPPORTED_RC_CHANNEL_COUNT - CONTROL_CHANNEL_COUNT`), removing unreachable `AUX 14` .. `AUX 20` entries.
  - Added strict write payload and sanitization clamping against `AUX_CHANNEL_COUNT - 1` (indices 0..12) to prevent out-of-bounds array indexing in flight controller receiver inputs.
- **Onconnect API Version Task Disconnect Sentinel Handling (`tasks/events/onconnect/tasks/apiversion.lua`)**:
  - Fixed an issue where the `apiversion` onconnect task immediately completed on reconnect due to the disconnect sentinel `"0"` being truthy and non-empty.
  - Added explicit check rejecting `"0"` alongside `nil` and `""` so the connect chain properly waits for a verified MSP API version read.
  - Implemented `M.reset()` on the `apiversion` task to ensure clean state resets across connect/disconnect cycles.
- **Unified Visual Language & Save/Notice Modal Consolidation (`ui/home.lua`, `controls/modes`, `controls/adjustments`, `dashboard/theme`, `splash.lua`)**:
  - Eliminated conflicting visual vocabularies during save operations where native EdgeTX blue message dialogs (`lvgl.message`) were raised over the suite's flat in-progress save overlay, which previously blocked the Lua `run()` loop and required keyboard dismissal.
  - Standardized all save outcome reporting (success and failure) to route through `ctx.reportSave()` and `reportSaveOutcome()`, displaying unified non-blocking notice overlays with touch- and key-navigable dismissal.
  - Replaced native modal alerts in `modes`, `adjustments`, and `theme` settings with in-suite notices (`ui.notice` / `LoadingOverlay.appendNotice`), ensuring the run loop advances smoothly and UI rebuilds take place immediately.
  - Harmonized the dashboard widget connection splash (`widgets/dashboard/splash.lua`) color palette with the core tool start screen using semantic theme tokens (`COLOR_THEME_PRIMARY3`, `COLOR_THEME_PRIMARY2`), creating a unified visual identity across standalone tools and telemetry widgets.
- **Decoupled FBL Connection State & Menu Tile Gating (`ui/home.lua`, `tasks/msp/runtime.lua`, `tasks/events/runtime.lua`, `app/pages/tools/diagnostics/rfstatus`)**:
  - Decoupled `fblConnected` (true Flight Controller MSP handshake) from `rfConnected` / `session.isConnected` (pure RF telemetry link presence).
  - Resolved an issue where main menu tiles (`enabledWhen = "fblConnected"`) unlocked 0.6s after RF link connection based on RSSI alone before any MSP reply arrived from the flight controller.
  - Required verified API version handshake (`versionReadCompleted == true` and valid `apiVersion`) before unlocking FC-dependent configuration tiles, keeping tiles safely locked when an FC is unpowered, booting, or silent.
- **Unresponsive Flight Controller Diagnosis & Connect Timeout (`ui/home.lua`, `tasks/msp`, `widgets/service`)**:
  - Unblocked the initial startup screen when a flight controller is silent (e.g. freshly flashed board with `FEATURE_TELEMETRY` disabled, or misconfigured MSP port), dismissing the loading spinner after ~6.0s instead of hanging indefinitely.
  - Automatically displays an actionable diagnostic notice explaining the root cause (*"No MSP reply from flight controller. Check that FEATURE_TELEMETRY is enabled and the MSP serial port is configured."*) and providing ELRS packet rate/ratio hints.
  - Reduced initial `API_VERSION` query timeout from 5.0s to 1.5s with 3 retries for rapid failure detection (~6s total) and exposed `session.mspLastError` and `session.mspErrorKind` across session and diagnostics state.
  - Updated the service widget to clearly report `"No MSP reply"` rather than `"Loading data... (0/5)"` when telemetry link is active but the flight controller remains silent.
- **Start Screen Bounded Wait & Startup Race Elimination (`ui/home.lua`)**:
  - Enforced an upper bound (max 2.0s offline, max 3.5s online) on the initial startup screen, preventing indefinite hangs when connecting to powered receivers with unresponsive flight controllers or wedged MSP links.
  - Eliminated the 0.6s timer race (0.45s vs 8.75s) by resolving the start screen as soon as core MSP identity (API version + MCU UID) is established, allowing onconnect tasks to run asynchronously in the background.
  - Replaced input-sensitive `state.lastInputTick` with dedicated `state.initialLoadStartTick` so key presses or touch gestures during boot do not restart the timeout timer.
  - Kept FBL-dependent menu tiles locked if startup times out without flight controller response, allowing pilots to access diagnostic tools instead of a frozen screen.
- **Diagnostics & Info Stalled Read Handling (`app/pages/tools/diagnostics/info`, `fblstatus`)**:
  - Added proactive timeout monitoring in `M.wakeup()` using `AsyncLoadUi.isTimedOut()` to abort stalled reads after 12s with clear modal feedback.
  - Added automatic link-loss detection and offline reload feedback notices.
  - Standardized per-request timeouts (3.5s) across diagnostic endpoints and fixed require path in `fblstatus/page.lua`.
- **ESC Configuration Save Timeout & Give-Up Notice (`app/pages/setup/esc_motors/esc_tools`)**:
  - Reduced ESC write timeout from 5.0s to 2.5s and added user-facing failure notice overlay on give-up so pilots are immediately informed when an ESC fails to acknowledge parameter writes.
- **Flight Log Selector Row Overlap & Sort Order (`app/pages/logs/page.lua`)**:
  - Fixed row layout height calculations in the flight log chooser, eliminating vertical text overlapping and clipping on compact displays.
  - Sorted flight logs in descending chronological order (newest files listed first).
- **Settings & Preferences Surface Consolidation (`lib/preferences.lua`, `settings/general`)**:
  - Consolidated `CONFIG_SCHEMA` in `settings/general` as single source of truth for save confirmations and disarm warnings.
  - Pruned orphaned preference keys (`txbatt_type`, `theme_loader`, `hs_loader`, `toolbar_timeout`, `iconsize`, `syncname`, `audio_switches`, `audio_timer`) and removed unreferenced audio stubs.
  - Fixed temperature unit conversion (`useFahrenheit()`) in dashboard telemetry text and flight log summaries.
  - Applied `sag_gain` in SmartFuel load calculation.
- **UI Layout & Display Profile Metrics (`ui/controls.lua`, `ui/display_profile.lua`)**:
  - Harmonized row metrics, reduced excessive vertical spacing, and widened multi-column numeric input fields across standard and high-resolution color radios (such as TX15 and TX16S).
  - Stripped UTF-8 BOM encoding from Lua files to avoid syntax errors on EdgeTX Lua interpreters.
- **Navigation Exit Debounce (`ui/home.lua`)**:
  - Debounced back-button navigation (`onBack`) to prevent rapid or repeated key events from causing accidental double-exit jumps from menus.
  - Stamped `lastBackTick` strictly on actual navigation transitions.
- **Battery Reserve Overwrite Protection (`setup/power/battery/page.lua`)**:
  - Fixed an issue where saving battery configuration without modifications could overwrite `cbat_alert_percent` (battery capacity reserve).
  - Removed unsafe preference seeding and ensured `batteryConfig` is safely populated and preserved on save.
- **Theme Color Token Normalization (`ui/controls.lua`, widgets)**:
  - Replaced hardcoded `GREY_DEFAULT` / nil color tokens with semantic theme color tokens across UI controls and widgets, fixing invisible text and rendering artifacts under custom color themes.
- **Help View Paragraph Spacing & Height Estimation (`ui/help_view.lua`)**:
  - Removed duplicate paragraph spacing in `estimateWrappedTextHeight`, aligning text container height estimation with native EdgeTX LVGL label rendering (48 px for 2 paragraphs instead of 80 px) and eliminating unnecessary scrollable whitespace.
- **FC Version Simulator Fixture Sync (`tasks/msp/api/fc_version.lua`)**:
  - Updated `fc_version` mock fixture from `{ 4, 5, 1 }` (RF 2.2.1) to `{ 4, 6, 0 }` (Rotorflight 2.3.0 / FC 4.6.0), synchronizing mock telemetry with `build_info.lua`.
- **UI Controls, Heights & Display Spacing (`ui/controls.lua`)**:
  - Unified native LVGL widget heights (standard 36 px), font rounding, and vertical alignments across all pages (PIDs, Rates, Mixer, Modes, Failsafe, Governor, Trims).
  - Resolved wide-display layout spacing and boundary clipping on large color touchscreens (e.g. 800x480).
- **Settings Lifecycle & Unsaved Changes Tracking (`settings/common.lua`)**:
  - Integrated all six settings form pages (`audio/events`, `audio/switches`, `audio/timer`, `dashboard/theme`, `general`, `localization`) into the suite's `ui.dirty` unsaved changes lifecycle.
  - Introduced non-rebuilding `runtime.markValueChanged()` for inline numeric controls to prevent focus loss during scrollwheel edits, alongside `runtime.markDirty()` for structure-altering toggles.
  - Added reusable `getValueSetter(key)` helper in form runtime.
- **Combo Selector Unknown Value Fallback (`ui/controls.lua`)**:
  - Replaced misleading fallback to the first option when an unknown value is returned from hardware with a dynamic "Unknown (%s)" / "Unbekannt (%s)" placeholder.
  - Added defensive guard in `set()` to ensure selecting or confirming the placeholder is a safe no-op.
- **Notice Dialog Bounded Dimensions (`ui/loading_overlay.lua`)**:
  - Fixed word-wrap line calculation (`countMessageLines`) against `innerW` matching LVGL layout behavior.
  - Added hard geometric bounds (`roomForLines`) and UTF-8 safe bisection truncation with ellipsis (`...`), guaranteeing dialog action buttons (OK/Dismiss) never run off the screen.
- **ESC Configuration (YGE, Hardware Protection)**:
  - Consolidated YGE model names and capabilities into a single source of truth (`escModels`) and added support for **YGE Saphir 125 V2** (ID `4691`) with 12V BEC capability.
  - Fixed silent UI display and save clamping on 10.0V BEC settings for 12V-capable YGE ESCs.
  - Restored `Keep mAh` (flags bit 2) and `Startup Response` (`acceleration` U16) controls on the YGE ESC configuration page.
  - Prevented full-page scene teardown and preserved active inline editors when adjusting ESC parameters.
- **SmartFuel Reserve Consolidation (`lib/smartfuel_reserve.lua`)**:
  - Consolidated SmartFuel capacity reserve arithmetic into a single centralized module, eliminating divergent calculations between telemetry widgets and diagnostics.
- **Model Name & Preference Persistence Across Updates**:
  - Prevented installer packages and deploy tasks from overwriting user `preferences.ini`.
  - Moved Model Sync settings directly onto the Model page (`setup/model`).
  - Fixed cold-start restore to prevent temporary model names from restoring after cold boots or telemetry dropouts.
  - Restricted model writes strictly to widget runtimes.
- **Save Callback Error Handling (`tasks/msp/save_pipeline.lua`)**:
  - Wrapped page save callbacks in `pcall` guards to capture errors and report them cleanly in the notice box.
- **Dialog Fallback Handling (`ui/controls.lua`)**:
  - Properly recognized asynchronous `lvgl.confirm` dialogs as active modals, preventing premature fallback invocation.
- **Session Logs Text Overlap & Contrast Fix (`app/pages/tools/diagnostics/session_logs/page.lua`)** (fixes #91):
  - Fixed text overlap / overdrawing: log entries are now truncated with an ellipsis (`…`) via binary-search `fitToWidth` to guarantee each line occupies exactly one `rowH` row, regardless of message length.
  - Fixed invisible / low-contrast text on light EdgeTX themes: added a solid `COLOR_THEME_PRIMARY3` background panel for the log view and replaced `GREY_DEFAULT` (white/near-white on light themes) with `COLOR_THEME_DISABLED` for `debug` and `trace` log levels, guaranteeing readable contrast on all EdgeTX themes (including light blue and unstyled page backgrounds).
  - Dynamically derived `rowH` and `maxVisible` from font metrics via `textSize("Ag", SMLSIZE)` instead of assuming a fixed height, correctly adapting across 320x240, standard, and 800x480 radio display classes without overdrawing or boundary clipping.
- **Runtime Locale Resolution & Language Selector (`lib/system_locale.lua`, `settings/localization/page.lua`, `lib/preferences.lua`) – fixes #103**:
  - `system_locale.lua:resolveSystemLanguage()` previously returned the build-time template placeholder `@i18n_language@` verbatim at runtime in uncompiled / simulator mode. `I18n.new("@i18n_language@")` failed to load any bundle and silently fell back to English, causing all Settings › General labels and confirmation dialogs to appear in English regardless of the selected language.
  - Introduced a three-step runtime fallback: ① read `language` from `[localizations]` in `preferences.ini` (set via Settings › Localization); ② read the EdgeTX `LANGUAGE` global (where exposed by the firmware); ③ caller-supplied default (`"en"`). The `@i18n_language@` marker is retained as a precompile token only – packaged release builds still get the locale baked in at build time, while source/simulator runs now correctly pick up the user's chosen language.
  - Added a **Language** dropdown (English / German) to Settings › Localization so users can set their preferred UI language; the choice is persisted in `preferences.ini` under `[localizations] language` and takes effect on the next tool open.
  - Added `language = "en"` to `lib/preferences.lua` defaults so the key is always present in newly created `preferences.ini` files.
- **Save & Reload Interlock, Non-Blocking Feedback & Local Settings While Armed (`ui/home.lua`, `i18n`, fixes #136)**:
  - Header Save and Reload actions remain interactive on pages that declare them instead of forcing them disabled in the header layout, ensuring user input reliably routes to `onSave` / `onReload`.
  - When the modal warning preference is disabled (`save_armed_warning = false`), tapping Save or Reload provides immediate non-blocking feedback by temporarily updating the top armed banner to `"Save blocked: Model is ARMED!"` / `"Reload blocked: Model is ARMED!"` for 2.5 seconds before auto-reverting, keeping the page visible and navigable.
  - Relabeled the safety switch in Settings › General to "Show Disarm Warning on Save/Reload" to reflect that it governs armed notices for both operations.
  - Unblocked saving on local tool settings pages (`settings_*` such as Preferences, Audio, Localization) while armed, as these pages do not communicate with the FC via MSP.
  - Saving FC parameters while armed remains strictly blocked in all cases.

### Performance, Memory & Build System
- **Tile & Theme Icon Pre-Scaling to 40x40 (`app/pages`, `widgets/dashboard/themes`)**:
  - Pre-scaled all 148 page/tile icons and 7 theme icons to exact 40x40 px using Lanczos resampling.
  - Reduced C-heap decode buffer allocation from 19.6 kB to 6.4 kB per PNG decode (3.1x reduction), reducing LVGL image cache footprint from ~78 kB to ~26 kB and eliminating LVGL heap exhaustion (`ta` error tiles) on image-heavy menus.
  - Cut total asset disk footprint by 51.3% and eliminated software zoom/scaling overhead on 800x480 displays.
- **Codebase GC & Memory Cleanup (`allowMemAutoRefresh`)**:
  - Removed 60 obsolete `allowMemAutoRefresh()` function stubs across all page modules and dashboard themes to reduce garbage collection churn and memory overhead.
- **Incremental Bytecode Compilation & Build Identity (`lib/precompile.lua`, `bin/package/build_package.py`)**:
  - Implemented incremental startup bytecode compilation checking file modification timestamps (`fstat`) with 2-second FAT tolerance against bytecode timestamps, only recompiling modified or stale Lua sources.
  - Integrated deterministic SHA-256 build identity hashing (`build.txt`), ensuring complete cache invalidation between releases.
- **Early Link-Ready Dashboard Rendering (`widgets/dashboard`)**:
  - Render telemetry dashboard immediately upon establishing the RF/MSP telemetry link without waiting for the full multi-step initialization chain.
- **Startup Pacing & Queue Optimization**:
  - MSP queue runner takes a second pass immediately after callers populate it, reducing round-trip latency.
  - Background task ticks twice as fast during initial connection startup.
  - Eliminated redundant readiness holds on initial connect and validated battery readiness using explicit status flags.
- **Bytecode & Loader Caching**:
  - Precompiled Lua bytecode cache at start and eliminated obsolete unread bytecode writes.
- **Build & Deployment Tooling**:
  - Fixed Python runtime detection across Windows and POSIX environments.
  - Added robust language discovery supporting VS Code JSONC user settings, profiles, and workspace settings.

# 0.1.5

### Features & Enhancements
- **Save Pipeline & Reboot Synchronization (`tasks/msp/save_pipeline.lua`)**:
  - Implemented a unified asynchronous save pipeline with automatic post-save reboot synchronization (`MSP_SET_REBOOT`) and response verification.
  - Replaced uncoordinated native dialog popups with integrated status reporting directly inside the `LoadingOverlay` notice box.
  - Added direct error and save refusal reporting, notifying the user when and why a write was rejected.
- **Dedicated Background Service Widget (`widgets/rfsuitesvc`) & Settings**:
  - Added standalone `rfsuitesvc` background service widget running MSP communication and telemetry tasks independently of the main configuration tool.
  - Added dedicated Service settings page (`settings/service`) for background link configuration.
- **Model Configuration & On-Connect Synchronization (`setup/model`, `tasks/events/onconnect`)**:
  - Added Model Configuration page (`setup/model`) to inspect and edit flight controller model name and pilot configuration parameters.
  - Implemented background synchronization tasks (`model_name_sync`, `model_params_sync`) to mirror FC model parameters onto the radio.
  - Added support for signed pilot config parameters (`MSP_PILOT_CONFIG`).
- **In-Flight Live Adjustment Announcements (`telemetry_bg/adjustments`)**:
  - Added real-time voice feedback when adjustments (e.g. gains, rates, governor trims) are changed via transmitter switches or rotary knobs during flight.
- **Interactive Telemetry Log Plotting (`diagnostics/flight_logs`)**:
  - Added graphical plotting of telemetry log channels against flight time.
  - Sized the plot view accurately against the active page body rather than the full display height.
- **Armed-State Safety & Visual Feedback (`ui/home.lua`, `ui/tiles.lua`)**:
  - Replaced blocking full-screen armed warning with an intuitive status strip across the home menu and locked tile badges.
  - Prevented MSP write and save actions while the craft is armed while maintaining passive telemetry draining.

### Bug Fixes & Improvements
- **Servos Configuration (`setup/servos/bus`, `setup/servos/pwm`)**:
  - Corrected bus servo addressing across three distinct index spaces (hardware ID, logical servo index, protocol slot).
  - Switched from full-table queries to individual servo queries (`get_servo_config`) to prevent telemetry RX buffer overflow.
  - Extracted `servo_count` directly from status reply payloads.
- **Adjustment Ranges Paging (`setup/controls/adjustments`)**:
  - Implemented paged reading of adjustment tables (`MSP_ADJUSTMENT_RANGE`) on compatible firmware versions to prevent unread configurations from displaying as empty tables.
- **ESC Configuration Hardening (YGE, Hobbywing V5, Scorpion, FlyRotor)**:
  - Fixed 8-byte parameter payload alignment for YGE ESCs.
  - Preserved byte-exact Hobbywing V5 device info blocks during save operations.
  - Respected FlyRotor byte-order endianness flag and prevented unintentional serial number overwrites.
  - Validated Scorpion response headers and payload lengths to reject short or malformed packets.
  - Added post-save parameter re-reads across all ESC tools to wait out device save lockouts.
- **Preferences & Settings Resilience**:
  - Removed 2048-byte limit when reading `preferences.ini`, ensuring large preference stores load completely.
  - Preserved section expansion states across page closes and reloads.
  - Properly persisted the "Confirm on Save" setting.
- **UI & Loading Overlay**:
  - Added the Rotorflight logo and connection progress status on the start screen.
  - Improved loading notice box geometry to support wrapping long titles and scaled line spacing from font metrics.
  - Standardized all modal dialog calls to `lvgl.message` (removing invalid `lvgl.alert` calls).
- **Localization (i18n)**:
  - Enhanced packaging resolution for pages constructed via `buildSimplePage` and dynamic UI elements in German and English.

### Performance & Memory Optimizations
- **Dashboard Refresh & Theme Resolution**:
  - Memoized dashboard theme script paths to avoid repeated path resolutions per cycle.
  - Reused grid coordinate arithmetic during telemetry value-only repaints.
  - Eliminated forced full garbage collection runs on every frame to avoid UI stuttering.
- **Log Browser Pacing**:
  - Switched telemetry log parsing to bounded, incremental read steps.
  - Optimized string measurement with bisection line-breaking for log summary lists.

# 0.1.4

### Bug Fixes & Improvements
- **Blackbox Status Page**:
  - Fixed a nil index error (`attempt to index a nil value (upvalue 'SdcardSummaryApi')`) occurring when navigating away or closing the Blackbox status page while MSP summary queries are in flight.
  - Safeguarded asynchronous MSP response callbacks against page unloads and nil module references.
- **Controls & Modes Setup (`setup/controls/modes`)**:
  - Standardized control heights for range inputs and action buttons (`+ Add`, `Set`, `X`, AUX/Logic choices, Min/Max numbers) to match the standard widget height used in the Rates and PIDs tables.
  - Fixed focus loss when editing numbers or dropdowns by removing premature full-page rebuild calls from value setters.
  - Expanded row heights and inter-row spacing to prevent separator lines from intersecting input controls.
- **Controls & Failsafe Setup (`setup/controls/failsafe`)**:
  - Standardized mode choice and failsafe pulse value inputs to native framework widget dimensions.
  - Adjusted row height to `56 px` with centered vertical offsets to ensure clean visual separation and avoid divider line clipping.
- **Hobbywing Platinum V5 ESC Configuration (`setup/esc_motors/esc_tools/hw5`)**:
  - Fixed MSP parameter parsing and write serialization by implementing dynamic `itemBytes` profile layouts (`DEFAULT_LAYOUT`, `HW1132_LAYOUT`, `HW1128_LAYOUT`, `OPTO_LAYOUT`) matching Rotorflight firmware specifications.
  - Fixed shifted and corrupted field values on OPTO ESCs (130A HV, 200A HV, 260A HV) caused by omitted BEC voltage field in OPTO telemetry payloads.
  - Corrected raw offset translation for `startup_time` (`value = raw + 4`) on reading and writing.
  - Fixed inverted `Active Freewheel` option mapping (`0 = Enabled`, `1 = Disabled`).
  - Added support for `response_time` setting (1–10) on compatible ESC models (e.g. HW1132).
  - Improved ESC model string decoding in `init.lua` to read full 31-byte model identification.
  - Corrected profile detection and layout field filtering in `profile.lua`.

# 0.1.3

### Bug Fixes & Improvements
- **Dashboard & Themes**:
  - Fixed model-specific dashboard theme switching (`model_override`) to immediately take effect without requiring a radio restart.
  - Corrected theme resolution fallback when model override is active and inflight/postflight themes are unassigned, ensuring the model's preflight theme remains active.
  - Ensured theme configuration adjustments (e.g. BEC voltage bounds, RPM limits, ESC temperature thresholds) are saved synchronously to both global (`preferences.ini`) and model-specific (`<mcu_id>.ini`) configuration files.
  - Added inter-process reload signaling between the configuration tool and standalone dashboard widgets using EdgeTX Global Variables (GV9 for FM0/FM8) and memory reload flags.
  - Fixed runtime crash after FBL initialization caused by single-argument `lcd.RGB` call in `@srb-rc` theme and safeguarded color conversion helpers in `common.lua` and `gauge.lua`.
  - Removed obsolete full-screen placeholder boxes in `@srb-rc` (`preflight.lua`, `inflight.lua`, `postflight.lua`) that caused unintended `"--"` text labels across the display.
  - Adjusted Postflight grid layout from 7 rows to 3 rows to eliminate the bottom background gap and utilize 100% of the screen height.
  - Corrected theme fallback loader in `runtime.lua` to properly fall back to the active flight mode's default theme script instead of non-existent `widget.lua`.
- **Save Progress & Localization**:
  - Fixed translation inlining for the save progress dialog (`app.saving` -> "Speichere...", `app.saving_settings` -> "Einstellungen werden angewendet").
  - Fixed English language package deployment by standardizing internal code fallbacks to English across settings pages (`settings_general`, `settings_audio_events`, `settings_audio_switches`, `settings_audio_timer`, `settings_localization`).
  - Enhanced the `precompile_i18n.py` build script to capture and inline dynamic `tr()` helper functions, `ctx.i18n` lookups, and section/item table definitions (`titleKey`/`titleFallback`, `labelKey`/`labelFallback`) during deployment and packaging.
- **Scorpion ESC Parameter Writing**:
  - Completed MSP 218 payload structure for Scorpion ESC (added missing `stick_max` and `stick_zero` fields to form full 84-byte payload) and named `serial_number`/`firmware_version` fields correctly to fix parameter save failures.
- **ELRS Link & Telemetry**:
  - Fixed ELRS packet rate parsing, RF link synchronization, and telemetry reload handling.
- **Audio & Telemetry**:
  - Restored model name and battery/initial fuel announcements upon model reconnect (e.g. plugging in a new battery) by resetting audio tracking states on connect and disconnect edges.
  - Enabled `name`, `battery_config`, and `smartfuel_config` background OnConnect tasks in both tool and widget contexts so battery capacity and model names are immediately available.
  - Added fallback to EdgeTX radio model name in `announceModelName()` if the FBL model name has not yet been received via MSP.
  - Aligned fuel audio callout behavior in the RFSuite tool with the dashboard widget by prioritizing Smart Fuel (`SmFt` / `smartfuel`) telemetry over standard fuel (`Bat%` / `fuel`) and adding `smartfuel = "SmFt"` to sensor aliases.
  - Renamed fuel callout option "Default (Only at 10%)" to "Only at 10%" ("Nur bei 10%") in audio event settings for clearer option distinction.
- **Deployment & Tooling**:
  - Supported configurable deployment language via VS Code settings (`rfsuite.deploy.language`) and build tasks.

# 0.1.2

### Performance & Memory Optimizations
- **Module & Singleton Memoization (`require.lua`)**:
  - Implemented centralized `rfsuite.require` module loader with bytecode and instance memoization to eliminate redundant disk reads and Lua compilations.
  - Integrated memoization into Tools entrypoint, telemetry widgets, background tasks, and dashboard runtime.
- **Dashboard Startup Pacing & Instruction Budget**:
  - Preloaded and memoized all dashboard object wrappers and subrenderers (`text`, `image`, `time`, `gauge`).
  - Removed artificial 14-box cap in simulator, allowing full layouts to render smoothly.
- **Garbage Collection & GC-Churn Reduction**:
  - Streamlined `Engine.renderKey` dirty-checking to eliminate intermediate table arrays and string allocations during refresh cycles.
  - Guarded debug log string concatenations in hot telemetry polling paths.
  - Eliminated anonymous closure allocations in repetitive MSP polling loops (`msp/queue.lua`) and background event runners.
- **SD Card I/O Reduction & Asset Cleanup**:
  - Removed redundant `io.open`/`close` probes in `help_registry.lua`.
  - Added in-memory path caches for audio WAV events and model images to avoid repeated file system checks.
  - Cleaned up obsolete legacy root icons from `src/rfsuite/assets/icons/`.

# 0.1.1

### Bug Fixes & Improvements
- **ESC Forward Programming & MSP Communication**:
  - Removed 4-Way Interface (`4wif_esc_fwd_prog`, MSP 244 target=100) from non-4WIF ESC manufacturers (XD-Fly, OMP, ZTW, Hobbywing Platinum V5, YGE, Scorpion, Flyrotor), eliminating motor beeping and communication timeouts.
  - Corrected header byte layout (`esc_version` before `esc_model`) in `esc_parameters_xdfly.lua`, `esc_parameters_omp.lua`, and `esc_parameters_ztw.lua`.
  - Fixed Governor P & I Gain active field mask indices for XD-Fly, OMP, and ZTW.
- **Dynamic On-Connect ESC Telemetry Detection**:
  - Added background OnConnect task `esc_sensor_config.lua` (with tool-only execution context) to query and dynamically enable active ESC tiles in the tools menu.
- **Audio & Telemetry Reliability**:
  - Restored `Audio.process` execution in configuration tool for announcements.
  - Fast-tracked simulator sensor reloads (0.5s interval).

# 0.1.0

### Features
- **Telemetry Flight Logs & Dashboard (`diagnostics/flight_logs`)**:
  - Implemented flight log browser and analytical dashboard to inspect EdgeTX CSV log files directly on the radio.
  - Added statistics calculations including min/max/average cell voltages, battery capacity consumption, RPM, temperatures, and flight durations.
  - Added interactive `LoadingOverlay` with non-blocking incremental parsing and proactive memory cleanup to keep the UI responsive on large CSV files.
- **RFSuite EdgeTX Updater Tool & CI**:
  - Added standalone and integrated EdgeTX Updater tool for automatic online and local updating of RFSuite packages.
  - Automated detection of available languages from repository branches and release tags.
  - Added multi-language CI build workflows and packaging scripts.
- **Governor Setup Pages**:
  - Ported Governor General setup page (`governor/general`).
  - Ported Governor Ramp Time configuration (`governor/ramps`).
  - Ported Governor Filters setup page (`governor/filters`).
  - Ported Governor Bypass Curve configuration (`governor/bypass`).
- **Dynamic ESC Sensor Detection**:
  - Added background `esc_sensor_config` task triggered on connection to query and identify active ESC telemetry protocol.
- **Manufacturer ESC Tools Integration**:
  - Ported and integrated full ESC configuration suites for Bluejay, BLHeli_S, Flyrotor, Hobbywing V5, OMP, Scorpion, XD-Fly, YGE, and ZTW.

### Localization (i18n)
- Localized flight tuning pages (PIDs, Rates, Governor, Rates Advanced) in German and English with fallback cleanup.

### Bug Fixes & Performance
- **Telemetry CSV Parsing Accuracy**: Improved header validation, outlier filtering (e.g. 0 RPM spikes), and memory efficiency during log analysis.
- **Reconnect Performance**: Resolved telemetry reconnect slowdowns and memory buildup using proactive garbage collection and cached LQ checks.

# 0.0.2

### Features
- **Compile-time Translation Inlining**: Introduced static translation inlining at compile time, simplified settings, and bumped version to 0.0.2.
- **Fuel Announcements**: Added initial fuel announcement and implemented differentiation between electric and gas/glow models in fuel callouts.
- **Developer Logging**: Made exit shutdown logging conditional on the developer `debug_level`.
- **Dynamic ESC Tools Lockout**: Automatically enable/disable manufacturer-specific ESC Tool menu tiles based on the active telemetry protocol queried via `esc_sensor_config`.
- **YGE ESC 12V BEC Support**: Dynamically adjust BEC voltage range up to 12.0V for supported models (205 HVT, 205 HVT BEC, 165 HVT, Aureus 105v2, Aureus 135v2, Saphir 155v2), capping older/standard models at 8.4V and synchronizing the `flags_bec12v` bit automatically.

### Security & Armed State (Model Armed)
- **Model Armed Blocking**:
  - Implemented `isModelArmed()` check in `home.lua` using the passive ARM telemetry sensor.
  - Blocked `MspRuntime.tick()` and active page wakeup from executing when model is armed to avoid serial connection hangs.
  - Added a full-screen armed warning screen at boot and during runtime if the model is armed.
  - Blocked subpage navigation, reloading, and saving actions with a warning dialog when armed.
  - Added German & English localizations for the armed title and warning messages.
- **Armed Warning Screen & Telemetry Check Optimization**:
  - Kept `MspRuntime.tick()` running when armed to drain the serial RX buffer and prevent telemetry loss.
  - Wrapped the armed warning screen in a standard page with a Close button and back-navigation support.
  - Checked `getRSSI()` to detect telemetry loss, skipping the check in the simulator to allow simulation of the armed state.

### Performance
- **Lag Reduction**: Cached compiled Lua chunks and optimized the exit cleanup sequence to resolve lags.

### Bug Fixes
- **Audio Callouts & Alarms**:
  - Corrected empty battery warning path for electric models to `"stat/alerts/lowbat.wav"` ("Flugakku leer") instead of the radio's native low battery warning.
  - Optimized fuel threshold countdown logic to jump directly to the lowest crossed threshold without stepped intermediate announcements.
- **Focus Preservation & Page Rebuilds**:
  - Redesigned `buildSessionSignature()` across all ESC pages (AM32, BLHeli_S, Bluejay, Flycolor, Hobbywing V5, OMP, Scorpion, XD-Fly, YGE, ZTW) to prevent background wakeup loops from stealing focus while editing fields.
  - Added value-change guards in `controls.lua` for number fields and combo selectors to ignore layout-time init events and prevent unintended dirty states.
- **Telemetry Freezes & Hangs**:
  - Unconditionally run `Events.wakeup()` in `home.lua` to keep the background `telemetry_bg` task running.
  - Skip onconnect tasks when armed in `tasks/events/runtime.lua` to prevent FBL configuration requests.
  - Run the `telemetry_bg` task even when armed to parse custom CRSF frames and update radio sensors.
  - Skip startup version and UID reads when armed in `tasks/msp/runtime.lua`.
- **Audio Processing**: Enabled `Audio.process` in the configuration tool for live voice feedback (profiles, rates, telemetry).
- **ESC Configuration (AM32)**:
  - Restored ESC target to 100 on `am32/page.lua` close and performed a post-save reset cycle to apply and save settings.
  - Fixed MotorConfigApi command reference in `am32/page.lua` (using `.command` instead of `.readCommand`).
  - Implemented retry logic for motor config reads when the FBL returns empty buffers.
  - Added German & English localizations for ESC config loading and saving messages.
- **Alignment Page**:
  - Added guards for `ui.runtime` checks in `alignment/page.lua` async callbacks to prevent nil errors after page close.

### UI & Miscellaneous
- **Layout Redesign**: Redesigned alignment layout to two rows, widened Roll/Nick/Yaw fields and Magnetometer combobox to 160px.
- **Git Config**: Updated `.gitignore`.
