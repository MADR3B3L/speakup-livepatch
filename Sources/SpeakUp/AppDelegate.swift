import Cocoa
import CoreGraphics
import Speech

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var lastInspectionSummary: String = "No inspection run yet. Press ⌃⌥⌘I while focused in a text field."
    var globalMonitor: Any?
    var localMonitor: Any?
    var lastExternalApp: NSRunningApplication?

    // "Prepare" and "Parallel Work" families: what was last prepared in
    // the background, and which app currently occupies each half of the
    // screen after a "work with" command.
    var lastPreparedTarget: String?
    var leftPaneApp: NSRunningApplication?
    var rightPaneApp: NSRunningApplication?
    var flagsMonitor: Any?
    var localFlagsMonitor: Any?
    let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/speakup-poc-log.txt")
    var lastCommandHeard: String?
    private var userCommands: [String: CommandSpec] = [:]

    // Held-backspace state — active while "action backspace" is running.
    private var backspaceHoldTimer: Timer?

    // Capture window — active diagnostic recording session.
    private var captureWindowActive = false
    private var captureWindowTimer: Timer?
    private var captureWindowLog: [String] = []
    private var captureWindowStart: Date?
    private var lastCaptureFilePath: String?

    // Adaptive corrections — pattern tracker + user-approved fixes.
    private var mismatchTracker: [String: (intended: String, count: Int)] = [:]
    private var approvedCorrections: [String: String] = [:]

    // Product stack detection — which add-ons are installed.
    private var installedProducts: Set<String> = ["speakup"] // always present

    private func detectInstalledProducts() {
        let speakupDir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp")
        if FileManager.default.fileExists(atPath: speakupDir.appendingPathComponent("alpha-config.json").path) {
            installedProducts.insert("livepatch")
        }
        if FileManager.default.fileExists(atPath: speakupDir.appendingPathComponent("veq-license.json").path) {
            installedProducts.insert("veq")
        }
        if FileManager.default.fileExists(atPath: speakupDir.appendingPathComponent("buffer-license.json").path) {
            installedProducts.insert("buffer")
        }
        appendLog("[Stack] Installed: \(installedProducts.sorted().joined(separator: ", "))")
    }

    private func requireProduct(_ product: String, feature: String) -> Bool {
        if installedProducts.contains(product) { return true }
        let productNames: [String: (name: String, desc: String)] = [
            "livepatch": ("LivePatch", "Reports, auto-learning, custom commands, adaptive corrections"),
            "veq": ("Veq", "Flows, AI context, memory, advanced tool calls"),
            "buffer": ("Buffer Infrastructure", "Cross-machine communication, multi-AI, worker lanes"),
        ]
        let info = productNames[product] ?? (product, "Advanced features")
        appendLog("[Stack] \(feature) requires \(info.name) — not installed")
        notify("\(info.name) required", "\(feature) is a \(info.name) feature. \(info.desc). Visit madr3b3l.github.io/speakup-livepatch")
        speak("\(info.name) feature")
        return false
    }

    // Session quality & chronology — time-aware behavior.
    private var sessionStartTime = Date()
    private var cpuSamples: [Double] = []
    private var cpuSampleTimer: Timer?
    private var correctionTimestamps: [Date] = []

    private var sessionQuality: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let lateNight = hour >= 0 && hour < 6
        let recentCorrections = correctionTimestamps.filter { Date().timeIntervalSince($0) < 300 }
        let highErrorRate = recentCorrections.count > 15 // >15 corrections in 5 min = struggling
        let sessionMinutes = Date().timeIntervalSince(sessionStartTime) / 60
        let longSession = sessionMinutes > 120 // over 2 hours

        if lateNight && highErrorRate { return "degraded" }
        if lateNight { return "low" }
        if highErrorRate && longSession { return "fatigued" }
        if highErrorRate { return "struggling" }
        if longSession { return "extended" }
        return "normal"
    }

    // Product intelligence — anonymous usage signals, no personal data.
    private var sessionStats: [String: Int] = [
        "commands_fired": 0,
        "commands_fuzzy_matched": 0,
        "commands_failed": 0,
        "corrections_made": 0,
        "corrections_low_confidence": 0,
        "volume_gate_rejections": 0,
        "captures_started": 0,
        "adaptive_prompts_shown": 0,
        "adaptive_approved": 0,
        "adaptive_rejected": 0,
    ]
    private let statsURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/usage-stats.json")
    private var appCommandCounts: [String: [String: Int]] = [:]  // app -> command -> count
    private let approvedCorrectionsURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/adaptive-corrections.json")
    private var pendingAdaptivePrompt: (heard: String, intended: String)? = nil

    // Milestone 2A: speech capture (log-only for now, no AX writes).
    let speechCapture = SpeechCapture()
    var isListening = false
    var speechMenuItem: NSMenuItem!

    // Virtual keycode for the "I" key on US layout.
    private let kVK_ANSI_I: UInt16 = 34
    // Virtual keycode for the "W" key on US layout (write-test hotkey).
    private let kVK_ANSI_W: UInt16 = 13
    // Virtual keycode for the RIGHT Command key.
    private let kVK_RightCommand: UInt16 = 54
    // Max gap between taps to count as a "double tap" (seconds).
    private let doubleTapWindow: TimeInterval = 0.4

    private var rightCommandIsDown = false
    private var lastRightCommandDownAt: TimeInterval = 0

    // Milestone 2B: double-tap-and-HOLD Right-⌘ as push-to-talk.
    // After the 2nd tap-down, if the key is still held past
    // `holdThreshold`, that's "hold" -> start listening. If released
    // before that, it's a quick double-tap -> inspect (legacy behavior).
    private var holdWorkItem: DispatchWorkItem?
    private var holdArmed = false
    private let holdThreshold: TimeInterval = 0.35

    // Milestone 3: "Live Patch" mode — a scoped port of the LivePatch Chrome
    // extension's core loop (see CandidateEngine.swift). While on, SpeakUp
    // continuously listens; when a short phrase settles, it's compared
    // (via similarity) against the word at/before the text cursor, and
    // patched in if it's a close-enough "smart suggestion".
    private var liveModeOn = false
    private var liveMenuItem: NSMenuItem!
    private var phraseSettleWorkItem: DispatchWorkItem?
    // Extension: AUTO_SETTLE_MS — let the user finish speaking before acting
    // on the transcript.
    private let phraseSettleDelay: TimeInterval = 1.4

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app menu, doesn't steal focus.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = "🎙"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "SpeakUp PoC — Milestone 1", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withAction: "Check Permissions", selector: #selector(checkPermissions), target: self)
        menu.addItem(withAction: "Inspect Focused Element Now", selector: #selector(inspectNow), target: self)
        menu.addItem(withAction: "Show Last Inspection", selector: #selector(showLastInspection), target: self)
        menu.addItem(withAction: "Write Test Text [SpeakUp]", selector: #selector(writeTestText), target: self)
        menu.addItem(withAction: "Reinstall Hotkey Monitor", selector: #selector(reinstallHotkeyMonitor), target: self)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withAction: "Start Listening (Right-⌘⌘ hold)", selector: #selector(toggleSpeechTest), target: self)
        speechMenuItem = menu.item(at: menu.numberOfItems - 1)
        menu.addItem(withAction: "Live Patch: OFF (quick double-tap = on)", selector: #selector(toggleLiveMode), target: self)
        liveMenuItem = menu.item(at: menu.numberOfItems - 1)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Hotkeys: tap-tap-HOLD Right-⌘ = talk (release=commit), quick double-tap = toggle Live Patch, ⌃⌥⌘I = inspect, ⌃⌥⌘W = write test", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withAction: "Quit", selector: #selector(NSApplication.terminate(_:)), target: self, key: "q")

        statusItem.menu = menu

        // Track the last app that was active BEFORE SpeakUp's own menu
        // steals activation, so "Inspect Focused Element Now" inspects
        // the right target instead of inspecting SpeakUp itself.
        lastExternalApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        })
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        appendLog("=== SpeakUp PoC launched ===")
        logPermissionStatus()
        detectInstalledProducts()
        loadAdaptiveCorrections()
        loadAppProfiles()
        startCPUSampling()
        installGlobalHotkeyMonitor()
        installDoubleTapMonitor()
    }

    @objc func activeAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = app
            appendLog("Active app changed -> \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
            trackAppEnvironment()
        }
    }

    // MARK: - Permissions

    @objc func checkPermissions() {
        let axTrusted = AccessibilityInspector.isTrusted(promptIfNeeded: true)
        let micStatus = MicrophonePermission.status()

        if micStatus == .notDetermined {
            MicrophonePermission.request { [weak self] granted in
                self?.showPermissionAlert(axTrusted: axTrusted, micGranted: granted)
            }
        } else {
            showPermissionAlert(axTrusted: axTrusted, micGranted: micStatus == .authorized)
        }
    }

    private func showPermissionAlert(axTrusted: Bool, micGranted: Bool) {
        let alert = NSAlert()
        alert.messageText = "SpeakUp Permission Status"
        alert.informativeText = """
        Accessibility: \(axTrusted ? "Granted ✅" : "NOT granted ❌\n(System Settings → Privacy & Security → Accessibility)")

        Microphone: \(micGranted ? "Granted ✅" : "NOT granted ❌\n(System Settings → Privacy & Security → Microphone)")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func logPermissionStatus() {
        let axTrusted = AccessibilityInspector.isTrusted(promptIfNeeded: false)
        appendLog("Accessibility trusted: \(axTrusted)")
        appendLog("Microphone status: \(MicrophonePermission.statusDescription())")
    }




    // MARK: - Inspection

    /// Global hotkey ⌃⌥⌘I — fires while focus stays in whatever app/field
    /// the user is currently in. Uses a 4-key combo to avoid colliding with
    /// app-specific shortcuts (e.g. Notes uses plain ⌘⇧I for something).
    private func installGlobalHotkeyMonitor() {
        if let existing = globalMonitor {
            NSEvent.removeMonitor(existing)
            globalMonitor = nil
        }
        if let existing = localMonitor {
            NSEvent.removeMonitor(existing)
            localMonitor = nil
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            let mods: NSEvent.ModifierFlags = [.control, .option, .command]
            guard event.modifierFlags.contains(mods) else { return }
            if event.keyCode == self.kVK_ANSI_I {
                self.appendLog("Hotkey ⌃⌥⌘I detected.")
                self.performInspection()
            } else if event.keyCode == self.kVK_ANSI_W {
                self.appendLog("Hotkey ⌃⌥⌘W detected.")
                self.writeTestText()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        // Local monitor catches the hotkey when SpeakUp's own alert/menu is key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }

        let trusted = AccessibilityInspector.isTrusted(promptIfNeeded: false)
        appendLog("Hotkey monitor (re)installed. Accessibility trusted: \(trusted). global=\(globalMonitor != nil) local=\(localMonitor != nil)")
    }

    /// Double-tap RIGHT Command (⌘) — primary trigger. A single physical
    /// key, pressed twice quickly, with no other key in between. Doesn't
    /// collide with any standard shortcut (those all use Command+something).
    private func installDoubleTapMonitor() {
        if let existing = flagsMonitor {
            NSEvent.removeMonitor(existing)
            flagsMonitor = nil
        }
        if let existing = localFlagsMonitor {
            NSEvent.removeMonitor(existing)
            localFlagsMonitor = nil
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            guard event.keyCode == self.kVK_RightCommand else { return }

            let isDown = event.modifierFlags.contains(.command)
            if isDown == self.rightCommandIsDown { return } // de-dupe repeats
            self.rightCommandIsDown = isDown

            if isDown {
                let now = ProcessInfo.processInfo.systemUptime
                let gap = now - self.lastRightCommandDownAt
                if gap > 0 && gap < self.doubleTapWindow {
                    self.appendLog("Double-tap Right-⌘ press #2 detected (gap \(String(format: "%.3f", gap))s). Arming hold-to-talk timer...")
                    self.lastRightCommandDownAt = 0

                    // If still held after holdThreshold, this is "tap-tap-HOLD"
                    // -> start listening. If released before then, it's a
                    // quick double-tap -> inspect (handled on release below).
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self, self.rightCommandIsDown else { return }
                        self.holdArmed = true
                        self.appendLog("Right-⌘ hold threshold reached -> start listening (push-to-talk).")
                        self.requestSpeechAuthorizationAndStart()
                    }
                    self.holdWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.holdThreshold, execute: workItem)
                } else {
                    self.lastRightCommandDownAt = now
                }
            } else {
                // Key released.
                self.holdWorkItem?.cancel()
                if self.holdArmed {
                    self.holdArmed = false
                    self.appendLog("Right-⌘ released -> stop listening + commit.")
                    if self.isListening {
                        self.stopListeningAndCommit()
                    }
                } else if self.holdWorkItem != nil {
                    self.appendLog("Quick double-tap Right-⌘ (released before hold threshold) -> toggle Live Patch.")
                    self.toggleLiveMode()
                }
                self.holdWorkItem = nil
            }
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }

        appendLog("Double-tap monitor installed. global=\(flagsMonitor != nil) local=\(localFlagsMonitor != nil)")
    }

    @objc func reinstallHotkeyMonitor() {
        installGlobalHotkeyMonitor()
        installDoubleTapMonitor()
        let alert = NSAlert()
        alert.messageText = "Hotkey Monitors Reinstalled"
        alert.informativeText = "Check ~/speakup-poc-log.txt for status. Try double-tapping the RIGHT ⌘ key, or ⌃⌥⌘I."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func inspectNow() {
        appendLog(">>> inspectNow() menu action fired")
        performInspection()
    }

    private func performInspection() {
        appendLog(">>> performInspection() start")
        if let app = lastExternalApp {
            appendLog(">>> target app for inspection: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
        } else {
            appendLog(">>> target app for inspection: NONE (falling back to frontmost)")
        }
        let result = AccessibilityInspector.inspectFocusedElement(targetApp: lastExternalApp)
        switch result {
        case .success(let info):
            lastInspectionSummary = info.summary
            appendLog("--- Inspection ---\n\(info.summary)")
        case .failure(let message):
            lastInspectionSummary = "Inspection failed: \(message)"
            appendLog("--- Inspection FAILED: \(message) ---")
        }

        // Exploratory (Milestone 3): is the system's own spelling/grammar
        // flagging (the red/dotted underlines) visible via AX? If so, Live
        // Patch could target those words directly instead of guessing via
        // similarity across the whole document.
        switch AccessibilityInspector.describeSpellingAttributes(targetApp: lastExternalApp) {
        case .success(let desc):
            appendLog("--- Spelling/Grammar attributes ---\n\(desc)")
        case .failure(let msg):
            appendLog("--- Spelling/Grammar attributes FAILED: \(msg) ---")
        }
    }

    @objc func writeTestText() {
        appendLog(">>> writeTestText() menu action fired")
        if let app = lastExternalApp {
            appendLog(">>> target app for write: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
        }
        let result = AccessibilityInspector.insertTextAtCursor(" [SpeakUp] ", targetApp: lastExternalApp)
        switch result {
        case .success(let detail):
            appendLog("--- Write SUCCESS: \(detail) ---")
        case .failure(let message):
            appendLog("--- Write FAILED: \(message) ---")
        }
    }

    // MARK: - Speech (Milestone 2A — log only, no AX writes yet)

    /// Menu-click entry point — same start/stop logic as the Right-⌘
    /// tap-tap-hold gesture, so either trigger can be used interchangeably.
    @objc func toggleSpeechTest() {
        if isListening {
            stopListeningAndCommit()
        } else {
            requestSpeechAuthorizationAndStart()
        }
    }

    /// Checks Speech Recognition authorization and, once granted, starts
    /// listening. Shared by the menu item and the Right-⌘ hold gesture.
    private func requestSpeechAuthorizationAndStart() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            startListening()
        case .notDetermined:
            appendLog("[Speech] Requesting Speech Recognition authorization...")
            SpeechCapture.requestAuthorization { [weak self] granted in
                guard let self = self else { return }
                self.appendLog("[Speech] Authorization granted: \(granted)")
                if granted {
                    self.startListening()
                } else {
                    self.appendLog("[Speech] Cannot start: Speech Recognition not authorized.")
                }
            }
        default:
            appendLog("[Speech] Cannot start: Speech Recognition status = \(SpeechCapture.authorizationStatusDescription()). Enable in System Settings > Privacy & Security > Speech Recognition.")
        }
    }

    private func startListening() {
        // Push-to-talk takes priority over Live Patch: pause the live
        // listen loop (if any) so the two don't fight over the mic / the
        // shared SpeechCapture instance. Resumed on release in
        // stopListeningAndCommit().
        if liveModeOn {
            stopLiveListenSession()
        }

        speechCapture.onResult = { [weak self] text, isFinal in
            self?.appendLog("[Speech] \(isFinal ? "FINAL" : "partial"): \(text)")
        }
        speechCapture.onError = { [weak self] message in
            self?.appendLog("[Speech] error/end: \(message)")
            DispatchQueue.main.async {
                self?.isListening = false
                self?.speechMenuItem?.title = "Start Listening (Right-⌘⌘ hold)"
                self?.updateStatusIcon()
            }
        }
        do {
            try speechCapture.start()
            isListening = true
            speechMenuItem.title = "Stop Listening (Right-⌘⌘ hold)"
            updateStatusIcon()
            appendLog("[Speech] Started listening. Mic status: \(MicrophonePermission.statusDescription())")
        } catch {
            appendLog("[Speech] Failed to start: \(error.localizedDescription)")
        }
    }

    /// Stops listening and commits the last partial transcript through the
    /// proven insert/replace AX write path. Shared by the menu item and the
    /// Right-⌘ hold-release gesture.
    private func stopListeningAndCommit() {
        // Capture the last partial BEFORE stop() — stop()/cancel() does
        // not reliably deliver an isFinal result, so "last partial at
        // release time" IS the commit value. Per the A/B write tests,
        // this goes through the same insert/replace path.
        let transcript = speechCapture.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        speechCapture.stop()
        isListening = false
        speechMenuItem.title = "Start Listening (Right-⌘⌘ hold)"
        updateStatusIcon()
        appendLog("[Speech] Stopped listening.")

        guard !transcript.isEmpty else {
            appendLog("[SpeechCommit] (empty transcript, nothing to insert)")
            resumeLiveModeIfNeeded()
            return
        }

        appendLog("[SpeechCommit] \"\(transcript)\"")
        if let app = lastExternalApp {
            appendLog("[SpeechCommit] target app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
        }
        let result = AccessibilityInspector.insertTextAtCursor(transcript, targetApp: lastExternalApp)
        switch result {
        case .success(let detail):
            appendLog("[SpeechCommit] WRITE SUCCESS: \(detail)")
        case .failure(let message):
            appendLog("[SpeechCommit] WRITE FAILED: \(message)")
        }
        resumeLiveModeIfNeeded()
    }

    private func resumeLiveModeIfNeeded() {
        guard liveModeOn else { return }
        startLiveListenSessionIfNeeded()
    }

    private func updateStatusIcon() {
        let axTrusted = AXIsProcessTrusted()
        if !axTrusted {
            statusItem.button?.title = "⚠️"
        } else if isListening {
            statusItem.button?.title = "🔴"
        } else if liveModeOn {
            statusItem.button?.title = "🟢"
        } else {
            statusItem.button?.title = "🎙"
        }
    }

    // MARK: - Live Patch (Milestone 3)

    /// Quick double-tap Right-⌘ (no hold), or the menu item — toggles
    /// continuous "Live Patch" mode on/off.
    @objc func toggleLiveMode() {
        liveModeOn.toggle()
        if liveModeOn {
            appendLog("[LiveMode] ON — watching focused field for close-match corrections.")
            liveMenuItem.title = "Live Patch: ON (quick double-tap = off)"
            updateStatusIcon()
            startLiveListenSessionIfNeeded()
        } else {
            appendLog("[LiveMode] OFF.")
            liveMenuItem.title = "Live Patch: OFF (quick double-tap = on)"
            stopLiveListenSession()
            updateStatusIcon()
        }
    }

    /// Begins (or re-begins) a live listen session, handling Speech
    /// Recognition authorization the same way push-to-talk does.
    private func startLiveListenSessionIfNeeded() {
        guard liveModeOn, !isListening, !speechCapture.isRunning else { return }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            beginLiveListenSession()
        case .notDetermined:
            appendLog("[LiveMode] Requesting Speech Recognition authorization...")
            SpeechCapture.requestAuthorization { [weak self] granted in
                guard let self = self else { return }
                self.appendLog("[LiveMode] Authorization granted: \(granted)")
                if granted && self.liveModeOn {
                    self.beginLiveListenSession()
                } else if !granted {
                    self.turnLiveModeOffDueToError("Speech Recognition not authorized.")
                }
            }
        default:
            turnLiveModeOffDueToError("Speech Recognition status = \(SpeechCapture.authorizationStatusDescription()). Enable in System Settings > Privacy & Security > Speech Recognition.")
        }
    }

    private func turnLiveModeOffDueToError(_ reason: String) {
        appendLog("[LiveMode] Turning off: \(reason)")
        liveModeOn = false
        liveMenuItem.title = "Live Patch: OFF (quick double-tap = on)"
        updateStatusIcon()
    }

    private func beginLiveListenSession() {
        speechCapture.onResult = { [weak self] text, isFinal in
            self?.appendLog("[LiveMode] partial: \(text)")
            self?.scheduleLivePhraseSettle()
        }
        speechCapture.onError = { [weak self] message in
            // Genuinely unexpected error (error 216 end-of-task noise is
            // already filtered out by SpeechCapture). If we're still
            // supposed to be live, restart.
            self?.appendLog("[LiveMode] error/end: \(message)")
            DispatchQueue.main.async {
                guard let self = self, self.liveModeOn, !self.isListening else { return }
                self.beginLiveListenSession()
            }
        }
        do {
            try speechCapture.start()
            appendLog("[LiveMode] Listening for corrections...")
        } catch {
            turnLiveModeOffDueToError("Failed to start: \(error.localizedDescription)")
        }
    }

    /// Stops the live listen session (used when toggling off, or pausing
    /// for push-to-talk). Does not flip `liveModeOn`.
    private func stopLiveListenSession() {
        phraseSettleWorkItem?.cancel()
        phraseSettleWorkItem = nil
        if speechCapture.isRunning {
            speechCapture.stop()
        }
    }

    /// Debounced "the user stopped talking" detector: each new partial
    /// resets this timer (Extension: AUTO_SETTLE_MS). When it fires, the
    /// current transcript is treated as a finished phrase.
    /// Report commands get an extra second so the description after "report
    /// issue" / "mac report bug" has time to arrive before we cut off.
    private func scheduleLivePhraseSettle() {
        phraseSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishLivePhrase()
        }
        phraseSettleWorkItem = workItem
        let partial = speechCapture.lastTranscript.lowercased()
        let isLongDictationCommand = partial.hasPrefix("report ") || partial.hasPrefix("mac report")
            || partial.hasPrefix("capture bug") || partial.hasPrefix("capture issue")
            || partial.hasPrefix("capture feedback")
        let isShortKnownCommand = Self.commands[partial] != nil
            || partial == "paste" || partial == "undo" || partial == "redo" || partial == "clear"
            || partial == "select all" || partial == "select" || partial == "copy"
            || partial.hasPrefix("action ") && Self.commands[String(partial.dropFirst("action ".count))] != nil
        let delay = isLongDictationCommand ? phraseSettleDelay + 1.0
            : isShortKnownCommand ? 0.7
            : phraseSettleDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishLivePhrase() {
        guard liveModeOn, !isListening else { return }
        phraseSettleWorkItem = nil
        let phrase = speechCapture.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        speechCapture.stop()

        if !phrase.isEmpty {
            processLiveHeardPhrase(phrase)
        }

        // Start a fresh session for the next phrase.
        if liveModeOn {
            beginLiveListenSession()
        }
    }

    // MARK: - Voice commands (Milestone 4 start)

    /// Trigger word that must precede a command phrase ("action paste",
    /// "action copy", etc.). Without this, a bare "paste" is ambiguous with
    /// Live Patch: the user might be SAYING the word "paste" to correct some
    /// nearby typo into "paste" ("pasta" -> "paste"), or — per the user's
    /// report — Claude's text field can swallow a bare "paste" as dictated
    /// text instead of triggering the command. Requiring "action <word>"
    /// gives the command layer an unambiguous wake phrase, separate from
    /// anything that could plausibly be a correction target. This is the
    /// shared prefix for the whole command set we're building out (paste,
    /// copy, field/site commands, etc.) — not paste-specific.
    private static let commandTriggerWord = "action"

    /// Virtual keycodes for a US/ANSI keyboard layout, for the keys our
    /// command set uses. (Letters are laid out by physical position, not by
    /// the letter printed on the key, which is why these don't look
    /// alphabetical.)
    private enum KeyCode {
        static let a: CGKeyCode = 0x00
        static let b: CGKeyCode = 0x0B
        static let c: CGKeyCode = 0x08
        static let f: CGKeyCode = 0x03
        static let i: CGKeyCode = 0x22
        static let l: CGKeyCode = 0x25
        static let m: CGKeyCode = 0x2E
        static let n: CGKeyCode = 0x2D
        static let p: CGKeyCode = 0x23
        static let q: CGKeyCode = 0x0C
        static let r: CGKeyCode = 0x0F
        static let s: CGKeyCode = 0x01
        static let t: CGKeyCode = 0x11
        static let u: CGKeyCode = 0x20
        static let v: CGKeyCode = 0x09
        static let w: CGKeyCode = 0x0D
        static let x: CGKeyCode = 0x07
        static let z: CGKeyCode = 0x06
        static let space: CGKeyCode = 0x31
        static let `return`: CGKeyCode = 0x24
        static let escape: CGKeyCode = 0x35
        static let tab: CGKeyCode = 0x30
        static let delete: CGKeyCode = 0x33
        static let leftBracket: CGKeyCode = 0x21
        static let rightBracket: CGKeyCode = 0x1E
        static let equals: CGKeyCode = 0x18
        static let minus: CGKeyCode = 0x1B
        static let leftArrow: CGKeyCode = 0x7B
        static let rightArrow: CGKeyCode = 0x7C
        static let upArrow: CGKeyCode = 0x7E
        static let downArrow: CGKeyCode = 0x7D
        static let four: CGKeyCode = 0x15
        static let three: CGKeyCode = 0x14
        static let zero: CGKeyCode = 0x1D
        static let d: CGKeyCode = 0x02
        static let h: CGKeyCode = 0x04
        static let o: CGKeyCode = 0x1F
        static let slash: CGKeyCode = 0x2C
        static let forwardDelete: CGKeyCode = 0x75
        static let pageUp: CGKeyCode = 0x74
        static let pageDown: CGKeyCode = 0x79
        static let home: CGKeyCode = 0x73
        static let end: CGKeyCode = 0x77
    }


    /// NX_KEYTYPE_* constants for the "media key" system-defined events
    /// (play/pause, next/previous track, volume, brightness, mute). These
    /// aren't regular keyboard keys — no physical key on most Macs sends
    /// them as plain keystrokes — so they need a different CGEvent
    /// construction (see `simulateMediaKey`) than `KeyCode`/
    /// `simulateKeyCombo`.
    private enum MediaKey {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
        static let brightnessUp: Int32 = 2
        static let brightnessDown: Int32 = 3
        static let mute: Int32 = 7
        static let play: Int32 = 16
        static let next: Int32 = 17
        static let previous: Int32 = 18
    }

    /// One command's spec: exactly one of `keyCode`, `mediaKey`, `shell`, or
    /// `sequence` should be set, plus what to log. Four execution paths
    /// share this table because they're all "things triggered by a command
    /// word":
    ///  - `keyCode`/`flags`: a regular keystroke via CGEvent (simulateKeyCombo)
    ///  - `mediaKey`: a media-key system event via CGEvent (simulateMediaKey)
    ///  - `shell`: an AppleScript run via osascript (runShellCommand) — for
    ///    things with no keyboard shortcut at all, like toggling dark mode.
    ///  - `sequence`: multiple keystrokes in order (simulateKeySequence) —
    ///    for things that are really "press this, then that", like "clear"
    ///    (select all, then delete).
    private struct CommandSpec {
        var keyCode: CGKeyCode? = nil
        var flags: CGEventFlags = []
        var mediaKey: Int32? = nil
        var shell: String? = nil
        var sequence: [(keyCode: CGKeyCode, flags: CGEventFlags)]? = nil
        let label: String
    }

    /// The command vocabulary. Each entry is a phrase that can follow
    /// "action " (e.g. "action paste", "action copy"); several phrases can
    /// map to the same underlying key combo for natural variation. All of
    /// these are synthetic keyboard events via CGEvent, so — like paste —
    /// they bypass AX entirely and work in ANY focused app, including
    /// Chrome and Claude where SpeakUp's AX read/write paths are blocked.
    ///
    /// This is the start of "uniting the flows": Live Patch (AX-based,
    /// app-dependent) handles in-place text corrections; this command table
    /// (CGEvent-based, universal) handles everything else — clipboard,
    /// editing shortcuts, app/window navigation, and system-level actions
    /// like Spotlight. Both are reached through the same "action <word>" /
    /// bare-phrase dispatch in `processLiveHeardPhrase`, so adding a new
    /// capability to either system is just one more case here or one more
    /// candidate in CandidateEngine — the user doesn't need to learn two
    /// different ways of talking to the computer.
    /// Common website shortcuts for "open <site>" — opened in the default
    /// browser via NSWorkspace, same as clicking a bookmark. Lowercased
    /// keys; matched against the lowercased target after "open "/"go to ".
    private static let websiteAliases: [String: String] = [
        "google": "https://www.google.com",
        "gmail": "https://mail.google.com",
        "email": "https://mail.google.com",
        "youtube": "https://www.youtube.com",
        "maps": "https://maps.google.com",
        "google maps": "https://maps.google.com",
        "amazon": "https://www.amazon.com",
        "github": "https://github.com",
        "wikipedia": "https://www.wikipedia.org",
        "twitter": "https://twitter.com",
        "x": "https://x.com",
        "reddit": "https://www.reddit.com",
        "chatgpt": "https://chat.openai.com",
        "claude": "https://claude.ai",
        "claude ai": "https://claude.ai",
        "news": "https://news.google.com",
        "weather": "https://weather.com",
        "calendar": "https://calendar.google.com",
        "drive": "https://drive.google.com",
        "google drive": "https://drive.google.com",
        "docs": "https://docs.google.com",
        "google docs": "https://docs.google.com",
        "translate": "https://translate.google.com",
    ]

    /// Spoken names that don't match their actual macOS app name closely
    /// enough for the title-cased fallback in `openTarget` to find them.
    private static let appAliases: [String: String] = [
        "settings": "System Settings",
        "system preferences": "System Settings",
        "preferences": "System Settings",
        "app store": "App Store",
        "activity monitor": "Activity Monitor",
        "text edit": "TextEdit",
        "facetime": "FaceTime",
        "face time": "FaceTime",
        "terminal": "Terminal",
        "finder": "Finder",
        // The actual app name is "Google Chrome" — the title-cased
        // fallback would try to launch "Chrome", which Launch Services
        // doesn't reliably resolve.
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        // The Zoom app's real name is "zoom.us", not "Zoom".
        "zoom": "zoom.us",
    ]

    private static let commands: [String: CommandSpec] = [
        "paste": CommandSpec(keyCode: KeyCode.v, flags: .maskCommand, label: "⌘V (paste)"),
        "paste that": CommandSpec(keyCode: KeyCode.v, flags: .maskCommand, label: "⌘V (paste)"),
        "paste it": CommandSpec(keyCode: KeyCode.v, flags: .maskCommand, label: "⌘V (paste)"),
        "paste this": CommandSpec(keyCode: KeyCode.v, flags: .maskCommand, label: "⌘V (paste)"),

        "copy": CommandSpec(keyCode: KeyCode.c, flags: .maskCommand, label: "⌘C (copy)"),
        "copy that": CommandSpec(keyCode: KeyCode.c, flags: .maskCommand, label: "⌘C (copy)"),

        "cut": CommandSpec(keyCode: KeyCode.x, flags: .maskCommand, label: "⌘X (cut)"),
        "cut that": CommandSpec(keyCode: KeyCode.x, flags: .maskCommand, label: "⌘X (cut)"),

        "select all": CommandSpec(keyCode: KeyCode.a, flags: .maskCommand, label: "⌘A (select all)"),
        // STT sometimes drops "all" and hears just "select" — catch both.
        "select": CommandSpec(keyCode: KeyCode.a, flags: .maskCommand, label: "⌘A (select all)"),
        "grab all": CommandSpec(keyCode: KeyCode.a, flags: .maskCommand, label: "⌘A (select all)"),
        "highlight all": CommandSpec(keyCode: KeyCode.a, flags: .maskCommand, label: "⌘A (select all)"),

        // Right arrow collapses any active text selection without moving
        // the cursor outside the field — the standard keyboard "deselect".
        "deselect": CommandSpec(keyCode: KeyCode.rightArrow, flags: [], label: "→ (deselect)"),
        "deselect all": CommandSpec(keyCode: KeyCode.rightArrow, flags: [], label: "→ (deselect)"),
        "clear selection": CommandSpec(keyCode: KeyCode.rightArrow, flags: [], label: "→ (deselect)"),

        "undo": CommandSpec(keyCode: KeyCode.z, flags: .maskCommand, label: "⌘Z (undo)"),
        "undo that": CommandSpec(keyCode: KeyCode.z, flags: .maskCommand, label: "⌘Z (undo)"),

        "redo": CommandSpec(keyCode: KeyCode.z, flags: [.maskCommand, .maskShift], label: "⇧⌘Z (redo)"),

        "find": CommandSpec(keyCode: KeyCode.f, flags: .maskCommand, label: "⌘F (find)"),
        "search": CommandSpec(keyCode: KeyCode.f, flags: .maskCommand, label: "⌘F (find)"),

        // Browser-flavored, but harmless elsewhere (just won't do anything
        // useful in an app without an address bar / tabs).
        "address bar": CommandSpec(keyCode: KeyCode.l, flags: .maskCommand, label: "⌘L (focus address bar)"),
        "new tab": CommandSpec(keyCode: KeyCode.t, flags: .maskCommand, label: "⌘T (new tab)"),

        // System-level: Cmd+Space is the default Spotlight shortcut. Posted
        // at the HID level, this reaches Spotlight regardless of which app
        // is focused — same as a physical keypress.
        "spotlight": CommandSpec(keyCode: KeyCode.space, flags: .maskCommand, label: "⌘Space (Spotlight)"),
        "search spotlight": CommandSpec(keyCode: KeyCode.space, flags: .maskCommand, label: "⌘Space (Spotlight)"),

        "enter": CommandSpec(keyCode: KeyCode.return, flags: [], label: "Return"),
        "return": CommandSpec(keyCode: KeyCode.return, flags: [], label: "Return"),
        "send": CommandSpec(keyCode: KeyCode.return, flags: .maskCommand, label: "⌘↩ (send/submit)"),
        "submit": CommandSpec(keyCode: KeyCode.return, flags: .maskCommand, label: "⌘↩ (submit)"),
        "escape": CommandSpec(keyCode: KeyCode.escape, flags: [], label: "Escape"),
        "cancel": CommandSpec(keyCode: KeyCode.escape, flags: [], label: "Escape"),
        "tab": CommandSpec(keyCode: KeyCode.tab, flags: [], label: "Tab"),

        // --- Window / tab / app management ---
        // "quit" included deliberately even though it's the riskiest entry
        // here: it's the same ⌘Q you'd press yourself, gated behind the
        // same "action" trigger (or command-mode window) as everything
        // else. If misrecognition here is a problem in practice, this is
        // the first one to remove or require a stronger confirmation for.
        "close": CommandSpec(keyCode: KeyCode.w, flags: .maskCommand, label: "⌘W (close window/tab)"),
        "close window": CommandSpec(keyCode: KeyCode.w, flags: .maskCommand, label: "⌘W (close window/tab)"),
        "close tab": CommandSpec(keyCode: KeyCode.w, flags: .maskCommand, label: "⌘W (close window/tab)"),
        "minimize": CommandSpec(keyCode: KeyCode.m, flags: .maskCommand, label: "⌘M (minimize)"),
        "full screen": CommandSpec(keyCode: KeyCode.f, flags: [.maskCommand, .maskControl], label: "⌃⌘F (toggle full screen)"),
        "quit": CommandSpec(keyCode: KeyCode.q, flags: .maskCommand, label: "⌘Q (quit app)"),

        // --- Browser / document navigation ---
        "back": CommandSpec(keyCode: KeyCode.leftBracket, flags: .maskCommand, label: "⌘[ (back)"),
        "forward": CommandSpec(keyCode: KeyCode.rightBracket, flags: .maskCommand, label: "⌘] (forward)"),
        "reload": CommandSpec(keyCode: KeyCode.r, flags: .maskCommand, label: "⌘R (reload)"),
        "refresh": CommandSpec(keyCode: KeyCode.r, flags: .maskCommand, label: "⌘R (reload)"),
        "next tab": CommandSpec(keyCode: KeyCode.rightBracket, flags: [.maskCommand, .maskShift], label: "⇧⌘] (next tab)"),
        "previous tab": CommandSpec(keyCode: KeyCode.leftBracket, flags: [.maskCommand, .maskShift], label: "⇧⌘[ (previous tab)"),
        "reopen tab": CommandSpec(keyCode: KeyCode.t, flags: [.maskCommand, .maskShift], label: "⇧⌘T (reopen closed tab)"),

        // --- File / document actions ---
        "save": CommandSpec(keyCode: KeyCode.s, flags: .maskCommand, label: "⌘S (save)"),
        "print": CommandSpec(keyCode: KeyCode.p, flags: .maskCommand, label: "⌘P (print)"),
        "new": CommandSpec(keyCode: KeyCode.n, flags: .maskCommand, label: "⌘N (new)"),

        // --- Text formatting (rich text editors / browsers) ---
        "bold": CommandSpec(keyCode: KeyCode.b, flags: .maskCommand, label: "⌘B (bold)"),
        "italic": CommandSpec(keyCode: KeyCode.i, flags: .maskCommand, label: "⌘I (italic)"),
        "underline": CommandSpec(keyCode: KeyCode.u, flags: .maskCommand, label: "⌘U (underline)"),

        // --- Zoom ---
        "zoom in": CommandSpec(keyCode: KeyCode.equals, flags: .maskCommand, label: "⌘+ (zoom in)"),
        "zoom out": CommandSpec(keyCode: KeyCode.minus, flags: .maskCommand, label: "⌘- (zoom out)"),

        // --- In-text cursor movement (handy where Live Patch can't reach,
        // e.g. Chrome web content) ---
        "line start": CommandSpec(keyCode: KeyCode.leftArrow, flags: .maskCommand, label: "⌘← (line start)"),
        "line end": CommandSpec(keyCode: KeyCode.rightArrow, flags: .maskCommand, label: "⌘→ (line end)"),
        "document start": CommandSpec(keyCode: KeyCode.upArrow, flags: .maskCommand, label: "⌘↑ (document start)"),
        "document end": CommandSpec(keyCode: KeyCode.downArrow, flags: .maskCommand, label: "⌘↓ (document end)"),
        "delete word": CommandSpec(keyCode: KeyCode.delete, flags: .maskAlternate, label: "⌥⌫ (delete word)"),
        "backspace": CommandSpec(keyCode: KeyCode.delete, flags: [], label: "⌫ (hold backspace)"),

        // --- System-level ---
        "screenshot": CommandSpec(keyCode: KeyCode.four, flags: [.maskCommand, .maskShift], label: "⇧⌘4 (screenshot)"),
        "emoji": CommandSpec(keyCode: KeyCode.space, flags: [.maskCommand, .maskControl], label: "⌃⌘Space (emoji picker)"),
        "mission control": CommandSpec(keyCode: KeyCode.upArrow, flags: .maskControl, label: "⌃↑ (Mission Control)"),
    ]

    /// "direct" family — no prefix, no command-mode window, ALWAYS
    /// recognized as a command. This is the experiment: "paste", "undo",
    /// "redo", "clear", "cancel" are common enough during normal work that
    /// requiring "action paste" every time felt like a tax — but they're
    /// also common enough as ordinary words/fragments that they risk
    /// colliding with dictation or Live Patch corrections.
    ///
    /// Test plan: if "undo"/"clear"/etc. start firing during normal
    /// dictation or stomp on corrections, move the offending entr(y/ies)
    /// back into `commands` (the "action ___" / 30s-window family) — that's
    /// a one-line change, not a redesign.
    private static let directCommands: [String: CommandSpec] = [
        "paste": CommandSpec(keyCode: KeyCode.v, flags: .maskCommand, label: "⌘V (paste)"),
        "undo": CommandSpec(keyCode: KeyCode.z, flags: .maskCommand, label: "⌘Z (undo)"),
        "redo": CommandSpec(keyCode: KeyCode.z, flags: [.maskCommand, .maskShift], label: "⇧⌘Z (redo)"),
        // "clear" = select all, then delete — clears the focused field.
        "clear": CommandSpec(sequence: [(KeyCode.a, .maskCommand), (KeyCode.delete, [])], label: "⌘A then ⌫ (clear field)"),
        "cancel": CommandSpec(keyCode: KeyCode.escape, flags: [], label: "Escape (cancel)"),
        "select all": CommandSpec(keyCode: KeyCode.a, flags: .maskCommand, label: "⌘A (select all)"),
        "select": CommandSpec(keyCode: KeyCode.a, flags: .maskCommand, label: "⌘A (select all)"),
        "copy": CommandSpec(keyCode: KeyCode.c, flags: .maskCommand, label: "⌘C (copy)"),
    ]

    /// "media" family — playback/volume, gated behind the "media" trigger
    /// word and a short 5s bare-word window (`shortModeWindow`, vs.
    /// `commandModeWindow`'s 30s). These words ("next", "previous", "play",
    /// "pause", "mute") are common in ordinary speech in a way "spotlight"
    /// or "paste" aren't — so they keep their descriptive "media " prefix
    /// (e.g. "media next") rather than joining the 30s bare-word
    /// vocabulary. "media next" opens the SHORT 5s window — just enough to
    /// chain "media next... next... next" without re-saying "media" every
    /// time, without leaving a long window open on words this common.
    private static let mediaCommands: [String: CommandSpec] = [
        // These post NX_KEYTYPE_* "media key" system events, not regular
        // keystrokes — they reach whatever app currently "owns" media keys
        // (Music, Spotify, QuickTime, a browser tab playing audio, etc.),
        // same as pressing the physical media keys on a keyboard.
        "play": CommandSpec(mediaKey: MediaKey.play, label: "Play/Pause"),
        "pause": CommandSpec(mediaKey: MediaKey.play, label: "Play/Pause"),
        "play pause": CommandSpec(mediaKey: MediaKey.play, label: "Play/Pause"),
        "next": CommandSpec(mediaKey: MediaKey.next, label: "Next track"),
        "next track": CommandSpec(mediaKey: MediaKey.next, label: "Next track"),
        "skip": CommandSpec(mediaKey: MediaKey.next, label: "Next track"),
        "previous": CommandSpec(mediaKey: MediaKey.previous, label: "Previous track"),
        "previous track": CommandSpec(mediaKey: MediaKey.previous, label: "Previous track"),
        "volume up": CommandSpec(mediaKey: MediaKey.soundUp, label: "Volume up"),
        "volume down": CommandSpec(mediaKey: MediaKey.soundDown, label: "Volume down"),
        // Bare "up"/"down" — mainly useful inside the 5s media window
        // (after "media volume up/down" or any other "media ___"), where
        // "up"/"down" unambiguously mean volume.
        "up": CommandSpec(mediaKey: MediaKey.soundUp, label: "Volume up"),
        "down": CommandSpec(mediaKey: MediaKey.soundDown, label: "Volume down"),
        "mute": CommandSpec(mediaKey: MediaKey.mute, label: "Mute"),
        // Brightness is the "display" family's canonical home, but people
        // naturally reach for "media" for any up/down AV-ish control —
        // accept it here too rather than insisting on one trigger word.
        "brightness up": CommandSpec(mediaKey: MediaKey.brightnessUp, label: "Brightness up"),
        "brightness down": CommandSpec(mediaKey: MediaKey.brightnessDown, label: "Brightness down"),
    ]

    /// "display" family — screen/system state, gated behind the "display"
    /// trigger word and the same short 5s bare-word window as `media`
    /// (separate timestamp, same duration — see `shortModeWindow`). Same
    /// rationale as media: "lock", "sleep" are common words, so they keep
    /// the "display " prefix as their normal form.
    private static let displayCommands: [String: CommandSpec] = [
        "brightness up": CommandSpec(mediaKey: MediaKey.brightnessUp, label: "Brightness up"),
        "brightness down": CommandSpec(mediaKey: MediaKey.brightnessDown, label: "Brightness down"),
        // Bare "up"/"down" — mainly useful inside the 5s display window
        // (after "display brightness up/down" or any other "display ___"),
        // where "up"/"down" unambiguously mean brightness.
        "up": CommandSpec(mediaKey: MediaKey.brightnessUp, label: "Brightness up"),
        "down": CommandSpec(mediaKey: MediaKey.brightnessDown, label: "Brightness down"),
        // ⌃⌘Q is the standard macOS "Lock Screen" shortcut.
        "lock screen": CommandSpec(keyCode: KeyCode.q, flags: [.maskControl, .maskCommand], label: "⌃⌘Q (lock screen)"),
        "lock": CommandSpec(keyCode: KeyCode.q, flags: [.maskControl, .maskCommand], label: "⌃⌘Q (lock screen)"),
        // No keyboard shortcut exists for these — run via osascript
        // (see `runShellCommand`): one AppleScript toggle, one
        // `do shell script "pmset ..."` for display sleep.
        "dark mode": CommandSpec(
            shell: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
            label: "Toggle dark/light mode"
        ),
        "sleep": CommandSpec(
            shell: "do shell script \"pmset displaysleepnow\"",
            label: "Sleep display"
        ),
    ]

    /// How long after a recognized command bare command words (without the
    /// "action" prefix) keep working — "action paste" opens a 30s window
    /// where you can just say "copy", "spotlight", "find", etc. and chain
    /// actions back-to-back without re-saying "action" each time. Any
    /// recognized command — prefixed or bare — resets the window back to
    /// the full 30s. Deliberately just a timestamp: no mode toggle, no
    /// extra state machine. While the window is open, a bare phrase that
    /// happens to exactly match a command word is treated as that command
    /// instead of a Live Patch correction target — that's the trade-off the
    /// window buys you, and why it expires on its own rather than staying
    /// on forever. 30s is fine here because this vocabulary ("spotlight",
    /// "paste", "address bar"...) rarely shows up in normal dictation, so
    /// there's room to pause and think between actions.
    private static let commandModeWindow: TimeInterval = 30

    /// nil, or the time until which bare command words (from `commands`)
    /// are recognized. Set any time a command (prefixed or bare) actually
    /// runs.
    private var commandModeUntil: Date?

    /// The trigger word for the "open/launch/switch-to app or site" family —
    /// "mac chrome", "mac gmail", "mac search for pizza dough", etc. ("switch
    /// to <target>" is also accepted as a synonym — see executeVoiceCommand.)
    private static let macTriggerWord = "mac"

    /// The trigger word for `mediaCommands` — "media next", "media mute",
    /// etc.
    private static let mediaTriggerWord = "media"

    /// The trigger word for `displayCommands` — "display lock", "display
    /// dark mode", etc.
    private static let displayTriggerWord = "display"

    /// The trigger word for capture-family commands — "capture note <...>",
    /// "capture reminder <...>", etc. Unlike the other families, the words
    /// after the kind ("note"/"reminder"/"task"/"idea") aren't looked up in
    /// a table — they're the content to capture, verbatim.
    private static let captureTriggerWord = "capture"
    private static let reportTriggerWord = "report"

    /// Same idea as `commandModeWindow`, but much shorter: 5s instead of
    /// 30s. Used by both the `media` and `display` families. Their
    /// vocabularies ("next", "previous", "play", "pause", "mute", "lock",
    /// "sleep"...) are common in ordinary speech, so they always keep their
    /// family prefix rather than joining the long-lived 30s bare-word
    /// vocabulary — but a short window still lets you chain "media next...
    /// next... next" without repeating "media" every time.
    private static let shortModeWindow: TimeInterval = 5

    /// nil, or the time until which bare `mediaCommands` words are
    /// recognized. Set any time a media command (prefixed or bare) runs.
    private var mediaModeUntil: Date?

    /// nil, or the time until which bare `displayCommands` words are
    /// recognized. Set any time a display command (prefixed or bare) runs.
    private var displayModeUntil: Date?

    /// Recognizes a small set of "command" phrases and executes them via
    /// synthetic input (CGEvent or osascript), bypassing AX entirely.
    /// Returns true if `phrase` was a recognized command (handled — caller
    /// should not also try a similarity-based correction).
    ///
    /// These are organized into "families" — separate trigger words/tables
    /// instead of one giant bucket — so each family's risk of colliding
    /// with normal dictation can be tuned independently:
    ///   - "action <cmd>"             -> `commands` (editing/app shortcuts), 30s bare-word window
    ///   - "mac <target>" / "switch to <target>" -> `openTarget`/`webSearch` (apps, sites, search)
    ///   - "media <cmd>"               -> `mediaCommands` (playback/volume), 5s bare-word window
    ///   - "display <cmd>"             -> `displayCommands` (screen/system state), 5s bare-word window
    ///   - "capture <kind> <text...>"  -> Notes/Reminders via osascript
    private func executeVoiceCommand(_ phrase: String) -> Bool {
        let normalized = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))

        let words = normalized.split(separator: " ").map(String.init)

        // Adaptive prompt response — "yes"/"no" when a correction prompt is showing
        if pendingAdaptivePrompt != nil {
            if normalized == "yes" || normalized == "yeah" || normalized == "correct" || normalized == "approve" {
                handleAdaptiveResponse(approved: true)
                return true
            }
            if normalized == "no" || normalized == "nope" || normalized == "wrong" || normalized == "deny" {
                handleAdaptiveResponse(approved: false)
                return true
            }
        }

        let inCommandMode = commandModeUntil.map { $0 > Date() } ?? false
        let inMediaMode = mediaModeUntil.map { $0 > Date() } ?? false
        let inDisplayMode = displayModeUntil.map { $0 > Date() } ?? false

        // Stop held backspace if one is running
        if backspaceHoldTimer != nil {
            let stopWords: Set<String> = ["stop", "ok", "done", "cancel", "enough", "slash"]
            if stopWords.contains(normalized) {
                stopBackspaceHold()
                return true
            }
        }

        // --- "direct" family ---
        // No prefix, no window check — "paste"/"undo"/"redo"/"clear"/
        // "cancel" always fire as-is. This is the experiment from the
        // directCommands doc comment: if these collide with normal
        // dictation or corrections, move the offending one back into
        // `commands` (the "action ___" family).
        if let spec = Self.directCommands[normalized] {
            appendLog("[LivePatch] COMMAND: \"\(phrase)\" (direct) -> simulating \(spec.label)")
            runCommandSpec(spec)
            commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
            notify("SpeakUp heard: \(phrase)", spec.label)
            // Spoken feedback for direct commands
            switch normalized {
            case "paste", "undo", "redo", "clear": speak("Done")
            default: break
            }
            return true
        }

        // --- "mac <target>" family ---
        // Single-word trigger "mac" — NOT "open" — because a dictated
        // sentence starting with "open" ("Open the door and...") is common,
        // but one starting with "mac" isn't. "switch to <target>" and
        // "launch <target>" are accepted as natural-language synonyms for
        // the same family — "switch to chrome" / "launch zoom" read better
        // than "mac chrome" / "mac zoom" depending on whether you're
        // bringing something to the front or starting it fresh, and neither
        // is likely to start a normal dictated sentence.
        //
        // Two intents live under this family, split by what the user
        // actually wants to happen on screen:
        //  - FOREGROUND ("I want to see it now"): "mac chrome", "launch
        //    zoom", "mac <site>", "<target> new window" -> openTarget,
        //    which activates the resulting app/window.
        //  - BACKGROUND ("get it ready, I'll deal with it later"): "search
        //    for <query>" / "google <query>" / "look up <query>" ->
        //    webSearch(background: true) — opens the tab in the default
        //    browser WITHOUT stealing focus from whatever you're doing.
        //    Say "mac chrome" / "switch to chrome" afterward to bring it
        //    to the front when you're ready.
        //
        // "<target> new window" (e.g. "mac launch chrome new window") opens
        // a fresh instance/window instead of just activating the existing
        // one. "right tab"/"left tab" are in-app tab navigation (⌘}/⌘{)
        // sent to whatever's currently frontmost — handled here rather than
        // via openTarget since there's no app/site to resolve.
        let openCommandPrefix: Int? = {
            if words.count >= 2, words[0] == Self.macTriggerWord { return 1 }
            // "max" — STT very commonly mishears "Mac" as "Max" (same
            // vowel/consonant shape). Accept it as an alias for the
            // trigger word rather than trying to fix the recognizer.
            if words.count >= 2, words[0] == "max" { return 1 }
            if words.count >= 2, words[0] == "launch" { return 1 }
            if words.count >= 3, words[0] == "switch", words[1] == "to" { return 2 }
            return nil
        }()
        if let prefixLen = openCommandPrefix {
            let rest = words.dropFirst(prefixLen).joined(separator: " ")

            // --- "prepare" family (v0) ---
            // "Mac prepare <target>" — open/launch <target> in the
            // background (no focus stolen), remember it as the
            // "last prepared" target, and confirm via notification. The
            // counterpart is "Mac show prepared" below, which brings it
            // forward when you're ready. "start <target>" and "work on
            // <target>" are natural-language synonyms for the same
            // background-launch behavior ("mac start claude" / "mac work on
            // gmail"). "repair "/"compare " are here too — STT regularly
            // mishears "prepare" as either of those.
            for prefix in ["prepare ", "repair ", "compare ", "start ", "work on "] {
                if rest.hasPrefix(prefix), rest.count > prefix.count {
                    let target = String(rest.dropFirst(prefix.count))
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> prepare \"\(target)\" (background)")
                    openTarget(target, background: true)
                    lastPreparedTarget = target
                    commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                    notify("SpeakUp heard: \(phrase)", "Prepared \"\(target)\"")
                    return true
                }
            }

            // "Mac show prepared" — recall whatever was last prepared and
            // bring it to the front.
            if rest == "show prepared" {
                guard let target = lastPreparedTarget else {
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> nothing prepared yet")
                    notify("SpeakUp heard: \(phrase)", "Nothing prepared yet")
                    return true
                }
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> show prepared \"\(target)\"")
                openTarget(target)
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                notify("SpeakUp heard: \(phrase)", "Showing \"\(target)\"")
                return true
            }

            // "Mac show <target>" / "Mac show me <target>" — same as bare
            // "mac <target>", just a more natural way to say "bring this
            // forward" as the opposite of "prepare". "show me " must be
            // checked before "show ", or "show me gmail" would strip only
            // "show " and leave "me gmail" as the target. Strip whichever
            // matches and fall through to the normal foreground-resolution
            // logic below.
            var rest2 = rest
            if rest2.hasPrefix("show me "), rest2.count > "show me ".count {
                rest2 = String(rest2.dropFirst("show me ".count))
            } else if rest2.hasPrefix("show "), rest2.count > "show ".count {
                rest2 = String(rest2.dropFirst("show ".count))
            }

            // --- "remind me"/"set reminder" -> Reminders ---
            // "Mac remind me 9:35 to record demo" -> Reminders item "record
            // demo" due/alerting at 9:35 (today, or tomorrow if 9:35 has
            // already passed). "Mac remind me <text>" (no recognized
            // "<time> to") and "Mac set reminder <text>" / "Mac set a
            // reminder <text>" just create a plain reminder with no due
            // date — same as the existing "capture reminder <text>" family,
            // reachable from the "mac" trigger word too.
            for prefix in ["remind me ", "set a reminder ", "set reminder "] {
                if rest2.hasPrefix(prefix), rest2.count > prefix.count {
                    let remainder = String(rest2.dropFirst(prefix.count))
                    let remainderWords = remainder.split(separator: " ").map(String.init)
                    var task = remainder
                    var time: (hour: Int, minute: Int)? = nil
                    if let parsed = Self.parseSpokenTime(remainderWords) {
                        let afterTime = Array(remainderWords.dropFirst(parsed.consumedWords))
                        if afterTime.first == "to", afterTime.count > 1 {
                            time = (parsed.hour, parsed.minute)
                            task = afterTime.dropFirst().joined(separator: " ")
                        }
                    }
                    let trimmedTask = task.trimmingCharacters(in: .whitespaces)
                    guard !trimmedTask.isEmpty else {
                        appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> reminder had no content, ignored")
                        notify("SpeakUp heard: \(phrase)", "Nothing to remind you about")
                        return true
                    }
                    let timeNote = time.map { " at \(Self.formatTime(hour: $0.hour, minute: $0.minute))" } ?? ""
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> reminder \"\(trimmedTask)\"\(timeNote)")
                    captureReminder(trimmedTask, hour: time?.hour, minute: time?.minute)
                    commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                    notify("SpeakUp heard: \(phrase)", "Reminder: \"\(trimmedTask)\"\(timeNote)")
                    return true
                }
            }

            // --- "Parallel Work" family (v1) ---
            // Side-by-side window arrangement: left = whatever was
            // frontmost before the command, right = the target. Reduced to
            // the verbs that map onto "Story 4": work with -> focus -> put
            // away. Everything else (split <A> and <B>, split my screen,
            // parallel work/side by side, focus left/right, tab nav) was
            // redundant or too fiddly to remember — cut per the "tired
            // Marty at 2am" pass.

            // "Mac work with <target>" — pair the current app (left) with
            // <target> (right).
            if rest2.hasPrefix("work with "), rest2.count > "work with ".count {
                let target = String(rest2.dropFirst("work with ".count))
                let left = NSWorkspace.shared.frontmostApplication
                let right = activateTargetAndGetApp(target, excluding: left)
                positionSideBySide(left: left, right: right)
                leftPaneApp = left
                rightPaneApp = right
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> split \(left?.localizedName ?? "?") | \(right?.localizedName ?? target)")
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                notify("SpeakUp heard: \(phrase)", "Split: \(left?.localizedName ?? "left") | \(right?.localizedName ?? target)")
                return true
            }

            // "Mac focus" — toggle between the two panes set up by "work
            // with". No left/right to remember: whichever one isn't
            // frontmost is the one you want.
            if rest2 == "focus" {
                guard let left = leftPaneApp, let right = rightPaneApp else {
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> no panes set yet")
                    notify("SpeakUp heard: \(phrase)", "Nothing to switch to yet — try \"mac work with <target>\" first")
                    return true
                }
                let frontmost = NSWorkspace.shared.frontmostApplication
                let target = (frontmost?.processIdentifier == left.processIdentifier) ? right : left
                target.activate(options: [.activateIgnoringOtherApps])
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> focused \(target.localizedName ?? "?")")
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                notify("SpeakUp heard: \(phrase)", "Focused \(target.localizedName ?? "?")")
                return true
            }

            // "Mac put away <target>" / "Mac put <target> away" — hide a
            // specific app by name. This is the target-based v1 of put
            // away: works directly off whatever you `prepare`d or
            // `show`ed, no "work with" required first. Both word orders
            // are accepted — natural speech doesn't keep "away" pinned to
            // "put".
            var putAwayTarget: String? = nil
            if rest2.hasPrefix("put away "), rest2.count > "put away ".count {
                putAwayTarget = String(rest2.dropFirst("put away ".count))
            } else if rest2.hasPrefix("put "), rest2.hasSuffix(" away"),
                      rest2.count > "put ".count + " away".count {
                putAwayTarget = String(rest2.dropFirst("put ".count).dropLast(" away".count))
            }
            if let target = putAwayTarget {
                guard let app = runningApp(named: target) else {
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> \"\(target)\" isn't running, nothing to put away")
                    notify("SpeakUp heard: \(phrase)", "\"\(target)\" isn't open")
                    return true
                }
                app.hide()
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> hid \(app.localizedName ?? target)")
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                notify("SpeakUp heard: \(phrase)", "Put away \(app.localizedName ?? target)")
                return true
            }

            // "Mac put away" — the reverse of bringing the right pane up:
            // hide it and return focus to the left (primary work) pane.
            // "Mac focus" brings it back (activating an app automatically
            // un-hides it).
            if rest2 == "put away" {
                guard let left = leftPaneApp else {
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> no left pane set yet")
                    notify("SpeakUp heard: \(phrase)", "No left pane set yet — try \"mac work with <target>\" first")
                    return true
                }
                rightPaneApp?.hide()
                left.activate(options: [.activateIgnoringOtherApps])
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> hid \(rightPaneApp?.localizedName ?? "right pane"), focused \(left.localizedName ?? "?")")
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                notify("SpeakUp heard: \(phrase)", "Back to \(left.localizedName ?? "work")")
                return true
            }

            // "mac report <kind>" / "mac report <kind> <text>" — file a report from
            // the mac family. "mac report bug" alone is valid (saves context snapshot).
            // "mac report issue paste fired twice" includes a description.
            if rest2.hasPrefix("report ") || rest2 == "report" {
                let afterReport = rest2.hasPrefix("report ") ? String(rest2.dropFirst("report ".count)) : ""
                let reportWords = afterReport.split(separator: " ").map(String.init)
                let kind = reportWords.first ?? "report"
                let text = reportWords.count > 1 ? reportWords.dropFirst().joined(separator: " ") : ""
                handleCapture(kind: kind, text: text, phrase: phrase)
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                return true
            }

            // "mac run <package>" — execute a named script from ~/Documents/SpeakUp/packages/
            // Phrase words become the filename: "mac run rebuild speakup" → rebuild-speakup.sh
            if rest2.hasPrefix("run "), rest2.count > "run ".count {
                let packageName = String(rest2.dropFirst("run ".count))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .components(separatedBy: .whitespaces).joined(separator: "-")
                let packagesDir = NSHomeDirectory() + "/Documents/SpeakUp/packages"
                let scriptPath = packagesDir + "/" + packageName + ".sh"
                if FileManager.default.fileExists(atPath: scriptPath) {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                    proc.arguments = [scriptPath]
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> running package \"\(packageName)\"")
                    do {
                        try proc.run()
                        logPackageRun(packageName: packageName, trigger: phrase)
                        notify("SpeakUp running: \(packageName)", nil)
                    } catch {
                        appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> package failed: \(error)")
                        notify("Package failed: \(packageName)", error.localizedDescription)
                    }
                } else {
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> package \"\(packageName)\" not found")
                    notify("No package: \(packageName)", "Add \(packageName).sh to ~/Documents/SpeakUp/packages/")
                }
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                return true
            }

            // "mac list packages" — show available packages
            if rest2 == "list packages" || rest2 == "show packages" {
                let packagesDir = NSHomeDirectory() + "/Documents/SpeakUp/packages"
                let scripts = (try? FileManager.default.contentsOfDirectory(atPath: packagesDir))?
                    .filter { $0.hasSuffix(".sh") }
                    .map { $0.replacingOccurrences(of: ".sh", with: "") }
                    .sorted() ?? []
                if scripts.isEmpty {
                    notify("SpeakUp packages", "None yet — add .sh files to ~/Documents/SpeakUp/packages/")
                } else {
                    notify("SpeakUp packages (\(scripts.count))", scripts.joined(separator: ", "))
                }
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> packages: \(scripts.joined(separator: ", "))")
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                return true
            }


            // "mac support" / "mac technical support" — generate and save a support report
            if rest2 == "support" || rest2 == "technical support" || rest2 == "help" {
                sendTechnicalSupport()
                commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                return true
            }

            // Veq-tier commands — flows, AI context, memory
            let veqCommands = ["send to codex", "send to claude", "send to gemini",
                               "remember this", "recall", "what was i working on",
                               "run flow", "start flow", "run sequence",
                               "context", "save context", "load context"]
            for vc in veqCommands {
                if rest2.hasPrefix(vc) {
                    if !requireProduct("veq", feature: "'\(vc)'") { return true }
                    // If Veq is installed, it handles these — placeholder for now
                    appendLog("[Veq] Would execute: \(rest2)")
                    return true
                }
            }

            // Buffer-tier commands — cross-machine communication
            let bufferCommands = ["send buffer to", "paste to session",
                                  "tell codex", "tell claude", "tell gemini",
                                  "sync", "push to mini", "pull from mini"]
            for bc in bufferCommands {
                if rest2.hasPrefix(bc) {
                    if !requireProduct("buffer", feature: "'\(bc)'") { return true }
                    appendLog("[Buffer] Would execute: \(rest2)")
                    return true
                }
            }

            // "mac sleep" — voice panic-off: turns live mode off immediately
            if rest2 == "sleep" || rest2 == "stop listening" || rest2 == "go to sleep" {
                if liveModeOn {
                    toggleLiveMode()
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> live mode off (voice sleep)")
                    notify("SpeakUp sleeping", "Double-tap ⌘ or menu to wake")
                } else {
                    notify("SpeakUp already off", "Double-tap ⌘ to wake")
                }
                return true
            }




            // "mac close <app>" / "mac quit <app>" — terminate a named running app
            for closePrefix in ["close ", "quit ", "kill "] {
                if rest2.hasPrefix(closePrefix), rest2.count > closePrefix.count {
                    let target = String(rest2.dropFirst(closePrefix.count)).trimmingCharacters(in: .whitespaces)
                    if let app = runningApp(named: target) {
                        let name = app.localizedName ?? target
                        app.terminate()
                        appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> terminated \(name)")
                        notify("Closed \(name)", nil)
                    } else {
                        appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> app not running: \(target)")
                        notify("Not running: \"\(target)\"", "Nothing to close")
                    }
                    commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
                    return true
                }
            }

            var notifyBody: String? = nil
            // Longest/most-specific prefixes first — "search for " must be
            // checked before bare "search ", or "search for pizza" would
            // match "search " with target "for pizza".
            for prefix in ["search for ", "look up ", "find me ", "google ", "search "] {
                if rest2.hasPrefix(prefix), rest2.count > prefix.count {
                    var target = String(rest2.dropFirst(prefix.count))
                    // "... in the background"/"... in background" is a
                    // meta-instruction ("do this without taking focus"), not
                    // part of the query — and this whole family is already
                    // background-only, so strip it rather than searching
                    // for it literally.
                    for suffix in [" in the background", " in background"] {
                        if target.hasSuffix(suffix), target.count > suffix.count {
                            target = String(target.dropLast(suffix.count))
                            break
                        }
                    }
                    appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> web search (background) \"\(target)\"")
                    webSearch(target, background: true)
                    // Remember this as the "prepared" item too, so "mac show
                    // prepared" / "mac parallel work" / "mac side by side"
                    // can bring it into view later.
                    lastPreparedTarget = target
                    notifyBody = "Ready in background: \"\(target)\""
                    break
                }
            }
            if notifyBody == nil {
                var target = rest2
                var newWindow = false
                if target.hasSuffix(" new window"), target.count > " new window".count {
                    target = String(target.dropLast(" new window".count))
                    newWindow = true
                } else {
                    // Leading "new " ("mac open new chrome") is a more
                    // natural way to say "new window" than the trailing
                    // form. Strip leading filler words first so "open new
                    // chrome" -> "new chrome" -> "chrome" (new window).
                    // Known edge case: a target that genuinely starts with
                    // "new" ("mac open new york times") gets misread as
                    // "york times" (new window) — acceptable for v0.
                    var probeWords = target.split(separator: " ").map { $0.lowercased() }
                    while let first = probeWords.first, probeWords.count > 1, Self.openTargetFillerWords.contains(first) {
                        probeWords.removeFirst()
                    }
                    if probeWords.first == "new", probeWords.count > 1 {
                        newWindow = true
                        target = target.split(separator: " ").map(String.init)
                            .suffix(probeWords.count - 1)
                            .joined(separator: " ")
                    }
                }
                appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> open \"\(target)\"\(newWindow ? " (new window)" : "")")
                openTarget(target, newWindow: newWindow)
                notifyBody = newWindow ? "Opening \"\(target)\" (new window)" : "Opening \"\(target)\""
            }
            commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
            notify("SpeakUp heard: \(phrase)", notifyBody)
            return true
        }

        // --- "media <cmd>" family ---
        // Always active, no command-mode needed. Opens the short 5s media
        // window so a quick run of "media next... next..." doesn't require
        // repeating "media" each time.
        if let first = words.first, first == Self.mediaTriggerWord, words.count > 1 {
            let rest = words.dropFirst().joined(separator: " ")
            guard let spec = Self.mediaCommands[rest] else {
                appendLog("[LivePatch] heard trigger word \"\(Self.mediaTriggerWord)\" but \"\(rest)\" isn't a recognized media command — ignored.")
                notify("SpeakUp heard: \(phrase)", "Not a recognized media command")
                return true
            }
            appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> simulating \(spec.label)")
            runCommandSpec(spec)
            mediaModeUntil = Date().addingTimeInterval(Self.shortModeWindow)
            appendLog("[LivePatch] media mode active for the next \(Int(Self.shortModeWindow))s — bare media words will be recognized.")
            notify("SpeakUp heard: \(phrase)", spec.label)
            return true
        }

        // Bare media word ("next", "mute", ...) inside the 5s media window
        // opened by a prior "media ___" command.
        if inMediaMode, let spec = Self.mediaCommands[normalized] {
            appendLog("[LivePatch] COMMAND: \"\(phrase)\" (bare word, media mode) -> simulating \(spec.label)")
            runCommandSpec(spec)
            mediaModeUntil = Date().addingTimeInterval(Self.shortModeWindow)
            appendLog("[LivePatch] media mode active for the next \(Int(Self.shortModeWindow))s — bare media words will be recognized.")
            notify("SpeakUp heard: \(phrase)", spec.label)
            return true
        }

        // --- "display <cmd>" family ---
        // Mirrors "media": always active, opens its own short 5s window.
        if let first = words.first, first == Self.displayTriggerWord, words.count > 1 {
            let rest = words.dropFirst().joined(separator: " ")
            guard let spec = Self.displayCommands[rest] else {
                appendLog("[LivePatch] heard trigger word \"\(Self.displayTriggerWord)\" but \"\(rest)\" isn't a recognized display command — ignored.")
                notify("SpeakUp heard: \(phrase)", "Not a recognized display command")
                return true
            }
            appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> simulating \(spec.label)")
            runCommandSpec(spec)
            displayModeUntil = Date().addingTimeInterval(Self.shortModeWindow)
            appendLog("[LivePatch] display mode active for the next \(Int(Self.shortModeWindow))s — bare display words will be recognized.")
            notify("SpeakUp heard: \(phrase)", spec.label)
            return true
        }

        // Bare display word ("lock", "sleep", ...) inside the 5s display
        // window opened by a prior "display ___" command.
        if inDisplayMode, let spec = Self.displayCommands[normalized] {
            appendLog("[LivePatch] COMMAND: \"\(phrase)\" (bare word, display mode) -> simulating \(spec.label)")
            runCommandSpec(spec)
            displayModeUntil = Date().addingTimeInterval(Self.shortModeWindow)
            appendLog("[LivePatch] display mode active for the next \(Int(Self.shortModeWindow))s — bare display words will be recognized.")
            notify("SpeakUp heard: \(phrase)", spec.label)
            return true
        }

        // --- "capture <kind> <text...>" family ---
        // "capture reminder call mom" -> Reminders item "call mom".
        // "capture note <...>" / "capture idea <...>" -> Notes item.
        // The words after <kind> are the content verbatim, not a table
        // lookup — see `handleCapture`.
        if let first = words.first, first == Self.captureTriggerWord, words.count > 2 {
            let kind = words[1]
            let text = words.dropFirst(2).joined(separator: " ")
            handleCapture(kind: kind, text: text, phrase: phrase)
            commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
            return true
        }

        // --- "report <kind> <text...>" family ---
        // "report bug" alone is valid — saves context snapshot with no body text.
        // "report bug paste fired twice" includes a description too.
        if let first = words.first, first == Self.reportTriggerWord, words.count > 1 {
            let kind = words[1]
            let text = words.count > 2 ? words.dropFirst(2).joined(separator: " ") : ""
            handleCapture(kind: kind, text: text, phrase: phrase)
            commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
            return true
        }

        // --- "action <cmd>" family + 30s bare-word window ---
        let rest: String
        let triggeredByActionWord: Bool
        if let first = words.first, first == Self.commandTriggerWord, words.count > 1 {
            rest = words.dropFirst().joined(separator: " ")
            triggeredByActionWord = true
        } else if inCommandMode, userCommands[normalized] != nil || Self.commands[normalized] != nil {
            // Bare command word inside the 30s window after a prior command.
            rest = normalized
            triggeredByActionWord = false
        } else {
            return false
        }

        guard let spec = userCommands[rest] ?? Self.commands[rest] else {
            // Only "action <unrecognized>" gets here (the bare-word branch
            // above already checked Self.commands[normalized] != nil) —
            // swallow it so an unrecognized command word doesn't also get
            // tried as a Live Patch correction.
            appendLog("[LivePatch] heard trigger word \"\(Self.commandTriggerWord)\" but \"\(rest)\" isn't a recognized command — ignored.")
            notify("SpeakUp heard: \(phrase)", "Not a recognized command")
            return true
        }

        let modeNote = triggeredByActionWord ? "" : " (bare word, command mode)"
        appendLog("[LivePatch] COMMAND: \"\(phrase)\"\(modeNote) -> simulating \(spec.label)")

        // "backspace" — hold mode: repeats ⌫ every 80ms until stopped by voice or physical key
        if rest == "backspace" {
            startBackspaceHold()
            commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
            notify("SpeakUp heard: \(phrase)", "⌫ holding — say stop/ok/done or press ⌫")
            return true
        }

        // "select all" — small delay so focused field is ready
        if rest == "select all" || rest == "select" || rest == "grab all" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.runCommandSpec(spec)
            }
        // "deselect" — try Escape first (works in more apps), then rightArrow
        } else if rest == "deselect" || rest == "deselect all" || rest == "clear selection" {
            simulateKeyCombo(keyCode: 53, flags: [], label: "⎋ (escape/deselect)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.runCommandSpec(spec)
            }
        } else {
            runCommandSpec(spec)
        }
        commandModeUntil = Date().addingTimeInterval(Self.commandModeWindow)
        appendLog("[LivePatch] command mode active for the next \(Int(Self.commandModeWindow))s — bare command words will be recognized.")
        notify("SpeakUp heard: \(phrase)", spec.label)
        return true
    }

    private func startBackspaceHold() {
        stopBackspaceHold()
        speak("Holding")
        backspaceHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.simulateKeyCombo(keyCode: KeyCode.delete, flags: [], label: "⌫ (hold)")
        }
    }

    private func stopBackspaceHold() {
        guard backspaceHoldTimer != nil else { return }
        backspaceHoldTimer?.invalidate()
        backspaceHoldTimer = nil
        speak("Done")
    }

    /// Dispatches a `CommandSpec` to whichever execution path it specifies —
    /// regular keystroke, media key, AppleScript, or key sequence.
    private func runCommandSpec(_ spec: CommandSpec) {
        if let keyCode = spec.keyCode {
            simulateKeyCombo(keyCode: keyCode, flags: spec.flags, label: spec.label)
        } else if let mediaKey = spec.mediaKey {
            simulateMediaKey(mediaKey, label: spec.label)
        } else if let shell = spec.shell {
            runShellCommand(shell, label: spec.label)
        } else if let sequence = spec.sequence {
            simulateKeySequence(sequence, label: spec.label)
        }
    }

    /// "capture <kind> <text>" — creates something in Notes/Reminders or saves a
    /// structured report. "note" -> Notes; "reminder"/"task"/"todo" -> Reminders;
    /// "bug"/"issue"/"feedback"/"report" -> JSONL report file; "idea" -> both Notes and report.
    private func handleCapture(kind: String, text: String, phrase: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case "note", "notes":
            guard !trimmed.isEmpty else {
                notify("SpeakUp heard: \(phrase)", "Nothing to capture")
                return
            }
            captureNote(trimmed)
            notify("SpeakUp heard: \(phrase)", "Saved note: \"\(trimmed)\"")
        case "idea", "ideas":
            guard !trimmed.isEmpty else {
                notify("SpeakUp heard: \(phrase)", "Nothing to capture")
                return
            }
            captureNote("Idea: \(trimmed)")
        case "reminder", "reminders", "task", "tasks", "todo":
            guard !trimmed.isEmpty else {
                notify("SpeakUp heard: \(phrase)", "Nothing to capture")
                return
            }
            captureReminder(trimmed)
            notify("SpeakUp heard: \(phrase)", "Saved reminder: \"\(trimmed)\"")
        case "bug", "bugs", "issue", "issues":
            if captureWindowActive {
                notify("Capture already running", "Wait for it to finish")
            } else {
                startCaptureWindow(kind: kind, description: trimmed)
            }
        case "feedback", "report":
            appendLog("[SpeakUp] capture \(kind): \"\(trimmed)\" — LivePatch required for full reporting")
            notify("LivePatch required", "Full reports, auto-learning, and custom commands are LivePatch features. Visit madr3b3l.github.io/speakup-livepatch to upgrade.")
            speak("LivePatch feature")
        default:
            appendLog("[LivePatch] COMMAND: \"\(phrase)\" -> capture kind \"\(kind)\" not recognized (try \"bug\", \"issue\", \"feedback\", \"note\", \"reminder\", or \"idea\") — ignored")
            notify("SpeakUp heard: \(phrase)", "Capture type \"\(kind)\" not recognized")
        }
    }

    /// Creates a new Notes item via osascript.
    private func captureNote(_ text: String) {
        let escaped = appleScriptEscape(text)
        let script = "tell application \"Notes\" to make new note at folder \"Notes\" with properties {body:\"\(escaped)\"}"
        runShellCommand(script, label: "Capture note: \"\(text)\"")
    }

    /// Appends a line to ~/Documents/SpeakUp/package-runs.log every time a package executes.
    private func logPackageRun(packageName: String, trigger: String) {
        let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/package-runs.log")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = "\(iso.string(from: Date()))\t\(packageName)\t\"\(trigger)\"\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fh = try? FileHandle(forWritingTo: logURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    /// Appends a structured report entry to ~/Documents/SpeakUp/reports/speakup-reports.jsonl.
    /// Captures app context, AX/Speech permission state, and the last 10 log lines automatically.

    /// Creates a new Reminders item via osascript. If `hour`/`minute` are
    /// given ("Mac remind me 9:35 to record demo"), the reminder gets a due
    /// date/alert at that time — today, or tomorrow if that time has
    /// already passed. Built by nudging `(current date)`'s time components
    /// rather than parsing a date string, since AppleScript date-string
    /// parsing is locale-dependent.
    private func captureReminder(_ text: String, hour: Int? = nil, minute: Int? = nil) {
        let escaped = appleScriptEscape(text)
        let script: String
        if let hour = hour, let minute = minute {
            script = """
            set targetDate to (current date)
            set hours of targetDate to \(hour)
            set minutes of targetDate to \(minute)
            set seconds of targetDate to 0
            if targetDate < (current date) then set targetDate to targetDate + (1 * days)
            tell application "Reminders" to make new reminder with properties {name:"\(escaped)", due date:targetDate, remind me date:targetDate}
            """
        } else {
            script = "tell application \"Reminders\" to make new reminder with properties {name:\"\(escaped)\"}"
        }
        let timeNote = (hour != nil && minute != nil) ? " at \(Self.formatTime(hour: hour!, minute: minute!))" : ""
        runShellCommand(script, label: "Capture reminder: \"\(text)\"\(timeNote)")
    }

    /// Parses a leading spoken time like "9:35" or "9:35 pm" from `words`.
    /// Returns the 24-hour hour/minute and how many leading words were
    /// consumed (1 for "9:35", 2 for "9:35 pm"), or nil if `words` doesn't
    /// start with something that looks like a time.
    private static func parseSpokenTime(_ words: [String]) -> (hour: Int, minute: Int, consumedWords: Int)? {
        guard let first = words.first else { return nil }
        let parts = first.replacingOccurrences(of: ".", with: ":").split(separator: ":")
        guard parts.count == 2, var hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        var consumed = 1
        if words.count > 1 {
            let next = words[1].lowercased()
            if next == "am" || next == "pm" || next == "a.m." || next == "p.m." {
                let isPM = next.hasPrefix("p")
                if isPM, hour < 12 { hour += 12 }
                if !isPM, hour == 12 { hour = 0 }
                consumed = 2
            }
        }
        return (hour, minute, consumed)
    }

    /// Formats a 24-hour hour/minute as "9:35 AM" for notifications.
    private static func formatTime(hour: Int, minute: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        var displayHour = hour % 12
        if displayHour == 0 { displayHour = 12 }
        return String(format: "%d:%02d %@", displayHour, minute, period)
    }

    /// Escapes a string for embedding in an AppleScript string literal —
    /// backslashes and double quotes need `\`-escaping.
    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Simulates a key press (with optional modifier flags) at the system
    /// level via CGEvent. Works in any focused app/field — including Chrome
    /// and Electron apps like Claude desktop, where SpeakUp's AX-based
    /// read/write paths are blocked (AXError -25212) — because it's a real
    /// keyboard event, not an AX attribute write.
    private func simulateKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags, label: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            appendLog("[LivePatch] COMMAND: \(label) -> failed to create CGEvent")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        appendLog("[LivePatch] COMMAND: \(label) -> posted")
    }

    /// Posts multiple key combos in order, with a short delay between each
    /// so the receiving app has time to process one before the next
    /// arrives — e.g. "clear" = select all (⌘A), then delete.
    private func simulateKeySequence(_ sequence: [(keyCode: CGKeyCode, flags: CGEventFlags)], label: String) {
        for (index, step) in sequence.enumerated() {
            simulateKeyCombo(keyCode: step.keyCode, flags: step.flags, label: "\(label) [step \(index + 1)/\(sequence.count)]")
            if index < sequence.count - 1 {
                usleep(30_000)
            }
        }
    }

    /// Posts a media-key system-defined event (play/pause, next/previous
    /// track, volume, brightness, mute). These are NOT regular keystrokes —
    /// they're the same "system defined" NSEvents the hardware media keys
    /// generate — so they go through NSEvent.otherEvent + a special
    /// subtype/data1 encoding rather than CGEvent(keyboardEventSource:).
    /// `key` is one of the `MediaKey.*` NX_KEYTYPE_* constants.
    private func simulateMediaKey(_ key: Int32, label: String) {
        for keyDown in [true, false] {
            let flags: NSEvent.ModifierFlags = keyDown
                ? NSEvent.ModifierFlags(rawValue: 0xa00)
                : NSEvent.ModifierFlags(rawValue: 0xb00)
            let data1 = Int((key << 16) | (keyDown ? 0xa00 : 0xb00))
            if let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        appendLog("[LivePatch] COMMAND: \(label) -> posted (media key)")
    }

    /// Runs a one-line AppleScript via osascript — for commands with no
    /// keyboard shortcut at all (e.g. toggling dark mode).
    private func runShellCommand(_ script: String, label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            appendLog("[LivePatch] COMMAND: \(label) -> ran osascript")
        } catch {
            appendLog("[LivePatch] COMMAND: \(label) -> failed to run osascript: \(error)")
        }
    }

    /// Filler words people naturally tack onto "mac ___" / "switch to ___"
    /// out of old habit ("mac open zoom", "switch to the terminal app") —
    /// stripped from the FRONT of the target (repeatedly, so "open the app
    /// zoom" also collapses to "zoom") before alias/app resolution. Without
    /// this, "mac open zoom" resolves to the literal app name "Open Zoom",
    /// fails to launch, and falls through to a web search for "open zoom" —
    /// which is the "it searches that in Chrome" symptom.
    private static let openTargetFillerWords: Set<String> = ["open", "launch", "the", "go", "to", "app", "application"]

    /// Resolves "open <target>" / "go to <target>". Tries, in order:
    ///  1. A known website alias (gmail -> mail.google.com, etc.)
    ///  2. Something that already looks like a domain ("github.com")
    ///  3. A macOS app, by name (with a few spoken-name aliases for the
    ///     ones whose app name doesn't match the obvious title-casing)
    ///  4. Fall back to a web search, so the command still does *something*
    ///     useful even if we can't resolve the target.
    ///
    /// This is always a FOREGROUND action — it activates the resulting
    /// app/window, because "mac chrome" / "launch zoom" mean "I want to see
    /// it now". For "get it ready in the background" use `webSearch(query,
    /// background: true)` instead (the "search for"/"google"/"look up"
    /// branch in executeVoiceCommand never calls this).
    ///
    /// `newWindow`, from a trailing "... new window" ("mac launch chrome new
    /// window"), launches a fresh instance via `open -n` instead of just
    /// activating whatever's already running. Only meaningful for the app
    /// branch — website aliases / bare domains go through NSWorkspace.open,
    /// which doesn't have an equivalent "force a new window" knob, so
    /// `newWindow` is a no-op there (typically opens as a new tab instead).
    ///
    /// `background`, from "mac prepare <target>", opens/launches the target
    /// WITHOUT activating it — the "Prepare" family's "get it ready, don't
    /// steal my focus" behavior. For an app this is `open -g`; for a
    /// website/search it's the same non-activating
    /// `NSWorkspace.OpenConfiguration` used by `webSearch(background:)`.
    private func openTarget(_ target: String, newWindow: Bool = false, background: Bool = false) {
        // "open -g" (background app launch) is supposed to avoid activating
        // the target — but for a COLD launch (app wasn't already running),
        // macOS activates the newly-created window anyway, regardless of
        // "-g". Snap focus back to whatever was frontmost before "prepare"
        // once the new app has had a moment to finish launching, so "Mac
        // prepare chrome" doesn't yank focus away from what you were doing.
        let previousFrontmost = background ? NSWorkspace.shared.frontmostApplication : nil
        defer {
            if let previousFrontmost = previousFrontmost {
                restoreFocus(to: previousFrontmost, after: 0.6)
            }
        }

        var words = target.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        while let first = words.first, words.count > 1, Self.openTargetFillerWords.contains(first) {
            words.removeFirst()
        }
        let trimmed = words.joined(separator: " ")
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()

        if let urlString = Self.websiteAliases[lower], let url = URL(string: urlString) {
            if background {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
                    if let error = error {
                        self?.appendLog("[LivePatch] COMMAND: open (background) \"\(trimmed)\" -> failed to open \(urlString): \(error)")
                    } else {
                        self?.appendLog("[LivePatch] COMMAND: open (background) \"\(trimmed)\" -> opened \(urlString)")
                    }
                }
            } else {
                NSWorkspace.shared.open(url)
                appendLog("[LivePatch] COMMAND: open \"\(trimmed)\" -> opened \(urlString)")
            }
            return
        }

        if lower.contains("."), !lower.contains(" ") {
            let urlString = lower.hasPrefix("http") ? lower : "https://\(lower)"
            if let url = URL(string: urlString) {
                if background {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
                        if let error = error {
                            self?.appendLog("[LivePatch] COMMAND: open (background) \"\(trimmed)\" -> failed to open \(urlString): \(error)")
                        } else {
                            self?.appendLog("[LivePatch] COMMAND: open (background) \"\(trimmed)\" -> opened \(urlString)")
                        }
                    }
                } else {
                    NSWorkspace.shared.open(url)
                    appendLog("[LivePatch] COMMAND: open \"\(trimmed)\" -> opened \(urlString)")
                }
                return
            }
        }

        let appName = Self.appAliases[lower] ?? trimmed
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // "-n" forces a new instance/window even if the app is already
        // running — that's the "new window" request. "-g" launches/activates
        // the app without bringing it to the front — that's "prepare".
        var arguments: [String] = []
        if background { arguments.append("-g") }
        if newWindow { arguments.append("-n") }
        arguments.append(contentsOf: ["-a", appName])
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                appendLog("[LivePatch] COMMAND: open \"\(trimmed)\" -> launched app \"\(appName)\"\(newWindow ? " (new window)" : "")\(background ? " (background)" : "")")
                return
            }
        } catch {
            // fall through to web search
        }

        appendLog("[LivePatch] COMMAND: open \"\(trimmed)\" -> not a known app/site, searching the web instead")
        webSearch(trimmed, background: background)
    }

    /// "search for <query>" / "google <query>" / "look up <query>" — opens
    /// a Google search for `query` in the default browser. Kept separate
    /// from the bare "search" command (which stays mapped to ⌘F /
    /// find-in-page).
    ///
    /// `background`, when true, opens the result tab WITHOUT activating the
    /// browser — i.e. it doesn't steal focus from whatever app you're
    /// currently in. This is the "get it ready, I'll deal with it later"
    /// half of the mac family: "mac search for X" / "mac look up Y" prepare
    /// a tab in the background; "mac chrome" / "switch to chrome" (which
    /// DOES activate, via `openTarget`) brings it to the front when you're
    /// ready to look. Uses NSWorkspace.OpenConfiguration(activates:) rather
    /// than the plain `open(_:)` convenience, which always activates.
    private func webSearch(_ query: String, background: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }

        if background {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
                if let error = error {
                    self?.appendLog("[LivePatch] COMMAND: web search (background) -> \"\(trimmed)\" failed: \(error)")
                } else {
                    self?.appendLog("[LivePatch] COMMAND: web search (background) -> \"\(trimmed)\"")
                }
            }
        } else {
            NSWorkspace.shared.open(url)
            appendLog("[LivePatch] COMMAND: web search -> \"\(trimmed)\"")
        }
    }

    /// Resolves and brings `target` to the front (via `openTarget`, same as
    /// bare "mac <target>"), then returns whatever app ended up frontmost.
    /// Used by "mac work with <target>" to get hold of the
    /// NSRunningApplication whose window should be moved into place.
    ///
    /// Polls `frontmostApplication` for up to ~1.5s, skipping over
    /// `excluding` (the app that was frontmost *before* this call — e.g.
    /// "left"). A single fixed 700ms sleep wasn't always enough for a
    /// browser to finish activating for a website target (gmail, etc.) —
    /// `frontmostApplication` would still read as the previous app, so
    /// "work with gmail" ended up reporting left == right == the app you
    /// were already in, and only that one window got repositioned.
    private func activateTargetAndGetApp(_ target: String, excluding: NSRunningApplication? = nil) -> NSRunningApplication? {
        openTarget(target)
        for _ in 0..<10 {
            usleep(150_000)
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let excluding = excluding, frontmost?.processIdentifier == excluding.processIdentifier {
                continue
            }
            return frontmost
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// Finds an already-running app matching a spoken `target` name, using
    /// the same alias table as `openTarget` (e.g. "chrome" -> "Google
    /// Chrome"), without launching anything. Used by "mac put away
    /// <target>" — putting something away only makes sense if it's
    /// already open.
    private func runningApp(named target: String) -> NSRunningApplication? {
        var words = target.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        while let first = words.first, words.count > 1, Self.openTargetFillerWords.contains(first) {
            words.removeFirst()
        }
        let trimmed = words.joined(separator: " ")
        guard !trimmed.isEmpty else { return nil }
        let appName = Self.appAliases[trimmed] ?? trimmed
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }
    }

    /// If `app` isn't frontmost after `delay` seconds, reactivates it. Used
    /// by `openTarget(background: true)` to undo a cold-launched app
    /// grabbing focus despite "-g" — see the comment at the top of
    /// `openTarget`.
    private func restoreFocus(to app: NSRunningApplication, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                app.activate(options: [.activateIgnoringOtherApps])
                self.appendLog("[LivePatch] prepare: restored focus to \(app.localizedName ?? "?")")
            }
        }
    }

    /// Which half of the screen a window should occupy.
    private enum ScreenSide {
        case left
        case right
    }

    /// Resizes and repositions `app`'s main window to fill the left or right
    /// half of the main screen — the "side by side, same size" half of the
    /// "Work Setup / Parallel Screen" family. Best-effort: if the app has no
    /// AX-visible main window (e.g. it's still launching), this just logs and
    /// does nothing.
    private func positionWindow(of app: NSRunningApplication?, side: ScreenSide) {
        guard let app = app else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // kAXMainWindowAttribute is sometimes empty for an app that isn't
        // currently frontmost (e.g. the "left" app, right after we've
        // activated "right" and moved on) even though it has a perfectly
        // good window — fall back to kAXFocusedWindowAttribute, then the
        // first entry of kAXWindowsAttribute, before giving up.
        var windowRef: CFTypeRef?
        var foundWindow = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef) == .success && windowRef != nil
        if !foundWindow {
            foundWindow = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success && windowRef != nil
        }
        if !foundWindow {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement], let first = windows.first {
                windowRef = first
                foundWindow = true
            }
        }
        guard foundWindow, let windowRef = windowRef else {
            appendLog("[LivePatch] split: no window found for \(app.localizedName ?? "?") yet — skipping")
            return
        }
        let axWindow = windowRef as! AXUIElement

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let halfWidth = visible.width / 2
        let cocoaX = side == .left ? visible.minX : visible.minX + halfWidth

        // AX window position/size use a top-left-origin coordinate space,
        // while NSScreen frames use bottom-left-origin — flip Y using the
        // full screen height.
        var position = CGPoint(x: cocoaX, y: screen.frame.height - visible.minY - visible.height)
        var size = CGSize(width: halfWidth, height: visible.height)

        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        appendLog("[LivePatch] split: positioned \(app.localizedName ?? "?") on the \(side == .left ? "left" : "right")")
    }

    /// Puts `left`'s window on the left half of the screen and `right`'s on
    /// the right half, same size — "Mac work with <X>" / "Mac split <A> and
    /// <B>" / "Mac parallel work".
    private func positionSideBySide(left: NSRunningApplication?, right: NSRunningApplication?) {
        positionWindow(of: left, side: .left)
        positionWindow(of: right, side: .right)
    }

    /// The core "smart suggestion" check, ported from the LivePatch
    /// extension's pickBestCandidate/applyPatch. v0.1: rather than only
    /// looking at the word at/before the text cursor (which misses typos
    /// the cursor isn't sitting next to), scan every "suspicious" word in
    /// the WHOLE focused field — same tokenization the extension's
    /// detectSuspicious uses ([A-Za-z']+, length >= 3, not a stopword) —
    /// and pick the single best similarity match against the heard phrase.
    private func processLiveHeardPhrase(_ phrase: String) {
        let wc = CandidateEngine.wordCount(phrase)
        guard wc > 0 else { return }

        // Volume gate: if the peak audio during this phrase was below the
        // threshold, it's probably ambient noise, not intentional speech.
        if !speechCapture.isAboveVolumeGate && speechCapture.sessionPeakPower < speechCapture.volumeGateThreshold {
            trackStat("volume_gate_rejections"); appendLog("[LivePatch] VOLUME GATE: \"\(phrase)\" rejected — peak \(String(format: "%.1f", speechCapture.sessionPeakPower)) dB below threshold \(String(format: "%.1f", speechCapture.volumeGateThreshold)) dB")
            return
        }

        // Voice commands: checked FIRST, and before any AX read. Commands
        // (starting with "paste") are implemented via synthetic keyboard
        // events rather than AX text read/write, so — unlike the
        // similarity-based correction below — they work in apps where AX
        // text access is blocked entirely (Chrome, Claude desktop / other
        // Electron apps -> AXError -25212). This is the start of porting the
        // extension's broader command set (paste, etc.) to those apps.
        if executeVoiceCommand(phrase) {
            captureLog("CMD_OK: \"\(phrase)\"")
            trackStat("commands_fired")
            trackAppCommand(phrase.lowercased())
            if !phrase.lowercased().hasPrefix("capture") {
                lastCommandHeard = phrase
            }
            return
        }

        // Fuzzy command match: if the phrase is close to a known command,
        // treat it as that command instead of a correction attempt.
        let allCommandKeys = Array(Self.directCommands.keys) + Array(Self.commands.keys)
        if let fuzzy = CandidateEngine.bestCommandMatch(for: phrase, in: allCommandKeys) {
            trackStat("commands_fuzzy_matched"); captureLog("FUZZY: \"\(phrase)\" → \"\(fuzzy.command)\" (sim=\(String(format: "%.2f", fuzzy.similarity)))")
            appendLog("[LivePatch] FUZZY COMMAND: heard \"\(phrase)\" → matched \"\(fuzzy.command)\" (sim=\(String(format: "%.2f", fuzzy.similarity)))")
            if executeVoiceCommand(fuzzy.command) {
                lastCommandHeard = fuzzy.command
                return
            }
        }

        captureLog("NOT_CMD: \"\(phrase)\" — trying correction")

        guard wc <= CandidateEngine.speechMaxWords else {
            captureLog("TOO_LONG: \"\(phrase)\" (\(wc) words)")
            appendLog("[LivePatch] ignored \"\(phrase)\" (\(wc) words > \(CandidateEngine.speechMaxWords) — likely not a correction)")
            return
        }

        // Check adaptive corrections first — user already approved this mapping
        if let adaptiveReplacement = applyAdaptiveCorrection(for: phrase) {
            appendLog("[Adaptive] AUTO-CORRECT: \"\(phrase)\" → \"\(adaptiveReplacement)\" (user-approved)")
            captureLog("ADAPTIVE: \"\(phrase)\" → \"\(adaptiveReplacement)\"")
            // Re-run with the corrected phrase
            processLiveHeardPhrase(adaptiveReplacement)
            return
        }

        switch AccessibilityInspector.currentValueAndCursor(targetApp: lastExternalApp) {
        case .failure(let msg):
            captureLog("AX_FAIL: \(msg)")
            appendLog("[LivePatch] could not read focused field: \(msg)")
            let appName = lastExternalApp?.localizedName ?? "this app"
            trackAppCorrection(app: appName, success: false)
            // Notify user that correction doesn't work here — offer support path
            let failKey = "ax_fail_\(appName)"
            let failCount = (sessionStats[failKey] ?? 0) + 1
            sessionStats[failKey] = failCount
            if failCount == 1 {
                notify("Voice corrections not available in \(appName)", "Commands still work. Say \"mac support\" to request \(appName) support.")
            } else if failCount == 5 {
                notify("\(appName) doesn't support text corrections yet", "Say \"mac support\" to send a report — we'll work on adding it.")
            }
        case .success(let info):
            let nsValue = info.text as NSString

            guard let match = CandidateEngine.bestMatch(in: nsValue, for: phrase, cursorLoc: info.cursorLoc) else {
                trackStat("corrections_low_confidence"); appendLog("[LivePatch] LOW_CONFIDENCE: heard \"\(phrase)\" — no word in field cleared the similarity floor — no patch.")
                return
            }
            let word = match.candidate.text
            let range = match.candidate.range
            let sim = match.similarity

            // Track this correction for adaptive learning
            trackMismatch(heard: phrase, correctedTo: word)

            // Re-snapshot the field right before writing. Between when this
            // phrase started settling (~phraseSettleDelay ago) and now, the
            // user may have kept typing — shifting/changing the text at
            // `range`. Writing against a stale range in that case can clobber
            // characters the user just typed (reported: correcting a word
            // then immediately continuing to type ate the next word). If the
            // text at `range` no longer reads exactly as `word`, bail out.
            var userCursor: Int
            switch AccessibilityInspector.currentValueAndCursor(targetApp: lastExternalApp) {
            case .failure(let msg):
                appendLog("[LivePatch] could not re-check focused field before writing: \(msg) — no patch.")
                return
            case .success(let freshInfo):
                let freshValue = freshInfo.text as NSString
                guard range.location + range.length <= freshValue.length,
                      freshValue.substring(with: range) == word else {
                    appendLog("[LivePatch] STALE: field changed since \"\(word)\" was found (likely still typing) — skipped to avoid clobbering.")
                    return
                }
                userCursor = freshInfo.cursorLoc
            }

            let replacement = CandidateEngine.matchCase(word, phrase)
            let replacementNS = replacement as NSString

            // Mid-flow correction: the word being patched is often BEHIND
            // where the user is currently typing (they spoke a correction
            // for something a few words back while continuing forward).
            // `replaceRange` collapses the cursor to right after the patched
            // word, which would yank the user's typing cursor backward. So:
            // figure out where the user's cursor SHOULD end up relative to
            // the patch, and explicitly restore it afterward.
            //   - cursor at/after the end of the patched range: it shifts by
            //     the length delta (chars added/removed by the patch).
            //   - cursor at/before the start of the patched range: unaffected.
            //   - cursor inside the patched range: snap to just after the
            //     replacement (the word it was "inside" no longer exists).
            let delta = replacementNS.length - range.length
            let restoreCursor: Int
            if userCursor >= range.location + range.length {
                restoreCursor = userCursor + delta
            } else if userCursor <= range.location {
                restoreCursor = userCursor
            } else {
                restoreCursor = range.location + replacementNS.length
            }

            appendLog("[LivePatch] PATCH \"\(word)\" -> \"\(replacement)\" (sim=\(String(format: "%.2f", sim)))")
            let result = AccessibilityInspector.replaceRange(range, with: replacement, expectedOriginal: word, targetApp: lastExternalApp)
            switch result {
            case .success(let detail):
                trackStat("corrections_made")
                correctionTimestamps.append(Date())
                trackAppCorrection(app: lastExternalApp?.localizedName ?? "unknown", success: true)
                captureLog("CORRECTED: \"\(word)\" → \"\(replacement)\" (sim=\(String(format: "%.2f", sim)))")
                appendLog("[LivePatch] WRITE SUCCESS: \(detail)")
                if restoreCursor != range.location + replacementNS.length {
                    switch AccessibilityInspector.setCursor(restoreCursor, targetApp: lastExternalApp) {
                    case .success:
                        appendLog("[LivePatch] cursor restored to \(restoreCursor) (mid-flow correction).")
                    case .failure(let msg):
                        appendLog("[LivePatch] could not restore cursor: \(msg)")
                    }
                }
            case .failure(let msg):
                appendLog("[LivePatch] WRITE FAILED: \(msg)")
            }
        }
    }

    @objc func showLastInspection() {
        let alert = NSAlert()
        alert.messageText = "Last Focused Element Inspection"
        alert.informativeText = lastInspectionSummary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Logging

    private static let maxLogSize = 1_000_000 // 1 MB

    private func appendLog(_ line: String) {
        let stamped = "[SpeakUp] \(line)\n"
        print(stamped, terminator: "")
        if let data = stamped.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                // Rotate if over 1 MB
                if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                   let size = attrs[.size] as? Int, size > Self.maxLogSize {
                    let archiveURL = logURL.deletingPathExtension().appendingPathExtension("old.txt")
                    try? FileManager.default.removeItem(at: archiveURL)
                    try? FileManager.default.moveItem(at: logURL, to: archiveURL)
                }
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: logURL)
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    // MARK: - Notifications

    /// Posts a top-right banner via NSUserNotificationCenter so every
    /// recognized voice command leaves a visible trail — "Heard X -> did Y"
    /// — not just a log line. This is the "collaborator feedback" loop:
    /// commands should always talk back, even (especially) when they're
    /// rejected or not recognized.
    ///
    /// NSUserNotification is deprecated in favor of UNUserNotificationCenter,
    /// but UNUserNotificationCenter requires an async authorization request
    /// (another permission prompt, on top of Accessibility + Microphone +
    /// Automation that this PoC already juggles every rebuild).
    /// NSUserNotification still posts banners for unsandboxed apps without
    /// that extra prompt, which matters a lot for iteration speed here. If
    /// banners stop appearing on a future macOS version, that's the trigger
    /// to migrate to UNUserNotificationCenter and eat the one-time
    /// authorization prompt.
    private func notify(_ title: String, _ body: String? = nil) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }

    /// Speak a short confirmation out loud — one or two words only.
    /// Non-blocking: fires and forgets via `say` so it never stalls the main thread.
    private func speak(_ text: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = [text]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
    }

    // MARK: - Adaptive Corrections (pattern tracking + user-approved fixes)

    private func loadAdaptiveCorrections() {
        guard let data = try? Data(contentsOf: approvedCorrectionsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            approvedCorrections = [:]
            return
        }
        approvedCorrections = dict
        if !dict.isEmpty {
            appendLog("[Adaptive] Loaded \(dict.count) approved correction(s)")
        }
    }

    private func saveAdaptiveCorrections() {
        try? FileManager.default.createDirectory(at: approvedCorrectionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: approvedCorrections, options: [.prettyPrinted]) {
            try? data.write(to: approvedCorrectionsURL)
        }
    }

    func applyAdaptiveCorrection(for heard: String) -> String? {
        return approvedCorrections[heard.lowercased()]
    }

    func trackMismatch(heard: String, correctedTo: String) {
        let key = heard.lowercased()
        let intended = correctedTo.lowercased()
        guard key != intended else { return }
        if approvedCorrections[key] != nil { return }

        if let existing = mismatchTracker[key], existing.intended == intended {
            mismatchTracker[key] = (intended, existing.count + 1)
            if existing.count + 1 >= 3 {
                promptAdaptiveCorrection(heard: key, intended: intended)
                mismatchTracker.removeValue(forKey: key)
            }
        } else {
            mismatchTracker[key] = (intended, 1)
        }
    }

    private func promptAdaptiveCorrection(heard: String, intended: String) {
        let quality = sessionQuality
        if quality == "degraded" {
            appendLog("[Adaptive] BLOCKED: \"\(heard)\" → \"\(intended)\" — session quality: \(quality) (late night + high errors). Won't learn from this.")
            return
        }
        if quality == "fatigued" {
            appendLog("[Adaptive] DELAYED: \"\(heard)\" → \"\(intended)\" — session quality: \(quality). Will re-check next session.")
            return
        }

        pendingAdaptivePrompt = (heard, intended)
        trackStat("adaptive_prompts_shown"); appendLog("[Adaptive] Prompting: \"\(heard)\" → \"\(intended)\" (3+ occurrences, quality: \(quality))")
        notify("SpeakUp noticed a pattern", "You correct \"\(heard)\" to \"\(intended)\" often. Say \"yes\" or click to approve.")
    }

    func handleAdaptiveResponse(approved: Bool) {
        guard let prompt = pendingAdaptivePrompt else { return }
        if approved {
            approvedCorrections[prompt.heard] = prompt.intended
            saveAdaptiveCorrections()
            trackStat("adaptive_approved"); appendLog("[Adaptive] APPROVED: \"\(prompt.heard)\" → \"\(prompt.intended)\" — saved")
            notify("SpeakUp learned", "\"\(prompt.heard)\" will now auto-correct to \"\(prompt.intended)\"")
            speak("Learned")
        } else {
            trackStat("adaptive_rejected"); appendLog("[Adaptive] REJECTED: \"\(prompt.heard)\" → \"\(prompt.intended)\"")
        }
        pendingAdaptivePrompt = nil
    }

    // MARK: - Product Intelligence (anonymous usage signals)

    func trackStat(_ key: String) {
        sessionStats[key] = (sessionStats[key] ?? 0) + 1
    }

    func trackAppCommand(_ command: String) {
        let app = lastExternalApp?.localizedName ?? "unknown"
        if appCommandCounts[app] == nil { appCommandCounts[app] = [:] }
        appCommandCounts[app]![command] = (appCommandCounts[app]![command] ?? 0) + 1
    }

    private func saveUsageStats() {
        var stats: [String: Any] = sessionStats as [String: Any]
        stats["app_command_usage"] = appCommandCounts
        stats["total_adaptive_corrections"] = approvedCorrections.count
        stats["session_end"] = ISO8601DateFormatter().string(from: Date())
        stats["session_start"] = ISO8601DateFormatter().string(from: sessionStartTime)
        stats["session_duration_minutes"] = Int(Date().timeIntervalSince(sessionStartTime) / 60)
        stats["session_quality_at_end"] = sessionQuality
        stats["avg_memory_mb"] = cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count)
        stats["peak_memory_mb"] = cpuSamples.max() ?? 0
        stats["correction_count_last_5min"] = correctionTimestamps.filter { Date().timeIntervalSince($0) < 300 }.count
        try? FileManager.default.createDirectory(at: statsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted]) {
            try? data.write(to: statsURL)
        }
        appendLog("[Stats] Session stats saved — \(sessionStats["commands_fired"] ?? 0) commands, \(sessionStats["corrections_made"] ?? 0) corrections")
    }

    func applicationWillTerminate(_ notification: Notification) {
        cpuSampleTimer?.invalidate()
        saveUsageStats()
        saveAppProfiles()
    }

    private func startCPUSampling() {
        cpuSampleTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cpu = self.getProcessCPU()
            self.cpuSamples.append(cpu)
            if self.cpuSamples.count > 120 { self.cpuSamples.removeFirst() } // keep last 60 min
        }
    }

    private func getProcessCPU() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576 // MB
    }

    // MARK: - App Environment Profiles

    private var appProfiles: [String: [String: Any]] = [:]
    private let appProfilesURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/app-profiles.json")

    func trackAppEnvironment() {
        guard let app = lastExternalApp else { return }
        let name = app.localizedName ?? "unknown"
        let bundleId = app.bundleIdentifier ?? "unknown"
        let family = AccessibilityInspector.detectAppFamily(for: app)

        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.trackAppEnvironment() }
            return
        }

        if appProfiles[name] == nil {
            appProfiles[name] = [
                "bundle_id": bundleId,
                "app_family": family.rawValue,
                "first_seen": ISO8601DateFormatter().string(from: Date()),
                "ax_supported": false,
                "ax_tested": false,
                "commands_used": [String: Int](),
                "corrections_made": 0,
                "corrections_failed": 0,
            ]
            appendLog("[AppProfile] New app: \(name) — \(AccessibilityInspector.appFamilyDescription(family))")
        }

        // Test AX support if we haven't yet
        if appProfiles[name]?["ax_tested"] as? Bool == false {
            switch AccessibilityInspector.currentValueAndCursor(targetApp: lastExternalApp) {
            case .success:
                appProfiles[name]?["ax_supported"] = true
                appProfiles[name]?["ax_tested"] = true
                appendLog("[AppProfile] \(name): AX supported")
            case .failure:
                appProfiles[name]?["ax_supported"] = false
                appProfiles[name]?["ax_tested"] = true
                appendLog("[AppProfile] \(name): AX not supported — commands only, no corrections")
            }
        }
    }

    func trackAppCorrection(app: String, success: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if success {
                self.appProfiles[app]?["corrections_made"] = ((self.appProfiles[app]?["corrections_made"] as? Int) ?? 0) + 1
            } else {
                self.appProfiles[app]?["corrections_failed"] = ((self.appProfiles[app]?["corrections_failed"] as? Int) ?? 0) + 1
            }
        }
    }

    private func loadAppProfiles() {
        guard let data = try? Data(contentsOf: appProfilesURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        appProfiles = dict
        appendLog("[AppProfile] Loaded profiles for \(dict.count) app(s)")
    }

    private func saveAppProfiles() {
        try? FileManager.default.createDirectory(at: appProfilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: appProfiles, options: [.prettyPrinted]) {
            try? data.write(to: appProfilesURL)
        }
    }

    // MARK: - Technical Support (quick report submission)

    private func sendTechnicalSupport() {
        let statsData = try? Data(contentsOf: statsURL)
        let statsText = statsData.flatMap { String(data: $0, encoding: .utf8) } ?? "no stats"

        let capturesDir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/captures")
        let recentCaptures = (try? FileManager.default.contentsOfDirectory(atPath: capturesDir.path))?
            .sorted().suffix(3).joined(separator: ", ") ?? "none"

        let logLines: [String]
        if let data = try? Data(contentsOf: logURL),
           let logText = String(data: data, encoding: .utf8) {
            logLines = Array(logText.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(20))
        } else {
            logLines = ["no log"]
        }

        let supportDir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/support")
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        let id = UUID().uuidString.prefix(8)
        let filename = "support-\(id).txt"
        let fileURL = supportDir.appendingPathComponent(filename)

        // Auto-include last capture if one was just taken
        var lastCaptureContent = ""
        if let capturePath = lastCaptureFilePath,
           let captureData = try? String(contentsOfFile: capturePath, encoding: .utf8) {
            lastCaptureContent = captureData
        }

        var content = "SpeakUp Technical Support Report\n"
        content += "================================\n"
        content += "Date: \(ISO8601DateFormatter().string(from: Date()))\n"
        content += "App: \(lastExternalApp?.localizedName ?? "unknown")\n"
        content += "App family: \(AccessibilityInspector.detectAppFamily(for: lastExternalApp).rawValue)\n"
        content += "LiveMode: \(liveModeOn ? "ON" : "OFF")\n"
        content += "Session quality: \(sessionQuality)\n"
        content += "Session duration: \(Int(Date().timeIntervalSince(sessionStartTime) / 60)) min\n"
        content += "Memory: \(String(format: "%.1f", cpuSamples.last ?? 0)) MB\n\n"

        if !lastCaptureContent.isEmpty {
            content += "--- ATTACHED CAPTURE (most recent) ---\n\(lastCaptureContent)\n\n"
        }

        content += "--- Recent Captures ---\n\(recentCaptures)\n\n"
        content += "--- Last 20 Log Lines ---\n\(logLines.joined(separator: "\n"))\n\n"
        content += "--- Session Stats ---\n\(statsText)\n\n"
        content += "--- Adaptive Corrections ---\n\(approvedCorrections.count) approved\n"
        for (heard, intended) in approvedCorrections {
            content += "  \"\(heard)\" → \"\(intended)\"\n"
        }
        content += "\n--- App Profiles ---\n"
        for (app, profile) in appProfiles {
            let family = profile["app_family"] as? String ?? "unknown"
            let axOK = profile["ax_supported"] as? Bool ?? false
            let cmds = profile["corrections_made"] as? Int ?? 0
            let fails = profile["corrections_failed"] as? Int ?? 0
            content += "  \(app) [\(family)] AX:\(axOK ? "yes" : "no") corrections:\(cmds) failed:\(fails)\n"
        }

        try? content.data(using: .utf8)?.write(to: fileURL)

        // Try to open Mail with a draft email and the report attached
        let emailBody = appleScriptEscape("Hi SpeakUp support,\\n\\nPlease find my support report attached.\\n\\nThanks")
        let filePath = appleScriptEscape(fileURL.path)
        let mailScript = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:"SpeakUp Support Report — \(id)", content:"\(emailBody)", visible:true}
            tell newMsg
                make new to recipient at end of to recipients with properties {address:"martyadiaz@gmail.com"}
                tell content
                    make new attachment with properties {file name:POSIX file "\(fileURL.path)"} at after the last paragraph
                end tell
            end tell
            activate
        end tell
        """
        let mailProc = Process()
        mailProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        mailProc.arguments = ["-e", mailScript]
        mailProc.standardOutput = FileHandle.nullDevice
        mailProc.standardError = FileHandle.nullDevice

        do {
            try mailProc.run()
            mailProc.waitUntilExit()
            if mailProc.terminationStatus == 0 {
                notify("Support email drafted", "Mail opened with your report attached. Review and send.")
                speak("Email ready")
            } else {
                // Mail failed — fall back to showing the file
                NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
                notify("Support report saved", "Mail couldn't open. Report saved at:\n\(fileURL.path)\nEmail to martyadiaz@gmail.com")
                speak("Support saved")
            }
        } catch {
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
            notify("Support report saved", "Report saved. Email to martyadiaz@gmail.com")
            speak("Support saved")
        }
        appendLog("[Support] Report saved: \(filename)")
    }

    // MARK: - Capture Window (live diagnostic recording)

    func captureLog(_ entry: String) {
        guard captureWindowActive else { return }
        let ts = String(format: "%.2f", Date().timeIntervalSince(captureWindowStart ?? Date()))
        captureWindowLog.append("[\(ts)s] \(entry)")
    }

    private func startCaptureWindow(kind: String, description: String) {
        captureWindowActive = true
        captureWindowStart = Date()
        captureWindowLog = []
        captureLog("CAPTURE START: \(kind) — \"\(description)\"")
        captureLog("Active app: \(lastExternalApp?.localizedName ?? "unknown")")
        captureLog("LiveMode: \(liveModeOn ? "ON" : "OFF")")
        captureLog("Volume gate threshold: \(speechCapture.volumeGateThreshold) dB")

        if let info = try? AccessibilityInspector.currentValueAndCursor(targetApp: lastExternalApp).get() {
            let preview = String(info.text.prefix(100))
            captureLog("Focused field: \"\(preview)\" cursor@\(info.cursorLoc)")
        } else {
            captureLog("Focused field: not readable")
        }

        speak("Capturing")
        notify("Capture started", "Recording for 15 seconds. Use SpeakUp normally.")
        trackStat("captures_started"); appendLog("[Capture] Window opened — \(kind): \"\(description)\"")

        captureWindowTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.endCaptureWindow(kind: kind, description: description)
        }
    }

    private func endCaptureWindow(kind: String, description: String) {
        captureWindowActive = false
        captureWindowTimer?.invalidate()
        captureWindowTimer = nil
        captureLog("CAPTURE END — \(captureWindowLog.count) events recorded")

        let capturesDir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SpeakUp/captures")
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        let id = UUID().uuidString.prefix(8)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "capture-\(kind)-\(id).txt"
        let fileURL = capturesDir.appendingPathComponent(filename)

        var content = "SpeakUp Capture Report\n"
        content += "======================\n"
        content += "Type: \(kind)\n"
        content += "Description: \(description)\n"
        content += "Timestamp: \(timestamp)\n"
        content += "Session quality: \(sessionQuality)\n"
        content += "Duration: 15 seconds\n"
        content += "Events: \(captureWindowLog.count)\n"
        content += "App: \(lastExternalApp?.localizedName ?? "unknown")\n"
        content += "App family: \(AccessibilityInspector.detectAppFamily(for: lastExternalApp).rawValue)\n"
        content += "Memory: \(String(format: "%.1f", cpuSamples.last ?? 0)) MB\n\n"
        content += captureWindowLog.joined(separator: "\n")
        content += "\n"

        try? content.data(using: .utf8)?.write(to: fileURL)
        lastCaptureFilePath = fileURL.path

        speak("Captured")
        notify("Capture saved — say \"mac support\" to send it", "\(captureWindowLog.count) events recorded")
        appendLog("[Capture] Saved \(captureWindowLog.count) events to \(filename)")
    }
}

private extension NSMenu {
    func addItem(withAction title: String, selector: Selector, target: AnyObject, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target
        addItem(item)
    }
}
