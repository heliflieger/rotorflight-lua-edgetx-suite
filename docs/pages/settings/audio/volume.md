---
nav_order: 2
parent: Audio
grand_parent: Settings
---

# Volume

The Volume page allows you to configure Adaptive Audio-Level and the Master-Volume bridge.

## WAV-Volume Level (Layer A)

* **Level:** Set the base volume level for audio announcements (1..5). Set to 0 (default) to let the radio's own volume setting rule.
* **Connected Only:** When enabled, the elevated audio level applies only when a flight controller is connected.

## Master-Volume Bridge (Layer B)

The Master-Volume bridge dynamically changes the entire radio's volume during flight, and forces it to a loud level during critical alarms (like Low Voltage or ESC Temperature).
To use this, you must configure a Global Variable (GVAR) on your radio and link it to the volume.

**Radio Setup (Once per model):**
1. **Settings > Audio > Volume:** Set *GVAR* to a free Global Variable (e.g., **GV9**). Set your desired *Normal* and *Alert* volume levels.
2. **Inputs:** Add one input, e.g. `I15 "Vol"`, **Source = GV9**, weight 100. (Give it its own slot and leave it out of the mixer).
3. **Logical Switch:** Create a logical switch `L10: a > x` with **a = GV9**, **x = -1024**. This is true while the suite is driving the volume.
4. **Special Function:** Create a special function `SF: L10 -> Volume = I15 (Vol)`. (Use the **input**, not the GVAR).

When the suite is not driving the volume (e.g. disconnected or feature off), it writes `-1024` to the GVAR. This makes the logical switch false, the special function releases, and your regular volume pot regains control.

> [!NOTE]
> Retiring the feature does not automatically release the GVAR. The last written value stays in the model file, so the pot will remain overridden until something writes `-1024` again.
