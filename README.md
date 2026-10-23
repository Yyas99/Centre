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

Needs macOS 13 or later and the Command Line Tools (`xcode-select --install`).

1. Run `bash setup-signing.sh` once. It creates a private signing certificate so macOS keeps Centre's permissions across updates.
2. Run `./centre install`. It builds, self-tests (66 checks), signs and installs Centre in `/Applications`.
3. Turn off Spotlight's `⌘ Space` (System Settings › Keyboard › Keyboard Shortcuts › Spotlight), or pick another shortcut in Centre's settings.

Run `./centre install` again to update. To remove Centre, use **Settings › System › Uninstall**: it restores your Dock and removes the login item. Settings live in `~/Library/Application Support/Centre`.

No accounts or analytics. Centre only goes online to fetch YouTube Music artwork and, when you run `info`, your public IP. Clipboard history stays in memory.

## Credits

Built by [Yyas99](https://github.com/Yyas99) with [Claude](https://claude.ai) (Anthropic).
<br><sub>Screenshots are rendered by the app: <code>./centre shots</code></sub>
