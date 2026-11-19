# AppVolumeLock

**AppVolumeLock remembers per-app volume levels from the Windows volume mixer and puts them back when Windows 11 resets them to 100%.**

A single-file PowerShell utility. No installation, no drivers, no services, no tray icon — just a background loop over the Core Audio API (WASAPI).

[Русская версия](README.ru.md) · [MIT License](LICENSE)

---

## The problem

Windows 11 lets you set a separate volume for every application in **Settings → System → Sound → Volume mixer**. The values are persisted, but Windows overwrites them with **100%** whenever something re-creates or re-registers the app's audio session:

- the application restarts or re-creates its audio stream;
- you switch the default playback device (headphones ↔ speakers);
- a long-idle app starts playing again;
- the audio service restarts.

Windows has no concept of "this is the level the user actually wants": the last writer wins. For apps you deliberately keep at 20–40%, the result is a sudden blast of sound — and a slider that has to be dragged back every time.

Editing the undocumented registry blobs where Windows stores those levels is unreliable and unsupported. A small watchdog that reacts to the reset is the practical fix.

## What it does

AppVolumeLock is **a memory for the mixer, not a fixed-volume enforcer**. It never fights you: if you move a slider, that becomes the new remembered value.

| Situation | Behaviour |
| --- | --- |
| An app appears in the mixer for the first time | Remembers its current level as the baseline |
| You move a slider | Saves the new level as intentional |
| The app restarts, a new audio session appears | Restores the remembered level |
| Windows jumps the slider to 100% | Restores the remembered level, even mid-playback |
| The reset happened while the mixer was open | Fixes it on the next pass |
| Several sessions share one app (e.g. Discord) | Each slider is remembered separately |

## How it works

Every 5 seconds the script enumerates the audio sessions of the default playback device and compares each session's current level with the remembered one.

**Reset or intentional change?** The utility checks which window is in the foreground:

- Settings (`SystemSettings` / `ApplicationFrameHost`), the legacy `SndVol`, the quick-settings flyout (`ShellExperienceHost` / `ShellHost`), or any window whose title mentions *mixer / volume / громкость* → the mixer is open, so **any change is treated as yours** and saved, including a deliberate 100%;
- otherwise, a jump **exactly to 100%** while the remembered level is lower → treated as a **Windows reset** and reverted;
- any other jump → also treated as your edit and saved.

This is why the utility does not need to know *why* Windows reset the level: the mixer being open is the signal that a human is touching the slider.

**Multiple sessions per app.** One application can expose several sliders (Discord has separate voice and notification sessions, and both share the same session identifier). Sessions are tracked by `SessionInstanceIdentifier` **plus** process ID, so editing one slider never drags the other along. Rules can additionally split them by the owner process command line.

**Persistence.** Remembered levels are stored in a small JSON file and survive reboots. A named mutex prevents a second instance from running.

## Requirements

- Windows 10 or Windows 11 (developed and tested on Windows 11).
- Windows PowerShell 5.1 — included with Windows. PowerShell 7 is not required and is not the tested configuration.
- No administrator rights to run. Registering the logon task may require elevation depending on policy; if it fails, `-Install` falls back to a shortcut in the Startup folder.
- No external modules, drivers, services or network access.

## Quick start

```powershell
git clone https://github.com/d1m40fficial/AppVolumeLock.git
cd AppVolumeLock

# Files downloaded from the internet are blocked by default
Unblock-File .\AppVolumeLock.ps1

# Read-only: show live sessions, remembered levels, rules and keys
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -ListSessions

# Register autostart (scheduled task at sign-in, hidden window)
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Install
```

Prefer no autostart? Run the script without parameters and leave the window open (or minimized):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1
```

The first pass remembers whatever is currently in the mixer. Move the sliders to the levels you want **with the mixer open**, and those levels become the reference.

## Command line

| Parameter | Description |
| --- | --- |
| *(none)* | Run the background loop (5 s interval by default) |
| `-ListSessions` | Print all current audio sessions, remembered levels, matched rule and memory key; then exit |
| `-Once` | Run a single pass and exit (debugging) |
| `-IntervalSeconds <int>` | Poll interval in seconds; `0` uses the value from `$Config` |
| `-LogFile <path>` | Log file path |
| `-NoLog` | Do not write a log file |
| `-Reset` | Forget all remembered levels (deletes the memory file); rules are untouched |
| `-Install` | Register autostart and exit |
| `-Uninstall` | Remove autostart and exit |

Examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Once
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -IntervalSeconds 2
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Reset
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Uninstall
```

## Configuration

All settings live in the `$Config` block at the top of the script.

| Key | Default | Meaning |
| --- | --- | --- |
| `IntervalSeconds` | `5` | How often sessions are checked |
| `MemoryFile` | `%LOCALAPPDATA%\AppVolumeLock\volume-memory.json` | Where remembered levels are stored |
| `Rules` | Discord, Chrome, Edge, Firefox | Exceptions for individual apps (see below) |
| `TrackAllProcesses` | `$true` | Track every app that has audio; `$false` switches to an allow-list mode driven only by `Rules` |
| `SilenceResetSeconds` | `20` | Deprecated and ignored; kept so old configs do not break |

### Rules

Rules are **exceptions**, not an allow-list. With `TrackAllProcesses = $true` (default), apps that match no rule are still tracked under a key equal to their process name in lower case. Rules are evaluated top-down and the **first match wins**.

Rule fields:

| Field | Meaning |
| --- | --- |
| `Name` | Human-readable name used in logs |
| `Process` | Process name; wildcards allowed (`chrome`, `Discord*`) |
| `Key` | Memory key; defaults to the process name in lower case. Use distinct keys to remember sessions separately |
| `SessionIdentifier` | Regex the session identifier **must** match |
| `NotSessionIdentifier` | Regex the session identifier **must not** match |
| `ProcessCommandLine` | Regex for the owning process command line — the only reliable way to tell apart sessions that share identifiers |
| `NotProcessCommandLine` | Negative regex for the command line |
| `DisplayName` | Regex the session display name must match |
| `NotDisplayName` | Negative regex for the display name |
| `Ignore` | `$true` — never touch these sessions |
| `SkipSystemSounds` | `$true` by default — leave system sounds alone |

Shipped examples:

```powershell
Rules = @(
    # Discord exposes two sliders (voice / notification sounds) with the same
    # session identifier. The owner command line is what differs:
    #   --type=utility --utility-sub-type=audio.mojom.AudioService -> notifications
    #   --type=renderer                                          -> voice
    @{ Name = 'Discord: notifications'; Process = 'Discord'; Key = 'discord:notifications'
       ProcessCommandLine = 'utility-sub-type=audio\.mojom\.AudioService' }
    @{ Name = 'Discord: voice'; Process = 'Discord'; Key = 'discord:voice'
       NotProcessCommandLine = 'utility-sub-type=audio\.mojom\.AudioService' }

    # Browsers spawn many audio processes per app -> one key per browser
    @{ Name = 'Chrome';  Process = 'chrome*';  Key = 'chrome' }
    @{ Name = 'Edge';    Process = 'msedge*';  Key = 'edge' }
    @{ Name = 'Firefox'; Process = 'firefox*'; Key = 'firefox' }
)
```

Use `-ListSessions` before writing rules: it shows the live session identifier, process ID, current and remembered volume, matched rule, memory key and the command-line role (e.g. `utility: audio.mojom.AudioService`).

## Files and data

| Path | Purpose |
| --- | --- |
| `%LOCALAPPDATA%\AppVolumeLock\volume-memory.json` | Remembered levels |
| `%LOCALAPPDATA%\AppVolumeLock\app-volume-lock.log` | Log; rotated to `.old` at 1 MB |
| Scheduled task `AppVolumeLock` | Autostart at sign-in (primary method) |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\AppVolumeLock.lnk` | Autostart fallback if the task cannot be registered |

Memory file format:

```json
{
  "version": 1,
  "channels": {
    "chrome": {
      "volume": 0.35,
      "process": "chrome",
      "updatedUtc": "2026-11-19T12:34:56.7890123Z"
    }
  }
}
```

`volume` is a fraction from `0.0` to `1.0`, matching the mixer scale.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| The level still jumps to 100% | Look at the log: repeated resets mean the app re-creates its audio stream constantly. Try `-IntervalSeconds 2`, and make sure only one instance is running |
| My intentional change was reverted | Change the slider while the mixer or Settings page is in the foreground — that is how the utility recognises a human edit |
| I want a permanent 100% | Same: set 100% with the mixer open and it will be remembered as intentional |
| An app is not tracked | It must have a live audio session; expired sessions are skipped. Check `-ListSessions` |
| The script does not start | Run `Unblock-File .\AppVolumeLock.ps1`; the commands above already bypass the execution policy |
| Antivirus warns about the script | The script compiles a small C# helper **in memory** via `Add-Type`; it downloads nothing and installs nothing. The source is in the file |
| Discord's two sliders share one value | The shipped rules separate them; verify them with `-ListSessions` |
| Levels differ after switching output devices | Windows keeps mixer levels per output device. AppVolumeLock normalises the level on the **current default device**; per-device profiles are not supported |

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\AppVolumeLock.ps1 -Uninstall

# Optional: forget remembered levels and delete logs
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\AppVolumeLock"
```

Then delete the script folder. No services, drivers or registry keys are created; only the scheduled task (or Startup shortcut) is removed.

## Limitations

- Default playback device only (`eConsole` role); capture/input sessions are not handled.
- 5-second polling by default; very short sessions may be missed.
- No GUI and no tray icon — configuration is done by editing the script.
- Console output, log messages and rule names are in Russian.
- Mixer detection is heuristic; future Windows UI changes may require updating the foreground process names.

## License

MIT — see [LICENSE](LICENSE).

---

**Keywords:** Windows 11 volume mixer reset, per-app volume resets to 100, application volume not saved, audio bug workaround, WASAPI, Core Audio, PowerShell.
