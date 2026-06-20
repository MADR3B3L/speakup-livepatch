# SpeakUp

Voice control for macOS that gets out of your way.

Say the fix. Keep typing.

---

## Why this exists

I built this because I needed it.

Typing with certain conditions means errors stack up faster than you can catch them. Switching to a mouse to fix them breaks flow. Dictation apps take over your screen and your workflow. None of that works when you're trying to actually get things done.

SpeakUp is what I wanted: a voice layer that fits *around* your work, not on top of it. Not a dictation app. Not an AI assistant. Something closer to a fast, invisible coworker sitting next to you — one that fixes the typo, fires the shortcut, and gets back out of the way.

---

## What it does

**Fix while you type**
Type normally. Say the correction. Keep typing.
SpeakUp hears what you said, finds the closest match in the focused field, and patches it in-place — cursor restored, no interruption.

**Control without leaving**
Say `paste`, `undo`, `clear`, `action next tab`, `media volume up` — shortcuts fire without touching the keyboard or losing focus.

**Prepare without interrupting**
Say `mac prepare Gmail`. It opens in the background. Nothing steals your focus.
Say `mac show me Gmail` when you're ready for it.

**Side-by-side without the drag**
Say `mac work with Chrome`. Your current app snaps left, Chrome snaps right.
Say `mac focus` to toggle between them. Say `mac put away Chrome` to return to your work.

---

## Requirements

- macOS 12+ (Monterey or later)
- Xcode Command Line Tools: `xcode-select --install`
- Accessibility permission — required for reading and writing text fields
- Microphone + Speech Recognition permission

---

## Build & Run

```bash
cd speakup-poc
./build.sh
open SpeakUp.app
```

First launch: click the 🎙 menu bar icon → **Check Permissions** → grant Accessibility and Microphone in System Settings.

> The app is ad-hoc signed (no Apple Developer cert). macOS resets Accessibility trust on every rebuild — after each `./build.sh`, open System Settings → Privacy & Security → Accessibility, remove SpeakUp and re-add it.

---

## Activation

- **Double-tap Right-⌘** — toggle listening on/off
- **Double-tap Right-⌘ then hold** — push-to-talk (commits on release)

---

## Command Reference

| Say | What happens |
|---|---|
| `paste` / `undo` / `redo` / `clear` | Fires instantly, no prefix needed |
| `action <command>` | Editing and app shortcuts (copy, close, next tab, bold…) |
| `action backspace` | Holds ⌫ at a steady pace — say *stop* or *ok* to release |
| `action delete word` | ⌥⌫ — deletes one word back |
| `action delete line` | ⌘⌫ — deletes to start of line |
| `media play` / `volume up` / `mute` | Media and volume keys |
| `display brightness down` / `display lock` | Screen controls |
| `mac prepare <app or site>` | Background open, no focus stolen |
| `mac show me <app or site>` | Bring to front |
| `mac work with <app>` | Split screen — current left, target right |
| `mac focus` | Toggle between split panes |
| `mac put away <app>` | Hide target, return to work |
| `mac search for <query>` | Search in background |
| `capture note <text>` / `capture reminder <text>` | Save to Notes or Reminders |

---

## Project Structure

```
speakup-poc/
├── Sources/SpeakUp/
│   ├── AppDelegate.swift            # Command dispatch, voice families, workspace control
│   ├── SpeechCapture.swift          # Microphone + SFSpeechRecognizer pipeline
│   ├── CandidateEngine.swift        # Similarity matching for typo correction
│   ├── AccessibilityInspector.swift # AX field read/write via AXUIElement
│   ├── MicrophonePermission.swift   # Permission helpers
│   └── main.swift                   # Entry point
├── Info.plist
├── build.sh
└── README.md
```

---

## Status

Working proof-of-concept. All core features run end-to-end on real voice input.
Not yet distributed — pending proper code signing and packaging.

This is the open core. A learning layer that adapts to your specific voice patterns and fixes your particular errors is in private development.

**Early access waitlist → [speakup.app](https://speakup.app)**

---

## License

MIT — see LICENSE

---

## Contributing

Issues and PRs welcome. If you use SpeakUp for accessibility or assistive technology purposes, I especially want to hear from you.

---

*Built by Marty Angel Diaz Jr · 2026*
