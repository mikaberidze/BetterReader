import AppKit
import ApplicationServices
import Carbon

@MainActor
final class TextRetrievalService {
    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
    }

    func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func selectedTextFromFocusedApp() async -> String? {
        guard ensureAccessibilityPermission(prompt: false) else {
            return nil
        }

        guard let pid = focusedAppPID() else {
            return nil
        }

        if let selectedText = selectedTextUsingAccessibility(for: pid) {
            return selectedText
        }

        return await selectedTextBySimulatedCopy(for: pid)
    }

    private func focusedAppPID() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontmostPID != ownPID
        else {
            return nil
        }

        return frontmostPID
    }

    private func systemWideFocusedElement(expectedPID: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard
            let focusedElement = axElement(
                attribute: kAXFocusedUIElementAttribute as CFString,
                from: systemWide
            )
        else {
            return nil
        }

        var actualPID: pid_t = 0
        let status = AXUIElementGetPid(focusedElement, &actualPID)
        guard status == .success, actualPID == expectedPID else {
            return nil
        }

        return focusedElement
    }

    private func applicationFocusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        return axElement(
            attribute: kAXFocusedUIElementAttribute as CFString,
            from: application
        )
    }

    private func selectedTextUsingAccessibility(for pid: pid_t) -> String? {
        if let focusedElement = systemWideFocusedElement(expectedPID: pid),
            let selectedText = selectedText(from: focusedElement)
        {
            return selectedText
        }

        if let focusedElement = applicationFocusedElement(pid: pid),
            let selectedText = selectedText(from: focusedElement)
        {
            return selectedText
        }

        return nil
    }

    private func selectedText(from element: AXUIElement) -> String? {
        if let direct = stringValue(
            attribute: kAXSelectedTextAttribute as CFString,
            from: element
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
            direct.isEmpty == false
        {
            return direct
        }

        if let ranged = stringForSelectedRange(in: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            ranged.isEmpty == false
        {
            return ranged
        }

        return nil
    }

    private func stringValue(attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else {
            return nil
        }

        return value as? String
    }

    private func stringForSelectedRange(in element: AXUIElement) -> String? {
        var selectedRangeRef: CFTypeRef?
        let selectedRangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )

        guard selectedRangeStatus == .success,
            let selectedRangeRef,
            CFGetTypeID(selectedRangeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        var selectedTextRef: CFTypeRef?
        let selectedTextStatus = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            selectedRangeRef,
            &selectedTextRef
        )
        guard selectedTextStatus == .success else {
            return nil
        }

        return selectedTextRef as? String
    }

    private func axElement(attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard status == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func selectedTextBySimulatedCopy(for pid: pid_t) async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshot(of: pasteboard)
        let initialChangeCount = pasteboard.changeCount

        await waitForOptionKeyRelease()

        guard sendCopyShortcut(to: pid) else {
            return nil
        }

        let copiedText = await waitForPasteboardStringChange(
            after: initialChangeCount,
            pasteboard: pasteboard
        )

        restore(snapshot: snapshot, to: pasteboard)
        return copiedText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()

            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    clone.setString(string, forType: type)
                }
            }

            return clone
        }

        return PasteboardSnapshot(items: items)
    }

    private func restore(snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard snapshot.items.isEmpty == false else {
            return
        }

        pasteboard.writeObjects(snapshot.items)
    }

    private func sendCopyShortcut(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: false
            )
        else {
            return false
        }

        source.localEventsSuppressionInterval = 0
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    private func waitForPasteboardStringChange(
        after changeCount: Int,
        pasteboard: NSPasteboard
    ) async -> String? {
        for _ in 0..<20 {
            if pasteboard.changeCount != changeCount {
                if let copiedString = readString(from: pasteboard) {
                    return copiedString
                }
            }

            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        return nil
    }

    private func readString(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string) {
            return string
        }

        let objects = pasteboard.readObjects(forClasses: [NSString.self], options: nil)
        return objects?.first as? String
    }

    private func waitForOptionKeyRelease() async {
        for _ in 0..<10 {
            if NSEvent.modifierFlags.contains(.option) == false {
                return
            }

            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
