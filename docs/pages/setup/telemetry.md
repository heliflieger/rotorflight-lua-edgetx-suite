---
title: Telemetry
sidebar_label: Telemetry
sidebar_position: 30
---

# Telemetry

Configuration of flight controller telemetry sensors. The flight controller can stream real-time flight data to the transmitter over CRSF (Crossfire / ELRS) or FrSky SmartPort.

## Where to find it

*Configuration* → *Setup* → *Telemetry*

Read-only while the model is armed.

## Mode Awareness

The header of the page indicates the active telemetry mode configured on the flight controller:

- **CRSF Telemetry: Native**: The flight controller sends standard CRSF frames for the native sensors whose IDs occupy telemetry slots (e.g. Attitude, Flight Mode, Altitude). These sensors are locked on in the page because removing them from the slots would stop the flight controller from sending them. Additional custom sensors require Custom mode. Unmanaged sensor slots on the flight controller are preserved in place, and conflicting individual sub-axes (e.g. pitch/roll/yaw attitude) are disabled when their parent is native-locked.
- **CRSF Telemetry: Custom**: The flight controller transmits individual custom telemetry sensors selected from the catalog.

## Sensor Slots & Limits

The flight controller provides up to 40 telemetry sensor slots (`telemetry_sensors[40]`).
Any sensor slot holding an ID outside the custom catalog (such as native CRSF sensors or aggregate sensors) is preserved in place upon saving. Saving writes selected catalog sensors to available slots while ensuring the total number of enabled sensors does not exceed the 40-slot hardware limit.

## Actions

- **Save**: Writes the enabled telemetry sensors to the flight controller and saves to EEPROM.
- **Reload**: Re-reads the current telemetry configuration from the flight controller.
- **Star (*)**: Loads default custom telemetry sensors into the selection.
