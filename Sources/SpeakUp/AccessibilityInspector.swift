import Cocoa
import ApplicationServices

// Allows using plain String values as lightweight error messages in Result<>.
extension String: Error {}

struct FocusedElementInfo {
    let appName: String
    let bundleID: String?
    let role: String?
    let subrole: String?
    let title: String?
    let value: String?
    let placeholder: String?
    let numberOfCharacters: Int?
    let selectedTextRange: String?
    let isValueSettable: Bool
    let actions: [String]

    var summary: String {
        """
        App: \(appName) (\(bundleID ?? "?"))
        Role: \(role ?? "?")  Subrole: \(subrole ?? "-")
        Title: \(title ?? "-")
        Placeholder: \(placeholder ?? "-")
        #Characters: \(numberOfCharacters.map(String.init) ?? "-")
        Selected Range: \(selectedTextRange ?? "-")
        Value Settable: \(isValueSettable)
        Actions: \(actions.joined(separator: ", "))
        Value (truncated): \(FocusedElementInfo.truncate(value))
        """
    }

    static func truncate(_ s: String?) -> String {
        guard let s = s else { return "-" }
        if s.count > 200 {
            return String(s.prefix(200)) + "…"
        }
        return s
    }
}

enum AccessibilityInspector {

    /// Returns whether this process is trusted for Accessibility.
    /// If `promptIfNeeded` is true and not trusted, macOS shows the
    /// "App would like to control this computer" system prompt.
    ///
    /// AXIsProcessTrustedWithOptions caches its result per-process — once
    /// the app has been trusted, it keeps returning true even after the user
    /// removes it from System Settings → Accessibility, until the app restarts.
    /// We bypass the cache by making a real AX API call and checking the error
    /// code: kAXErrorNotTrusted (-25211) means genuinely not trusted right now.
    /// Any other result (success, noValue, etc.) means we ARE trusted.
    // MARK: - App Family Detection

    enum AppFamily: String {
        case native = "native"           // Apple-native apps, full AX
        case electron = "electron"       // VS Code, Slack, Discord, Claude desktop
        case adobe = "adobe"             // Photoshop, Illustrator, etc
        case chromium = "chromium"       // Chrome, Edge, Brave — browser fields
        case java = "java"              // Java/Swing enterprise apps
        case unknown = "unknown"
    }

    static func detectAppFamily(for app: NSRunningApplication?) -> AppFamily {
        guard let bundleId = app?.bundleIdentifier else { return .unknown }
        let bid = bundleId.lowercased()

        if bid.hasPrefix("com.apple.") { return .native }

        if bid.contains("adobe") || bid.contains("photoshop") || bid.contains("illustrator")
            || bid.contains("indesign") || bid.contains("premiere") || bid.contains("aftereffects") {
            return .adobe
        }

        if bid.contains("google.chrome") || bid.contains("brave") || bid.contains("microsoft.edgemac")
            || bid.contains("arc") || bid.contains("vivaldi") || bid.contains("opera") {
            return .chromium
        }

        // Electron detection: check for Electron Helper in running processes
        // or known Electron bundle IDs
        if bid.contains("vscode") || bid.contains("visual-studio-code")
            || bid.contains("slack") || bid.contains("discord")
            || bid.contains("anthropic") || bid.contains("notion")
            || bid.contains("figma") || bid.contains("spotify")
            || bid.contains("teams") || bid.contains("whatsapp")
            || bid.contains("atom") || bid.contains("postman") {
            return .electron
        }

        // Java detection
        if bid.contains("java") || bid.contains("jetbrains")
            || bid.contains("intellij") || bid.contains("eclipse") {
            return .java
        }

        return .native  // default: try native AX
    }

    static func appFamilyDescription(_ family: AppFamily) -> String {
        switch family {
        case .native: return "Native macOS (full support)"
        case .electron: return "Electron app (commands work, corrections limited)"
        case .adobe: return "Adobe app (commands work, corrections limited)"
        case .chromium: return "Browser (commands work, web field corrections vary)"
        case .java: return "Java app (commands work, corrections limited)"
        case .unknown: return "Unknown framework"
        }
    }

    static func isTrusted(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            // Trigger the system prompt if needed — but ignore the cached return value.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            _ = AXIsProcessTrustedWithOptions([key: true] as NSDictionary)
        }
        // Live probe: hits the AX server directly, not the per-process cache.
        // kAXErrorNotTrusted = -25211 (not bridged as a Swift enum case).
        // Use CopyAttributeNames on the system-wide element — always returns
        // names when trusted regardless of whether any app has focus, so we
        // don't get false-positives from kAXErrorNoValue on an empty focus state.
        let systemWide = AXUIElementCreateSystemWide()
        var names: CFArray?
        let err = AXUIElementCopyAttributeNames(systemWide, &names)
        return err.rawValue != -25211
    }

    /// Chromium-based apps (Chrome, and Electron apps like Claude desktop)
    /// normally only build their full accessibility tree when they detect
    /// an assistive technology like VoiceOver running. SpeakUp isn't
    /// VoiceOver, so without this their AX tree can be empty/unreachable —
    /// the "AXError -25212" / "no focused UI element" failures seen for
    /// Chrome and Claude desktop. `AXManualAccessibility` is a known (if
    /// semi-undocumented) attribute that tells Chromium to populate its AX
    /// tree for any client that sets it. Best-effort + idempotent: failures
    /// are silently ignored, since most apps don't implement this attribute
    /// at all (and don't need to).
    private static func enableManualAccessibilityIfNeeded(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Resolves the focused UI element + owning app, given an (optional)
    /// target app override. Shared by inspect and write paths.
    private static func resolveFocusedElement(targetApp: NSRunningApplication?) -> Result<(AXUIElement, NSRunningApplication), String> {
        guard isTrusted(promptIfNeeded: false) else {
            return .failure("Accessibility permission not granted. Open System Settings > Privacy & Security > Accessibility and enable SpeakUp.")
        }

        // Give Chromium-based apps a chance to turn on their AX tree before
        // we go looking for a focused element in them. AXManualAccessibility
        // tells Chrome's renderer to start building its accessibility tree,
        // but that build is ASYNC — the very first lookup right after
        // setting it can still come back AXError -25212 (no focused
        // element) while the tree is still being constructed. Retry a few
        // times with short delays before giving up, but only for
        // Chromium/Electron-style apps (bundle IDs containing "chrome",
        // "chromium", or "electron") where this delay is the known cause —
        // for everything else, a missing focused element is a real,
        // immediate failure and we shouldn't add latency to every lookup.
        var isChromiumLike = false
        if let target = targetApp {
            enableManualAccessibilityIfNeeded(for: target)
            if let bid = target.bundleIdentifier?.lowercased(),
               bid.contains("chrome") || bid.contains("chromium") || bid.contains("electron") {
                isChromiumLike = true
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            enableManualAccessibilityIfNeeded(for: front)
            if let bid = front.bundleIdentifier?.lowercased(),
               bid.contains("chrome") || bid.contains("chromium") || bid.contains("electron") {
                isChromiumLike = true
            }
        }
        let focusLookupAttempts = isChromiumLike ? 4 : 1
        let focusLookupDelay: useconds_t = 150_000 // 150ms

        // Fallback target app for the app-element-based lookup below, and
        // for the error message if everything fails.
        let frontApp = targetApp ?? NSWorkspace.shared.frontmostApplication

        var lastErr: AXError = .failure
        for attempt in 1...focusLookupAttempts {
            // Prefer the SYSTEM-WIDE focused element: this reflects the OS's
            // actual current keyboard focus, independent of NSWorkspace
            // activation tracking — which is what we use for `lastExternalApp`,
            // and which never fires for overlays like Spotlight. If this works,
            // it's correct everywhere, including the cases lastExternalApp misses.
            let systemWide = AXUIElementCreateSystemWide()
            var systemFocusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &systemFocusedRef) == .success,
               let raw = systemFocusedRef {
                let element = raw as! AXUIElement
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success,
                   let app = NSRunningApplication(processIdentifier: pid) {
                    return .success((element, app))
                }
                // Got an element but couldn't resolve its owning app — still
                // fall through to the targetApp-based path below.
            }

            // Fallback: use the tracked external app (or frontmost) and ask
            // IT for its focused element.
            guard let frontApp = frontApp else {
                return .failure("Could not determine target application.")
            }

            let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

            var focusedElementRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

            if err == .success, let raw = focusedElementRef {
                let element = raw as! AXUIElement
                return .success((element, frontApp))
            }

            lastErr = err
            if attempt < focusLookupAttempts {
                usleep(focusLookupDelay)
            }
        }

        guard let frontApp = frontApp else {
            return .failure("Could not determine target application.")
        }
        let attemptsNote = focusLookupAttempts > 1 ? " after \(focusLookupAttempts) attempts (AXManualAccessibility delay)" : ""
        return .failure("No focused UI element reported by \(frontApp.localizedName ?? "frontmost app") (AXError \(lastErr.rawValue))\(attemptsNote).")
    }

    /// Inspects whatever UI element currently has keyboard focus in
    /// `targetApp`. If `targetApp` is nil, falls back to whatever is
    /// currently frontmost (which, if called from a menu click, will
    /// usually be SpeakUp itself — not useful).
    static func inspectFocusedElement(targetApp: NSRunningApplication? = nil) -> Result<FocusedElementInfo, String> {
        let resolved: (AXUIElement, NSRunningApplication)
        switch resolveFocusedElement(targetApp: targetApp) {
        case .success(let r): resolved = r
        case .failure(let msg): return .failure(msg)
        }
        let (element, frontApp) = resolved

        let role = copyStringAttribute(element, kAXRoleAttribute)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute)
        let title = copyStringAttribute(element, kAXTitleAttribute)
        let value = copyStringAttribute(element, kAXValueAttribute)
        let placeholder = copyStringAttribute(element, kAXPlaceholderValueAttribute)

        var numChars: Int? = nil
        var numRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &numRef) == .success {
            if let n = numRef as? Int {
                numChars = n
            } else if let n = numRef as? NSNumber {
                numChars = n.intValue
            }
        }

        var selectedRangeDesc: String? = nil
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) {
                selectedRangeDesc = "loc \(range.location), len \(range.length)"
            }
        }

        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable)

        var actionNamesRef: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionNamesRef) == .success,
           let names = actionNamesRef as? [String] {
            actions = names
        }

        return .success(FocusedElementInfo(
            appName: frontApp.localizedName ?? "Unknown",
            bundleID: frontApp.bundleIdentifier,
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            placeholder: placeholder,
            numberOfCharacters: numChars,
            selectedTextRange: selectedRangeDesc,
            isValueSettable: isSettable.boolValue,
            actions: actions
        ))
    }

    /// Inserts `text` at the current cursor position (or replaces the
    /// current selection) in the focused element of `targetApp`.
    ///
    /// Tries the "AXSelectedText" path first — this goes through the app's
    /// normal text system and is usually undoable with Cmd+Z. Falls back to
    /// splicing the full AXValue string directly, which works more broadly
    /// but may NOT be undoable in every app.
    static func insertTextAtCursor(_ text: String, targetApp: NSRunningApplication? = nil) -> Result<String, String> {
        let resolved: (AXUIElement, NSRunningApplication)
        switch resolveFocusedElement(targetApp: targetApp) {
        case .success(let r): resolved = r
        case .failure(let msg): return .failure(msg)
        }
        let (element, _) = resolved

        // Determine whether this will be an INSERT (empty selection) or a
        // REPLACE (non-empty selection), and what's about to be replaced —
        // this is "Test A" vs "Test B" from the user's perspective. Also
        // remember the selection's start location so we can re-collapse the
        // cursor to just after the inserted text afterward — some apps
        // (TextEdit, Stickies) leave AXSelectedText's replacement selected
        // with the anchor at its START, which visually looks like the
        // cursor "jumped back" in front of the new word.
        var mode = "INSERT"
        var replacedText: String? = nil
        var selectionStart = 0
        var rangeRef0: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef0) == .success,
           let rv = rangeRef0 {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue((rv as! AXValue), .cfRange, &range) {
                selectionStart = range.location
                if range.length > 0 {
                    mode = "REPLACE"
                    var selTextRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selTextRef) == .success,
                       let s = selTextRef as? String {
                        replacedText = s
                    }
                }
            }
        }
        let modeDesc = mode == "REPLACE"
            ? "REPLACE selected text \(replacedText.map { "\"\($0)\"" } ?? "(unknown)")"
            : "INSERT at cursor"

        // --- Path 1: AXSelectedText (preferred — goes through text system / undo) ---
        var selectedTextSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        if selectedTextSettable.boolValue {
            let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if setErr == .success {
                // Re-collapse the cursor to just after the inserted text.
                // Best-effort: some apps already do this correctly and will
                // just no-op/ignore a redundant set; if this AXValueCreate
                // or set fails, we still report success for the edit itself.
                var newRange = CFRange(location: selectionStart + (text as NSString).length, length: 0)
                if let axRangeValue = AXValueCreate(.cfRange, &newRange) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRangeValue)
                }
                return .success("[\(mode)] \(modeDesc) -> via AXSelectedText (undoable in most apps)")
            }
            // fall through to Path 2 if this failed despite being "settable"
        }

        // --- Path 2: splice into AXValue directly ---
        var valueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        guard valueSettable.boolValue else {
            return .failure("Neither AXSelectedText nor AXValue is settable on this element — cannot write.")
        }

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let currentValue = (valueRef as? String) ?? ""
        let nsValue = currentValue as NSString

        var cursorLoc = nsValue.length
        var cursorLen = 0
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) {
                cursorLoc = range.location
                cursorLen = range.length
            }
        }

        let safeLoc = min(max(cursorLoc, 0), nsValue.length)
        let safeLen = min(max(cursorLen, 0), nsValue.length - safeLoc)
        let newValue = nsValue.replacingCharacters(in: NSRange(location: safeLoc, length: safeLen), with: text)

        let setErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        guard setErr == .success else {
            return .failure("AXUIElementSetAttributeValue(AXValue) failed (AXError \(setErr.rawValue)).")
        }

        // Best-effort: move cursor to just after the inserted text.
        var newRange = CFRange(location: safeLoc + (text as NSString).length, length: 0)
        if let axRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRangeValue)
        }

        return .success("[\(mode)] \(modeDesc) -> via AXValue splice (may NOT be undoable with Cmd+Z)")
    }

    /// Milestone 3 (Live Patch): reads the focused element's current text
    /// value and cursor location (start of the selection range, or the
    /// caret position if there's no selection). Used to find "the word
    /// at/before the cursor" to compare against a heard phrase.
    static func currentValueAndCursor(targetApp: NSRunningApplication? = nil) -> Result<(text: String, cursorLoc: Int), String> {
        let resolved: (AXUIElement, NSRunningApplication)
        switch resolveFocusedElement(targetApp: targetApp) {
        case .success(let r): resolved = r
        case .failure(let msg):
            // Fallback: try walking the app's AX tree for any text field
            if let fallback = findTextFieldInApp(targetApp: targetApp) {
                return fallback
            }
            return .failure(msg)
        }
        let (element, _) = resolved

        guard let value = copyStringAttribute(element, kAXValueAttribute) else {
            // Fallback: try AXSelectedText instead of AXValue
            if let selected = copyStringAttribute(element, kAXSelectedTextAttribute), !selected.isEmpty {
                return .success((text: selected, cursorLoc: 0))
            }
            // Fallback: walk the tree
            if let fallback = findTextFieldInApp(targetApp: targetApp) {
                return fallback
            }
            return .failure("Focused element has no readable AXValue.")
        }

        var cursorLoc = (value as NSString).length
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) {
                cursorLoc = range.location
            }
        }

        return .success((text: value, cursorLoc: cursorLoc))
    }

    /// Fallback: walk the focused window's AX tree looking for any text element.
    /// This helps with Electron apps and other non-standard frameworks where
    /// the focused element isn't directly the text field.
    private static func findTextFieldInApp(targetApp: NSRunningApplication?, maxDepth: Int = 5) -> Result<(text: String, cursorLoc: Int), String>? {
        guard let app = targetApp ?? NSWorkspace.shared.runningApplications.first(where: { $0.isActive }) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Get focused window
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }

        // Walk children looking for a text area or text field with a value
        return walkForTextField(window as! AXUIElement, depth: 0, maxDepth: maxDepth)
    }

    private static func walkForTextField(_ element: AXUIElement, depth: Int, maxDepth: Int) -> Result<(text: String, cursorLoc: Int), String>? {
        guard depth < maxDepth else { return nil }

        // Check if this element has a role we care about
        if let role = copyStringAttribute(element, kAXRoleAttribute) {
            let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea"]
            if textRoles.contains(role) {
                if let value = copyStringAttribute(element, kAXValueAttribute), !value.isEmpty {
                    var cursorLoc = (value as NSString).length
                    var rangeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                       let rv = rangeRef {
                        var range = CFRange(location: 0, length: 0)
                        if AXValueGetValue((rv as! AXValue), .cfRange, &range) {
                            cursorLoc = range.location
                        }
                    }
                    return .success((text: value, cursorLoc: cursorLoc))
                }
            }
        }

        // Walk children
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children.prefix(20) {
            if let result = walkForTextField(child, depth: depth + 1, maxDepth: maxDepth) {
                return result
            }
        }
        return nil
    }


    /// Milestone 3 (Live Patch): replaces the given character range in the
    /// focused element with `text`. Implemented by moving the selection to
    /// `range` and then reusing `insertTextAtCursor`'s proven REPLACE path
    /// (AXSelectedText first, AXValue splice fallback) — same write engine
    /// as the A/B-tested gesture, just with a programmatically-chosen
    /// selection instead of the user's own.
    ///
    /// `expectedOriginal`, if non-nil, is the text the caller believes is
    /// currently sitting at `range` (the word being corrected). The AXValue
    /// splice fallback below reads the WHOLE field, splices in `text`, and
    /// writes the WHOLE field back — there's a small window between that
    /// read and write where the user can keep typing elsewhere in the
    /// document, and writing our now-stale copy back would silently eat
    /// those keystrokes (observed: "Oh no" -> "ono"). Right before that
    /// write, we re-check that `range` in the freshly-read text still holds
    /// `expectedOriginal`; if the user typed anything that shifted/changed
    /// it, we bail out as STALE instead of clobbering the live document.
    static func replaceRange(_ range: NSRange, with text: String, expectedOriginal: String? = nil, targetApp: NSRunningApplication? = nil) -> Result<String, String> {
        let resolved: (AXUIElement, NSRunningApplication)
        switch resolveFocusedElement(targetApp: targetApp) {
        case .success(let r): resolved = r
        case .failure(let msg): return .failure(msg)
        }
        let (element, _) = resolved

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRangeValue = AXValueCreate(.cfRange, &cfRange) else {
            return .failure("Could not construct AXValue for selection range.")
        }
        let setRangeErr = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRangeValue)
        guard setRangeErr == .success else {
            return .failure("Could not set selection to candidate range (AXError \(setRangeErr.rawValue)).")
        }

        // Verify the selection actually took effect with the requested
        // length. Some apps (observed in Claude desktop) report .success
        // when setting kAXSelectedTextRangeAttribute to a non-empty range,
        // but the selection silently collapses to length 0 — if we
        // proceeded to insertTextAtCursor in that case, it would take the
        // INSERT path and leave the original word in place, splicing the
        // replacement text in right next to it (e.g. "didnt" ->
        // "Didn'tdidnt") instead of replacing it. When that happens, fall
        // back to a direct AXValue splice that doesn't depend on selection
        // state at all.
        var verifyOK = false
        var readBackRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &readBackRef) == .success,
           let rv = readBackRef {
            var readBack = CFRange(location: 0, length: 0)
            if AXValueGetValue((rv as! AXValue), .cfRange, &readBack) {
                verifyOK = (readBack.location == range.location && readBack.length == range.length) || range.length == 0
            }
        }

        if verifyOK {
            return insertTextAtCursor(text, targetApp: targetApp)
        }

        // --- Fallback: splice directly into AXValue, independent of selection ---
        var valueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        guard valueSettable.boolValue else {
            return .failure("Selection range did not stick and AXValue isn't settable — cannot replace.")
        }

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let currentValue = (valueRef as? String) ?? ""
        let nsValue = currentValue as NSString

        guard range.location + range.length <= nsValue.length else {
            return .failure("Candidate range is out of bounds of current AXValue — field changed underneath us.")
        }
        let replacedText = nsValue.substring(with: range)

        // Last-moment freshness check (see doc comment above): if the
        // caller told us what should be at `range` and it's no longer
        // there, the user typed something that shifted the document since
        // our last read. Don't write our (now stale) full-document copy
        // back — that would erase whatever they just typed.
        if let expected = expectedOriginal, replacedText != expected {
            return .failure("STALE: expected \"\(expected)\" at range but found \"\(replacedText)\" — field changed just before write, skipped to avoid clobbering.")
        }

        let newValue = nsValue.replacingCharacters(in: range, with: text)

        let setErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        guard setErr == .success else {
            return .failure("AXUIElementSetAttributeValue(AXValue) failed during fallback splice (AXError \(setErr.rawValue)).")
        }

        // Setting the WHOLE field's AXValue at once (as opposed to a
        // targeted AXSelectedText replace) makes some rich-text editors —
        // notably Claude desktop's — re-sync their internal editor state
        // from the new string on the next tick, which resets the caret to
        // the very start of the document (position 0). If we set the
        // selection range immediately, that reset wins the race and the
        // user sees the cursor jump to the beginning. Give the editor a
        // moment to finish that re-sync first, then set the cursor —
        // ours wins instead.
        usleep(100_000) // 100ms

        // Best-effort: place cursor just after the replacement.
        var newRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let axRangeValue2 = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRangeValue2)
        }

        return .success("[REPLACE] REPLACE \"\(replacedText)\" -> via AXValue splice fallback (selection range didn't stick on this app; may NOT be undoable with Cmd+Z)")
    }

    /// Milestone 3 (Live Patch, mid-flow): collapses the selection to a bare
    /// cursor at `location` in the focused element. Used after a background
    /// correction to put the user's typing cursor back where THEY left it —
    /// which is usually NOT where the just-patched word was, since the
    /// correction often targets a word the user has already typed past.
    static func setCursor(_ location: Int, targetApp: NSRunningApplication? = nil) -> Result<Void, String> {
        let resolved: (AXUIElement, NSRunningApplication)
        switch resolveFocusedElement(targetApp: targetApp) {
        case .success(let r): resolved = r
        case .failure(let msg): return .failure(msg)
        }
        let (element, _) = resolved

        var cfRange = CFRange(location: max(location, 0), length: 0)
        guard let axRangeValue = AXValueCreate(.cfRange, &cfRange) else {
            return .failure("Could not construct AXValue for cursor position.")
        }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRangeValue)
        guard err == .success else {
            return .failure("Could not set cursor position (AXError \(err.rawValue)).")
        }
        return .success(())
    }

    /// Milestone 3 (Live Patch, exploratory): asks the focused element for
    /// its AXAttributedStringForRange over the whole text and reports any
    /// attribute runs that look spelling/grammar-related — this is the same
    /// data macOS uses to draw the red/dotted underlines for misspelled
    /// words and grammar issues. If a given app exposes this, Live Patch
    /// could target words the SYSTEM already flagged as wrong, instead of
    /// guessing via whole-document similarity — which would make corrections
    /// like its/it's, your/you're, there/their far more precise (the system
    /// already knows those are wrong; voice would just supply the fix).
    /// This is a debug probe to find out which apps support it and what the
    /// attribute keys/values actually look like — wired into the existing
    /// Inspect action so results show up in the log.
    static func describeSpellingAttributes(targetApp: NSRunningApplication? = nil) -> Result<String, String> {
        let resolved: (AXUIElement, NSRunningApplication)
        switch resolveFocusedElement(targetApp: targetApp) {
        case .success(let r): resolved = r
        case .failure(let msg): return .failure(msg)
        }
        let (element, _) = resolved

        guard let value = copyStringAttribute(element, kAXValueAttribute) else {
            return .failure("Focused element has no readable AXValue.")
        }
        let nsValue = value as NSString
        guard nsValue.length > 0 else {
            return .success("(empty text — nothing to check)")
        }

        var fullRange = CFRange(location: 0, length: nsValue.length)
        guard let rangeParam = AXValueCreate(.cfRange, &fullRange) else {
            return .failure("Could not construct AXValue for full range.")
        }

        var attrStringRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXAttributedStringForRange" as CFString,
            rangeParam,
            &attrStringRef
        )
        guard err == .success, let raw = attrStringRef else {
            return .failure("AXAttributedStringForRange not supported here (AXError \(err.rawValue)).")
        }
        let attrString = raw as! NSAttributedString

        var lines: [String] = []
        attrString.enumerateAttributes(in: NSRange(location: 0, length: attrString.length), options: []) { attrs, range, _ in
            guard !attrs.isEmpty else { return }
            let interesting = attrs.filter { key, _ in
                let name = key.rawValue.lowercased()
                return name.contains("spell") || name.contains("grammar") || name.contains("misspell")
            }
            guard !interesting.isEmpty else { return }
            let text = nsValue.substring(with: range)
            let attrDesc = interesting.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
            lines.append("\"\(text)\" @\(range.location),\(range.length): \(attrDesc)")
        }

        if lines.isEmpty {
            return .success("AXAttributedStringForRange OK (\(attrString.length) chars), but no spelling/grammar attribute runs found — either nothing is flagged right now, or this app doesn't surface that via AX.")
        }
        return .success("Spelling/grammar-flagged runs:\n" + lines.joined(separator: "\n"))
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        if let s = ref as? String { return s }
        return nil
    }
}
