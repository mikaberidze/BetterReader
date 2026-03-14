import AppKit
import Carbon

@main
struct BetterReaderMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appController = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appController.start()
    }
}

@MainActor
final class AppController: NSObject {
    private var hotKeyController: HotKeyController?
    private var accessibilityPollingTimer: Timer?
    private var isCapturingSelection = false
    private let textRetrieval = TextRetrievalService()
    private let readingWindowController = ReadingWindowController()

    func start() {
        prepareHotKey()
    }

    private func prepareHotKey() {
        guard hotKeyController == nil else {
            return
        }

        guard textRetrieval.ensureAccessibilityPermission(prompt: true) else {
            startAccessibilityPolling()
            return
        }

        registerHotKey()
    }

    private func startAccessibilityPolling() {
        guard accessibilityPollingTimer == nil else {
            return
        }

        accessibilityPollingTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(pollAccessibilityPermission),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func pollAccessibilityPermission(_ timer: Timer) {
        guard textRetrieval.ensureAccessibilityPermission(prompt: false) else {
            return
        }

        timer.invalidate()
        accessibilityPollingTimer = nil
        registerHotKey()
    }

    private func registerHotKey() {
        guard hotKeyController == nil else {
            return
        }

        let controller = HotKeyController { [weak self] action in
            switch action {
            case .togglePlayback:
                self?.handleOptionP()
            case .stopAndClose:
                self?.handleOptionO()
            }
        }
        guard controller.register() else {
            presentHotKeyInstallAlert()
            return
        }

        hotKeyController = controller
    }

    private func handleOptionP() {
        guard textRetrieval.ensureAccessibilityPermission(prompt: true) else {
            startAccessibilityPolling()
            return
        }

        guard isCapturingSelection == false else {
            return
        }

        isCapturingSelection = true
        let sourceApplication = NSWorkspace.shared.frontmostApplication

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let selectedText = await self.textRetrieval.selectedTextFromFocusedApp()
            self.isCapturingSelection = false

            guard let selectedText else {
                return
            }

            self.readingWindowController.present(
                text: selectedText.preprocessedForSpeech(),
                returningFocusTo: sourceApplication
            )
        }
    }

    private func handleOptionO() {
        readingWindowController.stopAndClose()
    }

    private func presentHotKeyInstallAlert() {
        let alert = NSAlert()
        alert.messageText = "Global Hotkey Unavailable"
        alert.informativeText =
            "BetterReader could not install the global Option+P interceptor. Grant Accessibility access, then relaunch the app if needed."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
            let settingsURL = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }
}

enum GlobalHotKeyAction {
    case togglePlayback
    case stopAndClose
}

final class HotKeyController {
    private let handler: @MainActor (GlobalHotKeyAction) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping @MainActor (GlobalHotKeyAction) -> Void) {
        self.handler = handler
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    func register() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { _, type, event, userData in
                    guard let userData else {
                        return Unmanaged.passUnretained(event)
                    }

                    let controller = Unmanaged<HotKeyController>.fromOpaque(userData)
                        .takeUnretainedValue()
                    return controller.handleEvent(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            guard let action = hijackedAction(for: event) else {
                return Unmanaged.passUnretained(event)
            }

            let handler = self.handler
            Task { @MainActor in
                handler(action)
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func hijackedAction(for event: CGEvent) -> GlobalHotKeyAction? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let relevantFlags = event.flags.intersection([
            .maskShift,
            .maskControl,
            .maskCommand,
            .maskAlternate,
        ])

        guard relevantFlags == .maskAlternate else {
            return nil
        }

        switch keyCode {
        case Int64(kVK_ANSI_P):
            return .togglePlayback
        case Int64(kVK_ANSI_O):
            return .stopAndClose
        default:
            return nil
        }
    }
}

@MainActor
final class ReadingWindowController: NSWindowController, NSWindowDelegate {
    private let textView: NSTextView
    private var hasCenteredWindow = false

    init() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 460))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 16, height: 20)
        textView.minSize = .zero
        textView.drawsBackground = false
        textView.insertionPointColor = .clear
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        self.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterReader"
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = scrollView

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else {
            return
        }

        if hasCenteredWindow == false {
            window.center()
            hasCenteredWindow = true
        }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func present(text: String, returningFocusTo sourceApplication: NSRunningApplication?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }

        stopSpeaking()
        textView.string = trimmed
        show()

        let selectedRange = NSRange(location: 0, length: (trimmed as NSString).length)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.textView.setSelectedRange(selectedRange)
            self.textView.scrollRangeToVisible(selectedRange)
            self.textView.startSpeaking(nil)
            self.window?.orderOut(nil)
            self.restoreFocus(to: sourceApplication)
        }
    }

    func stopAndClose() {
        stopSpeaking()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopSpeaking()
    }

    private func stopSpeaking() {
        textView.stopSpeaking(nil)
    }

    private func restoreFocus(to sourceApplication: NSRunningApplication?) {
        guard let sourceApplication,
            sourceApplication != NSRunningApplication.current,
            sourceApplication.isTerminated == false
        else {
            return
        }

        sourceApplication.activate(options: [])
    }
}

extension String {
    fileprivate func preprocessedForSpeech() -> String {
        var result = ""
        var index = startIndex

        while index < endIndex {
            let character = self[index]

            if character.isLineBreak {
                result.trimTrailingInlineWhitespace()

                let shouldJoinWithoutSpace = result.last?.isLineBreakHyphen == true

                repeat {
                    index = self.index(after: index)
                } while index < endIndex && self[index].isLineBreak

                while index < endIndex && self[index].isInlineWhitespace {
                    index = self.index(after: index)
                }

                if shouldJoinWithoutSpace == false,
                    result.isEmpty == false,
                    index < endIndex
                {
                    result.append(" ")
                }

                continue
            }

            result.append(character)
            index = self.index(after: index)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate mutating func trimTrailingInlineWhitespace() {
        while last?.isInlineWhitespace == true {
            removeLast()
        }
    }
}

extension Character {
    private static let lineBreakHyphenCharacters: Set<Character> = [
        "-",
        "\u{2010}",  // hyphen
        "\u{2011}",  // non-breaking hyphen
        "\u{2012}",  // figure dash
        "\u{2013}",  // en dash
        "\u{2014}",  // em dash
        "\u{2212}",  // minus sign
        "\u{FE58}",  // small em dash
        "\u{FE63}",  // small hyphen-minus
        "\u{FF0D}",  // fullwidth hyphen-minus
    ]

    fileprivate var isLineBreak: Bool {
        unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
    }

    fileprivate var isInlineWhitespace: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.whitespaces.contains($0) && !CharacterSet.newlines.contains($0)
        }
    }

    fileprivate var isLineBreakHyphen: Bool {
        Self.lineBreakHyphenCharacters.contains(self)
    }
}
