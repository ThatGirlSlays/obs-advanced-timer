# OBS Advanced Timer

Count up / count down timers for OBS Studio with actions that run when they complete. One copy of the script runs up to 10 independent timers, each with its own text source and settings.

By ThatGirlSlays. Version 1.0.5 (the version is shown at the top of the script's panel in OBS).

**Install**
1. Download [`thatgirlslays-advanced-timer.lua`](thatgirlslays-advanced-timer.lua) (Download raw file button) and save it in a folder you'll keep, e.g. Documents/OBS Scripts.
2. To update later, download the new version over the same file and press the reload button in Tools > Scripts. Your settings are kept.

**Setup**
1. Create a text source and put "Timer" in its name, for example "Stream Start Timer".
2. In OBS go to Tools > Scripts, press +, and pick `thatgirlslays-advanced-timer.lua`.
3. Set "Number of timers", pick a timer under "Edit timer", then choose its text source, type and duration and press Start / Pause.

The text source list only shows text sources with "Timer" in the name. Tick "List all text sources" to see every one. If you add sources or scenes while the script panel is open, press "Refresh source and scene lists".

**Timer**
- Count down: starts at the duration and counts down to 00:00:00.
- Count up: starts at 00:00:00 and stops at the duration. Leave the duration at 00:00:00 for a count up that never stops.
- Duration is typed as hh:mm:ss (mm:ss and plain seconds also work).
- Hotkeys for each timer's Start / Pause and Reset can be set in Settings > Hotkeys ("Advanced Timer 1: ...").

**Activation mode**
- Manual: only the buttons and hotkeys start, pause and reset it.
- Restart when the text source goes live: starts from the beginning each time the text source appears in the program output (on stream, not just in the preview).
- Run only while the text source is live: runs while the text source is in the program output and pauses when it isn't.
- Restart when streaming starts / when recording starts.

**Display**
- Standard format, with checkboxes: hide leading 00 (00:08:30 shows as 08:30, and under a minute 00:00:08 shows as 08), hide leading single 0 (08:30 shows as 8:30, 08.05 as 8.05), and show hundredths (07:48.19).
- Custom format: type your own, e.g. `%h:%mm:%ss.%ff`.
  - `%d` days, `%h` hours, `%m` minutes, `%s` seconds. Double the letter for 2 digits (`%hh`, `%mm`, `%ss`).
  - `%f` tenths, `%ff` hundredths, `%fff` milliseconds. `%%` is a percent sign.
  - The largest unit used holds the rest of the time, so `%mm:%ss` shows 1 hour 5 minutes as 65:00.
  - Other text is kept as typed, e.g. `Starting in %m min %ss sec`.
- Text before and after the time (works with both formats).

**When the timer completes** (any combination)
- Timer text: keep the final value, hide the text source, change the text, or reset to the starting value.
- Change scene, hide a source, show a source. Hiding/showing applies to the source in every scene it is in.
- Press hotkey: type a combo such as `Ctrl+Shift+F5` that is bound to something in Settings > Hotkeys. The script presses it inside OBS (it does not send keys to other programs). Use "Test hotkey" to check it. Modifiers: Ctrl, Shift, Alt, Cmd/Win.
- Audio: every audio source (mic, desktop audio, media files, ...) is listed. Pick Mute or Unmute and set a delay/offset in milliseconds. A positive number runs that long after the timer completes (1000 = 1 second later). A negative number runs that long before it completes (-10000 = 10 seconds early, handy for a 10 second countdown sound).

**Version history**
- 1.0.5: moved to its own repository; file name is now `thatgirlslays-advanced-timer.lua` with no version in it.
- 1.0.4: author and version shown in the Scripts panel.
- 1.0.3: hiding leading 00 also drops empty minutes under a minute (8.05 instead of 0:08.05).
- 1.0.2: fixed OBS freezing when a completed timer changed scene.
- 1.0.1: multiple timers, activation modes, custom format.
- 1.0.0: first version.
