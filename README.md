<p align="center">
  <img src="docs/icon.png" width="112" height="112" alt="Centre app icon">
</p>

<h1 align="center">Centre</h1>

<p align="center">
  A native macOS launcher and taskbar. One keystroke from anything.<br>
  <sub>Objective-C · AppKit · no Xcode · no dependencies · no telemetry</sub>
</p>

<p align="center">
  <img src="docs/home-dark.png" width="760" alt="Centre's home: now playing, most used apps, quick actions, clipboard and recent files">
</p>

## What it does

- **Search** apps, settings, commands, files, open browser tabs and clipboard history, ranked by what you use at this hour.
- **Home** adapts to where you came from: a browser's other tabs, a terminal's last commands, actions for selected text.
- **Status line, notes and shelf:** time, next event, battery; `note …` keeps a line on Home; drop files onto the shelf.
- **Tools:** calculator, units, dictionary, timers, passwords, text transforms, time zones, emoji, window snapping.
- **Taskbar (optional):** one button per window, music controls, tray and clock; keeps windows clear of the bar.

<table>
  <tr>
    <td width="50%"><img src="docs/deck.png" alt="Home opened from Safari"></td>
    <td width="50%"><img src="docs/tabs.png" alt="Tab search"></td>
  </tr>
  <tr>
    <td align="center"><sub>Opened from Safari: status line, a note, that window's tabs</sub></td>
    <td align="center"><sub><code>tab guide</code> jumps to any open tab</sub></td>
  </tr>
</table>

<p align="center">
  <img src="docs/taskbar-dark.png" width="900" alt="Centre's taskbar">
</p>

## Keys and prefixes

| Input | Does |
| --- | --- |
| `⌘ Space` · hold it | Open Centre · quick glance |
| `⌘ ↩` · `⌘ 1–9` · `⇧ ⌘ P` | Alternate action · run by position · pin to Home |
| `note …` · `tab …` · `clip` · `f …` | Note · browser tab · clipboard · files |
| `> cmd` · `pw 24` · `5 km to mi` · `timer 10m` | Shell · password · units · timer |
| `save session Study` · `Study` | Save and restore window layouts |

## Install

1. Download **Centre-x.y.z.dmg** from [Releases](https://github.com/Yyas99/Centre/releases/latest), open it and drag Centre into Applications.
2. The first time, macOS says it can't check Centre for malware, because it isn't notarised by Apple. Open **System Settings › Privacy & Security** and click **Open Anyway**.
3. Turn off Spotlight's `⌘ Space` shortcut (System Settings › Keyboard › Keyboard Shortcuts › Spotlight), or choose another one in Centre.

Centre checks for updates itself. **Settings › General › Updates** installs a new version in place, and only if it's signed by the same certificate, so your permissions carry over. To remove Centre, use **Settings › System › Uninstall**. Settings are kept in `~/Library/Application Support/Centre`.

No accounts or analytics. Centre goes online only to check GitHub for updates, fetch YouTube Music artwork, and look up your public IP when you run `info`. Clipboard history stays in memory.

## Build from source

You need macOS 13 or later and the Command Line Tools (`xcode-select --install`). Run `bash setup-signing.sh` once, then `./centre` to build and run. To make a release, bump `VERSION` and run `./centre release`, which writes the `.dmg` and the update `.zip` to `dist/`.

## Credits

Built by [Yyas99](https://github.com/Yyas99) with [Claude](https://claude.ai) (Anthropic).
<br><sub>Screenshots are rendered by the app: <code>./centre shots</code></sub>
