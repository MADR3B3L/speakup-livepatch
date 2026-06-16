# SpeakUp / LivePatch

A native macOS proof-of-concept that lets your voice participate in active text
entry — fixing typos, firing shortcuts, and arranging your workspace — without
interrupting what you're doing.

**Not a dictation app. Not an AI assistant.**  
It's a voice layer that acts like a fast, invisible coworker sitting next to you.

---

## What it does

### Fix While Working
Type normally. Say the correction. Keep typing.  
SpeakUp hears what you just said, finds the closest match in the focused field,
and patches it in-place — cursor restored, no interruption.

### Control Without Leaving
Say `paste`, `undo`, `clear`, `action next tab`, `media volume up`,
`display brightness down` — keyboard shortcuts fire without touching the keyboard
or switching focus.

### Prepare
Say `mac prepare Gmail` or `mac prepare Notes`.  
The app opens in the background. Nothing steals your focus.  
Say `mac show me Gmail` when you're ready for it.

### Parallel Work
Say `mac work with Chrome`.  
Your current app snaps left. Chrome snaps right.  
Say `mac focus` to toggle between them.  
Say `mac put away Chrome` to hide it and return to your work.

---

## Requirements

- macOS 12+ (Monterey or later)
- Xcode Command Line Tools (`xcode-select --install`)
- **Accessibility permission** — required for reading/writing text fields
- **Microphone + Speech Recognition permission** — required for voice input

---

## Build & Run

```bash
cd speakup-poc
./build.sh
open SpeakUp.app
```

On first launch, click the 🎙 menu bar icon → **Check Permissions** and grant
Accessibility + Microphone in System Settings.

> **Note:** The app is ad-hoc signed (no Apple Developer cert). macOS resets
> Accessibility trust on every rebuild — after each `./build.sh`, click
> the menu icon → **Check Permissions** → **Reinstall Hotkey Monitor**.

---

## Activation

- **Double-tap Right-⌘** — toggle Live Mode on/off  
- **Double-tap Right-⌘ then hold** — push-to-talk (listens while held, commits on release)

---

## Voice Command Reference

| Say | What happens |
|---|---|
| `paste` / `undo` / `redo` / `clear` / `cancel` | Fires instantly, no prefix |
| `action <command>` | Editing/app shortcuts (select all, copy, close, next tab…) |
| `media play` / `volume up` / `mute` / `brightness down` | System media/brightness keys |
| `display brightness down` / `display lock` / `display sleep` | Screen controls |
| `capture note <text>` / `capture reminder <text>` | Saves to Notes / Reminders |
| `mac prepare <target>` | Background launch, no focus stolen |
| `mac show me <target>` | Bring target to front |
| `mac work with <target>` | Split screen: current left, target right |
| `mac focus` | Toggle between split panes |
| `mac put away <target>` | Hide target, return to work |
| `mac remind me 9:35 to <task>` | Timed Reminders entry |
| `mac search for <query>` | Google search, opens in background |

---

## Project Structure

```
speakup-poc/
├── Sources/SpeakUp/
│   ├── AppDelegate.swift          # Command dispatch, voice families, workspace control
│   ├── SpeechCapture.swift        # Microphone capture + SFSpeechRecognizer pipeline
│   ├── CandidateEngine.swift      # Similarity matching for live typo correction
│   ├── AccessibilityInspector.swift  # AX field read/write via AXUIElement
│   ├── MicrophonePermission.swift # Permission helpers
│   └── main.swift                 # Entry point
├── Info.plist                     # App metadata + entitlements
├── build.sh                       # One-command build + ad-hoc sign
└── README.md
```

---

## Status

Active proof-of-concept. All 4 demo stories working end-to-end on real voice
input. Not yet distributed — pending proper code signing and packaging.

---

*SpeakUp / LivePatch — Marty Angel Diaz Jr — 2026*
