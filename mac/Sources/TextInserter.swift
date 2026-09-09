import AppKit
import ApplicationServices
import Foundation

/// Puts text where the cursor is, using the least disruptive method that works.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        /// Written straight into the focused text field through the Accessibility API.
        case accessibility
        /// Pasted with Cmd+V; the previous pasteboard contents were restored.
        case paste
        /// Nothing worked; the text is sitting on the clipboard.
        case clipboardOnly

        var historyLabel: String {
            switch self {
            case .accessibility: return "Accessibility API"
            case .paste: return "clipboard + Cmd-V"
            case .clipboardOnly: return "left on clipboard"
            }
        }

        var userMessage: String? {
            self == .clipboardOnly ? "Copied to clipboard; paste manually" : nil
        }
    }

    /// How long to wait before restoring the user's clipboard after posting Cmd+V. Long
    /// enough for a slow (Electron, loaded) app to have consumed the paste; the
    /// `changeCount` check below is what actually keeps the restore safe.
    static let pasteRestoreDelay: TimeInterval = 0.4
    /// Longest document we are willing to copy over AX just to read the character before
    /// the cursor, when the element has no `AXStringForRange`.
    private static let maxValueScanCharacters = 4096
    /// Virtual key code for "V" on any layout (kVK_ANSI_V).
    private static let virtualKeyV: CGKeyCode = 9

    @discardableResult
    static func insert(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .accessibility }

        let context = focusedContext()
        let payload = needsLeadingSpace(precedingCharacter: context?.precedingCharacter, text: text)
            ? " " + text
            : text

        if let element = context?.element, setSelectedText(element, payload) {
            Log.insert.info("Inserted via Accessibility (\(payload.count, privacy: .public) chars)")
            return .accessibility
        }
        if pasteViaClipboard(payload) {
            Log.insert.info("Inserted via Cmd+V (\(payload.count, privacy: .public) chars)")
            return .paste
        }
        copyOnly(payload)
        Log.insert.error("Insertion failed; text left on the clipboard")
        return .clipboardOnly
    }

    // MARK: - Leading space

    /// A space is added when the text would otherwise be glued onto a word. When the
    /// Accessibility API cannot read the surrounding context (`nil`), no space is added.
    static func needsLeadingSpace(precedingCharacter: Character?, text: String) -> Bool {
        guard let previous = precedingCharacter, let first = text.first else { return false }
        guard previous.isLetter || previous.isNumber else { return false }
        return first.isLetter
    }

    // MARK: - Accessibility

    private struct FocusContext {
        var element: AXUIElement
        var precedingCharacter: Character?
    }

    private static func focusedContext() -> FocusContext? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        let element = raw as! AXUIElement
        return FocusContext(element: element, precedingCharacter: characterBeforeCursor(in: element))
    }

    private static func characterBeforeCursor(in element: AXUIElement) -> Character? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location > 0 else { return nil }

        // Ask for exactly the one UTF-16 unit in front of the cursor. Copying the whole
        // document over AX IPC — which is what reading kAXValue does — makes every
        // insertion into a large editor buffer visibly lag.
        if let text = string(in: element, range: CFRange(location: range.location - 1, length: 1)),
           let first = text.first {
            return first
        }
        return firstCharacterFromWholeValue(of: element, before: range.location)
    }

    private static func string(in element: AXUIElement, range: CFRange) -> String? {
        var target = range
        guard let argument = AXValueCreate(.cfRange, &target) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            argument,
            &out
        ) == .success else { return nil }
        return out as? String
    }

    /// Fallback for elements that do not implement `AXStringForRange` (a fair number of
    /// single-line fields). Bounded, so we never haul a whole document across.
    private static func firstCharacterFromWholeValue(of element: AXUIElement, before location: Int) -> Character? {
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let count = countRef as? Int, count <= maxValueScanCharacters
        else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String
        else { return nil }

        let utf16 = Array(text.utf16)
        let index = location - 1
        guard index >= 0, index < utf16.count else { return nil }
        return String(utf16CodeUnits: [utf16[index]], count: 1).first
    }

    private static func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    // MARK: - Clipboard fallback

    /// A deep copy of the pasteboard: every item, every type, as raw data.
    struct PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]]
    }

    static func snapshot(_ pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        return PasteboardSnapshot(items: items)
    }

    static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items = snapshot.items.compactMap { dictionary -> NSPasteboardItem? in
            guard !dictionary.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dictionary { item.setData(data, forType: type) }
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private static func pasteViaClipboard(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(saved, to: pasteboard)
            return false
        }
        // Anything that writes to the pasteboard bumps this; if it moves before the restore
        // fires, either the target app has not pasted yet or the user copied something new.
        // Either way, leaving the pasteboard alone is the safe answer.
        let ourChangeCount = pasteboard.changeCount
        guard postCommandV() else {
            // Leave the text on the clipboard so the user can paste it themselves.
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteRestoreDelay) {
            guard pasteboard.changeCount == ourChangeCount else {
                Log.insert.info("Pasteboard changed after our write; not restoring")
                return
            }
            restore(saved, to: pasteboard)
        }
        return true
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { return false }
        // Only Command; drop any modifier the user is still physically holding.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
